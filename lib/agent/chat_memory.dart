import 'dart:convert';

import 'agent_models.dart';

class ChatPruneReport {
  const ChatPruneReport({
    required this.deletedSessions,
    required this.trimmedMessages,
  });

  final int deletedSessions;
  final int trimmedMessages;

  bool get didWork => deletedSessions > 0 || trimmedMessages > 0;
}

/// 会话便签：多轮补全用的轻量上下文（笔记向）。
class SessionSticky {
  SessionSticky({
    this.intent,
    this.summary,
    Map<String, String>? extras,
  }) : extras = extras ?? {};

  String? intent;
  String? summary;
  final Map<String, String> extras;

  bool get isEmpty =>
      (intent == null || intent!.isEmpty) &&
      (summary == null || summary!.isEmpty) &&
      extras.isEmpty;

  Map<String, dynamic> toJson() => {
        if (intent != null) 'intent': intent,
        if (summary != null && summary!.isNotEmpty) 'summary': summary,
        if (extras.isNotEmpty) 'extras': extras,
      };

  factory SessionSticky.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) return SessionSticky();
    final extrasRaw = json['extras'];
    return SessionSticky(
      intent: json['intent'] as String?,
      summary: json['summary'] as String?,
      extras: extrasRaw is Map
          ? extrasRaw.map((k, v) => MapEntry('$k', '$v'))
          : {},
    );
  }

  factory SessionSticky.decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return SessionSticky();
    try {
      return SessionSticky.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return SessionSticky();
    }
  }

  String encode() => jsonEncode(toJson());

  String toPromptBlock() {
    if (isEmpty) return '';
    final lines = <String>[];
    if (summary != null && summary!.trim().isNotEmpty) {
      lines.add('更早对话摘要：$summary');
    }
    if (intent != null) lines.add('当前意图：$intent');
    for (final e in extras.entries) {
      lines.add('${e.key}：${e.value}');
    }
    return '本会话已从闲聊中记下的信息（可继续追问补全）：\n'
        '${lines.join('\n')}';
  }
}

/// 会话作用域：找 AI（agent）与笔记编辑 AI（note）分开存。
const kChatKindAgent = 'agent';
const kChatKindNote = 'note';

class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.sticky,
    required this.createdAt,
    required this.updatedAt,
    this.kind = kChatKindAgent,
    this.refKey,
  });

  final String id;
  final String title;
  final SessionSticky sticky;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// [kChatKindAgent] 全 App 找 AI；[kChatKindNote] 绑定某篇笔记草稿。
  final String kind;

  /// note 会话：笔记 uuid，或未保存时的 `draft:…`。
  final String? refKey;
}

class StoredChatMessage {
  StoredChatMessage({
    this.id,
    required this.sessionId,
    required this.role,
    required this.text,
    this.pending,
    this.confirmed,
    required this.createdAt,
  });

  final int? id;
  final String sessionId;
  final ChatRole role;
  final String text;
  final PendingAction? pending;
  final bool? confirmed;
  final DateTime createdAt;

  ChatMessage toUi() => ChatMessage(
        role: role,
        text: text,
        pending: pending,
        confirmed: confirmed,
      );
}

class ContextUsage {
  const ContextUsage({
    required this.usedTokens,
    required this.windowTokens,
    required this.keptMessages,
    required this.droppedMessages,
  });

  final int usedTokens;
  final int windowTokens;
  final int keptMessages;
  final int droppedMessages;

  double get ratio =>
      windowTokens <= 0 ? 0 : (usedTokens / windowTokens).clamp(0.0, 1.5);

  int get percent => (ratio * 100).round().clamp(0, 999);
}

/// 粗估 token：中文偏多时约 1.6 字/token，英文约 4 字/token，取折中。
int estimateTokens(String text) {
  if (text.isEmpty) return 0;
  var cjk = 0;
  for (final r in text.runes) {
    if (r >= 0x4E00 && r <= 0x9FFF) cjk++;
  }
  final other = text.length - cjk;
  return ((cjk / 1.5) + (other / 4)).ceil().clamp(1, 1000000);
}

