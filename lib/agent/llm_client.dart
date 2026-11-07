import 'dart:convert';

import 'package:http/http.dart' as http;

import 'agent_models.dart';
import 'agent_settings.dart';
import 'agent_tools.dart';
import 'chat_memory.dart';
import 'llm_providers.dart';

class LlmToolCall {
  LlmToolCall({required this.name, required this.arguments});

  final String name;
  final Map<String, dynamic> arguments;
}

class LlmResult {
  LlmResult({this.content, this.toolCalls = const [], this.providerName});

  final String? content;
  final List<LlmToolCall> toolCalls;
  final String? providerName;
}

class LlmClient {
  LlmClient(this.settings);

  final AgentSettings settings;

  Future<LlmResult> chat({
    required String system,
    required String user,
    required String inventoryContext,
    SessionSticky? sticky,
    List<ChatMessage> history = const [],
    String? rolledSummary,
    bool landlord = true,
  }) async {
    final endpoints = settings.resolveEndpoints();
    if (endpoints.isEmpty) {
      throw StateError(
        '未配置可用对话模型。请在设置中选择厂商并填写 Key，'
        '或打包时在 env.local 配置 ZHIPU_API_KEY / BAIDU_LLM_API_KEY / ASR_API_KEY / ONE_API_*。',
      );
    }

    final errors = <String>[];
    for (final ep in endpoints) {
      try {
        return await _chatOnce(
          ep: ep,
          system: system,
          user: user,
          inventoryContext: inventoryContext,
          sticky: sticky,
          history: history,
          rolledSummary: rolledSummary,
          landlord: landlord,
        );
      } catch (e) {
        errors.add('${ep.name}: $e');
        if (!_shouldFailover(e)) {
          // 业务/参数类错误不浪费下一家（少见）；仍允许换家试 tools 兼容
          if (!_looksLikeProviderIssue(e)) rethrow;
        }
      }
    }
    throw StateError(
      '对话模型均不可用：\n${errors.join('\n')}\n'
      '可到设置里换厂商，或检查 Key / 限额。',
    );
  }

  Future<LlmResult> _chatOnce({
    required LlmEndpoint ep,
    required String system,
    required String user,
    required String inventoryContext,
    SessionSticky? sticky,
    List<ChatMessage> history = const [],
    String? rolledSummary,
    bool landlord = true,
  }) async {
    final base = ep.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/chat/completions');

    final messages = <Map<String, String>>[
      {'role': 'system', 'content': system},
    ];

    final preamble = StringBuffer()
      ..writeln('当前账本摘要：')
      ..writeln(inventoryContext);
    final stickyBlock = sticky?.toPromptBlock() ?? '';
    if (stickyBlock.isNotEmpty) {
      preamble
        ..writeln()
        ..writeln(stickyBlock);
    }
    if (rolledSummary != null && rolledSummary.trim().isNotEmpty) {
      preamble
        ..writeln()
        ..writeln('更早对话摘要（原文已截断，事实以便签和账本为准）：')
        ..writeln(rolledSummary);
    }
    preamble
      ..writeln()
      ..writeln(
        '下面是本会话近期对话。房东可能分多句慢慢说，请承接上下文追问补全，不要要求对方按固定格式重说。',
      )
      ..writeln(
        '若便签里写着「当前意图」，只表示多轮补全中的提示；'
        '房东本句若是抄表/优惠/备注/改附加费/出单等，必须按本句意图调用对应 tool，'
        '不要沿用已结束的「登记租约」。房间已有在租约时禁止再 create_lease。'
        '历史里标注「已确认执行/已取消」的操作不要重复提议。',
      );
    messages.add({'role': 'system', 'content': preamble.toString()});

    for (final m in history) {
      if (m.role == ChatRole.system) continue;
      var content = m.text;
      if (m.pending != null) {
        if (m.confirmed == true) {
          content = '$content\n（已确认执行：${m.pending!.tool}）';
        } else if (m.confirmed == false) {
          content = '$content\n（已取消：${m.pending!.tool}）';
        } else {
          content = '$content\n（待房东点确认，尚未执行：${m.pending!.tool}）';
        }
      }
      messages.add({
        'role': m.role == ChatRole.user ? 'user' : 'assistant',
        'content': content,
      });
    }
    messages.add({'role': 'user', 'content': user});

    final model = ep.model == 'default' ? '' : ep.model;
    final body = <String, dynamic>{
      if (model.isNotEmpty) 'model': model,
      'temperature': 0.2,
      'messages': messages,
      'tools': toolSchemasFor(landlord: landlord),
      'tool_choice': 'auto',
    };

    final res = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${ep.apiKey}',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 60));

    if (res.statusCode >= 400) {
      throw StateError('HTTP ${res.statusCode}：${res.body}');
    }

    final json = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final choices = json['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      throw StateError('模型没有返回内容');
    }
    final message = (choices.first as Map)['message'] as Map<String, dynamic>;
    final content = message['content'] as String?;
    final rawTools = message['tool_calls'] as List<dynamic>? ?? const [];
    final calls = <LlmToolCall>[];
    for (final t in rawTools) {
      final fn = (t as Map)['function'] as Map<String, dynamic>?;
      if (fn == null) continue;
      final name = fn['name'] as String? ?? '';
      final argsRaw = fn['arguments'];
      Map<String, dynamic> args = {};
      if (argsRaw is String && argsRaw.isNotEmpty) {
        args = Map<String, dynamic>.from(jsonDecode(argsRaw) as Map);
      } else if (argsRaw is Map) {
        args = Map<String, dynamic>.from(argsRaw);
      }
      if (name.isNotEmpty) {
        calls.add(LlmToolCall(name: name, arguments: args));
      }
    }
    return LlmResult(
      content: content,
      toolCalls: calls,
      providerName: ep.name,
    );
  }

  static bool _shouldFailover(Object e) {
    final s = '$e'.toLowerCase();
    return s.contains('timeout') ||
        s.contains('timed out') ||
        s.contains('socket') ||
        s.contains('connection') ||
        s.contains('http 429') ||
        s.contains('http 5') ||
        s.contains('http 401') ||
        s.contains('http 403') ||
        s.contains('没有返回内容') ||
        s.contains('tool') ||
        s.contains('function');
  }

  static bool _looksLikeProviderIssue(Object e) {
    final s = '$e'.toLowerCase();
    return s.contains('http ') ||
        s.contains('timeout') ||
        s.contains('没有返回') ||
        s.contains('tool');
  }
}
