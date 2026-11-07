import 'package:uuid/uuid.dart';

import 'agent_models.dart';
import 'agent_settings.dart';
import 'agent_tools.dart';
import 'chat_memory.dart';
import 'llm_client.dart';
import 'local_agent.dart';

class AgentTurnResult {
  AgentTurnResult({
    required this.reply,
    required this.sticky,
    required this.usage,
  });

  final AgentReply reply;
  final SessionSticky sticky;
  final ContextUsage usage;
}

class AgentOrchestrator {
  AgentOrchestrator(this.runner, {AgentSettings? settings})
      : settings = settings ?? AgentSettings.instance,
        _local = LocalAgent(runner);

  final AgentToolRunner runner;
  final AgentSettings settings;
  final LocalAgent _local;
  final _uuid = const Uuid();

  static const systemPrompt = '''
你是房东缘初。房东多数不熟悉软件，只会像微信一样随便聊，请用口语承接，不要要求对方按固定格式说话。
规则：
1. 只能通过提供的 tools 查询或修改本地账本；界面能做的（含改小区名、改房号、删房、删小区、退租、改附加费）都用 tools。
2. 写操作一般一次只提议一个 tool；但抄表若用户一次报了水+电（或多种），必须用 record_meter_readings 一次录入全部，不要只录一种。
3. 已设过的水电燃单价要改时，必须用 set_meter_rates（可只改电价或只改水价）；不要用 create_lease。
4. 抄表可只改上月或只改本月：record_meter_reading 的 previous_reading / current_reading 可只传一个。
5. 房间已有在租租约时：改房租/附加费/租户/单价用 update_lease、set_lease_extras、add_lease_extra、set_meter_rates，禁止再调 create_lease（会打断旧账）。
6. 信息可以分多轮慢慢凑齐：结合会话便签和近期对话追问；凑齐再提议执行。租户姓名可选，可不填。
7. 每月附加费是多项「名称+金额」，用 set_lease_extras / add_lease_extra，不要塞进水电单价。
8. 本月一次性额外费用（维修、清扫等，只收一次、可多项有名称）用 add_period_fee / remove_period_fee / set_period_fees，不要和每月附加费、优惠搞混；优惠减免用 apply_period_discount。
9. 本月房租备注（显示在应收列表，不影响金额）用 set_period_remark；清空备注时 remark 传空字符串。
10. 算账用 preview_rent_bill（未冻结可继续补抄表）；确认出单用 issue_invoice；已冻结要改抄表/优惠/额外费用先 unfreeze_invoice 解除冻结。
11. 房间不存在时可 auto_create_room=true。不要编造证件号；电话、租户名可空。
''';

  Future<AgentTurnResult> handleTurn({
    required String userText,
    required List<ChatMessage> priorMessages,
    required SessionSticky sticky,
  }) async {
    var nextSticky = mergeStickyFromUtterance(sticky, userText);
    // 登记槽位已齐却仍挂着 create_lease：清空意图，避免 LLM/本地再次当成「继续登记」
    if (nextSticky.intent == 'create_lease' &&
        missingLeaseSlots(nextSticky).isEmpty) {
      nextSticky.intent = null;
    }
    final packed = packConversation(
      all: priorMessages,
      system: systemPrompt,
      inventory: '', // 占位，下面用真实摘要重算展示
      sticky: nextSticky,
      userText: userText,
      model: settings.effectiveChatModel,
    );

    if (!settings.hasLlm) {
      var reply = await _local.handle(userText, sticky: nextSticky);
      if (runner.store.isGuest && reply.pending != null) {
        reply = AgentReply(
          text: '游客可以随便聊，但改物业/租约需要先注册登录成为房东。'
              '点右上角「登录/注册」即可。',
        );
      }
      nextSticky = mergeStickyFromUtterance(
        nextSticky,
        userText,
        pending: reply.pending,
      );
      if (packed.rolledSummary != null) {
        nextSticky.summary = packed.rolledSummary;
      }
      final inventory = await runner.runRead('list_inventory', {});
      final usage = packConversation(
        all: priorMessages,
        system: systemPrompt,
        inventory: inventory,
        sticky: nextSticky,
        userText: userText,
        model: settings.effectiveChatModel,
      ).usage;
      return AgentTurnResult(reply: reply, sticky: nextSticky, usage: usage);
    }

    // 抄表/优惠等：本地能稳定解析时不交给大模型（避免只回复「好了」却不出现确认按钮）
    if (runner.store.isLandlord) {
      final direct = await _local.tryDirectWrite(userText, sticky: nextSticky);
      if (direct != null && direct.pending != null) {
        nextSticky = mergeStickyFromUtterance(
          nextSticky,
          userText,
          pending: direct.pending,
        );
        final inventory = await runner.runRead('list_inventory', {});
        final usage = packConversation(
          all: priorMessages,
          system: systemPrompt,
          inventory: inventory,
          sticky: nextSticky,
          userText: userText,
          model: settings.effectiveChatModel,
        ).usage;
        return AgentTurnResult(reply: direct, sticky: nextSticky, usage: usage);
      }
    }

    try {
      final result = await _handleWithLlm(
        userText: userText,
        priorMessages: priorMessages,
        sticky: nextSticky,
      );
      nextSticky = mergeStickyFromUtterance(
        nextSticky,
        userText,
        pending: result.reply.pending,
      );
      if (result.rolledSummary != null) {
        nextSticky.summary = result.rolledSummary;
      }
      return AgentTurnResult(
        reply: result.reply,
        sticky: nextSticky,
        usage: result.usage,
      );
    } catch (e) {
      final fallback = await _local.handle(userText, sticky: nextSticky);
      nextSticky = mergeStickyFromUtterance(
        nextSticky,
        userText,
        pending: fallback.pending,
      );
      final inventory = await runner.runRead('list_inventory', {});
      final usage = packConversation(
        all: priorMessages,
        system: systemPrompt,
        inventory: inventory,
        sticky: nextSticky,
        userText: userText,
        model: settings.effectiveChatModel,
      ).usage;
      if (fallback.pending != null || !fallback.text.contains('还没听懂')) {
        return AgentTurnResult(
          reply: AgentReply(
            text: '大模型调用失败（$e），已改用本地理解：\n${fallback.text}',
            pending: fallback.pending,
          ),
          sticky: nextSticky,
          usage: usage,
        );
      }
      return AgentTurnResult(
        reply: AgentReply(
          text: '大模型调用失败：$e\n也可先用本地说法，发「帮助」查看示例。',
        ),
        sticky: nextSticky,
        usage: usage,
      );
    }
  }