int contextWindowForModel(String model) {
  final m = model.toLowerCase();
  final n = RegExp(r'(\d+)\s*k').firstMatch(m)?.group(1);
  if (n != null) {
    final k = int.tryParse(n);
    if (k != null && k >= 4) return k * 1024;
  }
  if (m.contains('deepseek')) return 65536;
  if (m.contains('glm-4') || m.contains('glm4')) return 128000;
  if (m.contains('qwen')) return 32768;
  if (m.contains('ernie')) return 8192;
  if (m.contains('gpt-4o') || m.contains('claude')) return 128000;
  if (m.contains('32k')) return 32768;
  return 32768;
}

class PackedContext {
  PackedContext({
    required this.history,
    required this.usage,
    this.rolledSummary,
  });

  final List<ChatMessage> history;
  final ContextUsage usage;
  final String? rolledSummary;
}

/// 按 token 预算从新到旧尽量多带历史；装不下的压成摘要。
PackedContext packConversation({
  required List<ChatMessage> all,
  required String system,
  required String inventory,
  required SessionSticky sticky,
  required String userText,
  required String model,
  int toolsReserveTokens = 3500,
}) {
  final window = contextWindowForModel(model);
  final historyBudget = (window * 0.48).floor().clamp(4000, 48000);

  final fixed = estimateTokens(system) +
      estimateTokens(inventory) +
      estimateTokens(sticky.toPromptBlock()) +
      estimateTokens(userText) +
      toolsReserveTokens;

  final kept = <ChatMessage>[];
  var histTokens = 0;
  for (var i = all.length - 1; i >= 0; i--) {
    final m = all[i];
    if (m.role == ChatRole.system) continue;
    final t = estimateTokens('${m.role.name}:${m.text}');
    if (kept.isNotEmpty && histTokens + t > historyBudget) break;
    kept.insert(0, m);
    histTokens += t;
  }

  String? rolled;
  final dropped = all.length - kept.length;
  if (dropped > 0) {
    final old = all.take(dropped).where((m) => m.role != ChatRole.system);
    final buf = StringBuffer();
    for (final m in old.take(40)) {
      final who = m.role == ChatRole.user ? '用户' : '助手';
      final snippet =
          m.text.length > 80 ? '${m.text.substring(0, 80)}…' : m.text;
      buf.writeln('$who：$snippet');
    }
    rolled = buf.toString().trim();
    if (rolled.length > 1200) {
      rolled = rolled.substring(rolled.length - 1200);
    }
  }

  final used = fixed + histTokens + estimateTokens(rolled ?? '');
  return PackedContext(
    history: kept,
    usage: ContextUsage(
      usedTokens: used,
      windowTokens: window,
      keptMessages: kept.length,
      droppedMessages: dropped < 0 ? 0 : dropped,
    ),
    rolledSummary: rolled,
  );
}

/// 从闲聊里抽取意图，合并进便签（本地规则，不依赖模型）。
SessionSticky mergeStickyFromUtterance(
  SessionSticky prev,
  String text, {
  PendingAction? pending,
}) {
  final next = SessionSticky.fromJson(prev.toJson());
  final t = text.trim();

  if (_matchAny(t, ['记一下', '记下', '记条', '写笔记', '备忘', '日程', '提醒我'])) {
    next.intent = 'create_note';
  } else if (_matchAny(t, ['列出笔记', '我的笔记', '有哪些笔记'])) {
    next.intent = 'list_notes';
  } else if (_matchAny(t, ['上架', '发布到市集', '下架'])) {
    next.intent = 'publish_note';
  }

  if (pending != null) {
    next.intent = pending.tool;
  }

  return next;
}

bool _matchAny(String text, List<String> keys) => keys.any(text.contains);
