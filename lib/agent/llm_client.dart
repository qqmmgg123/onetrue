import 'dart:convert';

import 'package:http/http.dart' as http;

import 'agent_models.dart';
import 'agent_settings.dart';
import 'agent_tools.dart';
import 'chat_memory.dart';

class LlmToolCall {
  LlmToolCall({required this.name, required this.arguments});

  final String name;
  final Map<String, dynamic> arguments;
}

class LlmResult {
  LlmResult({this.content, this.toolCalls = const []});

  final String? content;
  final List<LlmToolCall> toolCalls;
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
  }) async {
    final base = settings.baseUrl.replaceAll(RegExp(r'/+$'), '');
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
      ..writeln('下面是本会话近期对话。房东可能分多句慢慢说，请承接上下文追问补全，不要要求对方按固定格式重说。');
    messages.add({'role': 'system', 'content': preamble.toString()});

    for (final m in history) {
      if (m.role == ChatRole.system) continue;
      messages.add({
        'role': m.role == ChatRole.user ? 'user' : 'assistant',
        'content': m.text,
      });
    }
    messages.add({'role': 'user', 'content': user});

    final body = {
      'model': settings.model,
      'temperature': 0.2,
      'messages': messages,
      'tools': toolSchemas,
      'tool_choice': 'auto',
    };

    final res = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${settings.apiKey}',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 60));

    if (res.statusCode >= 400) {
      throw StateError('模型接口 ${res.statusCode}：${res.body}');
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
    return LlmResult(content: content, toolCalls: calls);
  }
}
