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
你是「醍醐」里的全能 AI：可以闲聊、解答问题、帮忙构思与写作；同时能通过 tools 操作用户的笔记本（随笔/备忘/日程/文章）。
用户像微信一样随便聊；不要要求固定格式。没有对应 tool 的事，用自然语言直接答即可。
笔记技能：
1. 只能通过提供的 tools 查询或修改笔记本；不要假装已改数据。
2. create_note / update_note / list_notes；形态互转 convert_note_kind；多篇整理成文 merge_notes_to_article（默认保留原文）；文章上架 publish_note / 下架 unpublish_note。
3. 写文章/整理文章时 body 必须是完整纯文本正文（不要只写标题；不要 Markdown 代码块或 JSON）。
4. 日程重复用 recur_freq/recur_byday/recur_until|recur_count；remind_offset_min 为相对提醒（-1=不提醒）；备忘用 remind_at，禁止设为过去的时间，不提醒则不传。
5. 用户只要把正文「贴到对话里/发给我看」时，用自然语言回复正文，不要为此调用写工具。
6. 写操作提议后等用户确认再执行；回复尽量短。
''';

  Future<AgentTurnResult> handleTurn({
    required String userText,
    required List<ChatMessage> priorMessages,
    required SessionSticky sticky,
  }) async {
    var nextSticky = mergeStickyFromUtterance(sticky, userText);
    final packed = packConversation(
      all: priorMessages,
      system: systemPrompt,
      inventory: '',
      sticky: nextSticky,
      userText: userText,
      model: settings.effectiveChatModel,
    );

    if (!settings.hasLlm) {
      var reply = await _local.handle(userText, sticky: nextSticky);
      if (runner.store.isGuest && reply.pending != null) {
        reply = AgentReply(
          text: '游客可以随便聊，但改笔记本需要先注册登录。'
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
      final inventory = await runner.runRead('list_notes', {});
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

    if (runner.store.isLandlord) {
      final direct = await _local.tryDirectWrite(userText, sticky: nextSticky);
      if (direct != null && direct.pending != null) {
        nextSticky = mergeStickyFromUtterance(
          nextSticky,
          userText,
          pending: direct.pending,
        );
        final inventory = await runner.runRead('list_notes', {});
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
      final inventory = await runner.runRead('list_notes', {});
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
    final inventory = await runner.runRead('list_notes', {});
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
              ? '可以说得更具体一点，或让我「记一下…」「列出笔记」。'
              : result.content!.trim(),
        ),
        usage: packed.usage,
        rolledSummary: packed.rolledSummary,
      );
    }

    final call = result.toolCalls.first;
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
          text: '游客可以随便聊，但改笔记本需要先注册登录。'
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
        ? '确认要执行吗？'
        : result.content!.trim();
    return (
      reply: AgentReply(text: '$tip\n${action.summary}', pending: action),
      usage: packed.usage,
      rolledSummary: packed.rolledSummary,
    );
  }

  Future<String> confirm(PendingAction action) => runner.commit(action);
}