  Future<({AgentReply reply, ContextUsage usage, String? rolledSummary})>
      _handleWithLlm({
    required String userText,
    required List<ChatMessage> priorMessages,
    required SessionSticky sticky,
  }) async {
    final inventory = await runner.runRead('list_inventory', {});
    final packed = packConversation(
      all: priorMessages,
      system: systemPrompt,
      inventory: inventory,
      sticky: sticky,
      userText: userText,
      model: settings.effectiveChatModel,
    );

    final llm = LlmClient(settings);
    final result = await llm.chat(
      system: systemPrompt,
      user: userText,
      inventoryContext: inventory,
      sticky: sticky,
      history: packed.history,
      rolledSummary: packed.rolledSummary,
      landlord: runner.store.isLandlord,
    );

    if (result.toolCalls.isEmpty) {
      return (
        reply: AgentReply(
          text: (result.content == null || result.content!.trim().isEmpty)
              ? '我再确认一下：房号、租户、每月几号收、房租多少，你想到哪句说哪句就行。'
              : result.content!.trim(),
        ),
        usage: packed.usage,
        rolledSummary: packed.rolledSummary,
      );
    }

    // 多个抄表 tool 合并成一次确认，避免只执行第一个。
    final mergedMeters = _mergeMeterToolCalls(result.toolCalls);
    final call = mergedMeters ?? result.toolCalls.first;
    if (!writeTools.contains(call.name)) {
      final out = await runner.runRead(call.name, call.arguments);
      final prefix = (result.content == null || result.content!.trim().isEmpty)
          ? ''
          : '${result.content!.trim()}\n\n';
      return (
        reply: AgentReply(text: '$prefix$out'),
        usage: packed.usage,
        rolledSummary: packed.rolledSummary,
      );
    }

    if (runner.store.isGuest) {
      return (
        reply: AgentReply(
          text: '游客可以随便聊，但改物业/租约需要先注册登录成为房东。'
              '点右上角「登录/注册」即可。',
        ),
        usage: packed.usage,
        rolledSummary: packed.rolledSummary,
      );
    }

    final action = PendingAction(
      id: _uuid.v4(),
      tool: call.name,
      args: call.arguments,
      summary: runner.summarize(call.name, call.arguments),
    );
    final tip = (result.content == null || result.content!.trim().isEmpty)
        ? '我帮你记好了，确认要执行吗？'
        : result.content!.trim();
    return (
      reply: AgentReply(text: '$tip\n${action.summary}', pending: action),
      usage: packed.usage,
      rolledSummary: packed.rolledSummary,
    );
  }

  /// 若本轮全是抄表类写操作，合并为 record_meter_readings。
  LlmToolCall? _mergeMeterToolCalls(List<LlmToolCall> calls) {
    if (calls.length < 2) return null;
    final meterOnly = calls.every(
      (c) =>
          c.name == 'record_meter_reading' ||
          c.name == 'record_meter_readings',
    );
    if (!meterOnly) return null;
    final readings = <Map<String, dynamic>>[];
    String? room;
    String? property;
    for (final c in calls) {
      room ??= c.arguments['room_label']?.toString();
      property ??= c.arguments['property_name']?.toString();
      if (c.name == 'record_meter_readings') {
        final list = c.arguments['readings'];
        if (list is List) {
          for (final r in list) {
            if (r is Map) readings.add(Map<String, dynamic>.from(r));
          }
        }
      } else {
        readings.add({
          'kind': c.arguments['kind'],
          'previous_reading': c.arguments['previous_reading'],
          'current_reading': c.arguments['current_reading'],
        });
      }
    }
    if (readings.isEmpty || room == null) return null;
    return LlmToolCall(
      name: 'record_meter_readings',
      arguments: {
        'room_label': room,
        if (property != null && property.isNotEmpty) 'property_name': property,
        'readings': readings,
      },
    );
  }

  Future<String> confirm(PendingAction action) => runner.commit(action);
}
