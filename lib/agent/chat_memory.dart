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

/// 会话便签：闲聊过程中逐步记下的槽位，不依赖用户按格式说话。
class SessionSticky {
  SessionSticky({
    this.intent,
    this.propertyName,
    this.roomLabel,
    this.tenantName,
    this.tenantPhone,
    this.rentDueDay,
    this.baseRent,
    this.deposit,
    this.summary,
    Map<String, String>? extras,
  }) : extras = extras ?? {};

  String? intent;
  String? propertyName;
  String? roomLabel;
  String? tenantName;
  String? tenantPhone;
  int? rentDueDay;
  double? baseRent;
  double? deposit;
  String? summary;
  final Map<String, String> extras;

  bool get isEmpty =>
      (intent == null || intent!.isEmpty) &&
      (propertyName == null || propertyName!.isEmpty) &&
      (roomLabel == null || roomLabel!.isEmpty) &&
      (tenantName == null || tenantName!.isEmpty) &&
      tenantPhone == null &&
      rentDueDay == null &&
      baseRent == null &&
      deposit == null &&
      (summary == null || summary!.isEmpty) &&
      extras.isEmpty;

  Map<String, dynamic> toJson() => {
        if (intent != null) 'intent': intent,
        if (propertyName != null) 'property_name': propertyName,
        if (roomLabel != null) 'room_label': roomLabel,
        if (tenantName != null) 'tenant_name': tenantName,
        if (tenantPhone != null) 'tenant_phone': tenantPhone,
        if (rentDueDay != null) 'rent_due_day': rentDueDay,
        if (baseRent != null) 'base_rent': baseRent,
        if (deposit != null) 'deposit': deposit,
        if (summary != null && summary!.isNotEmpty) 'summary': summary,
        if (extras.isNotEmpty) 'extras': extras,
      };

  factory SessionSticky.fromJson(Map<String, dynamic>? json) {
    if (json == null || json.isEmpty) return SessionSticky();
    final extrasRaw = json['extras'];
    return SessionSticky(
      intent: json['intent'] as String?,
      propertyName: json['property_name'] as String?,
      roomLabel: json['room_label'] as String?,
      tenantName: json['tenant_name'] as String?,
      tenantPhone: json['tenant_phone'] as String?,
      rentDueDay: (json['rent_due_day'] as num?)?.toInt(),
      baseRent: (json['base_rent'] as num?)?.toDouble(),
      deposit: (json['deposit'] as num?)?.toDouble(),
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
    if (propertyName != null) lines.add('小区/房产：$propertyName');
    if (roomLabel != null) lines.add('房号：$roomLabel');
    if (tenantName != null) lines.add('租户：$tenantName');
    if (tenantPhone != null && tenantPhone!.isNotEmpty) {
      lines.add('电话：$tenantPhone');
    }
    if (rentDueDay != null) lines.add('每月收款日：$rentDueDay 号');
    if (baseRent != null) lines.add('房租：$baseRent');
    if (deposit != null) lines.add('押金：$deposit');
    for (final e in extras.entries) {
      lines.add('${e.key}：${e.value}');
    }
    return '本会话已从闲聊中记下的信息（可继续追问补全，不要要求用户按固定格式重说）：\n'
        '${lines.join('\n')}';
  }
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.sticky,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final SessionSticky sticky;
  final DateTime createdAt;
  final DateTime updatedAt;
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
  // 给对话历史留窗口的约一半，其余留给 system/tools/账本/回复
  final historyBudget = (window * 0.48).floor().clamp(4000, 48000);

  final fixed = estimateTokens(system) +
      estimateTokens(inventory) +
      estimateTokens(sticky.toPromptBlock()) +
      estimateTokens(userText) +
      toolsReserveTokens;

  final kept = <ChatMessage>[];
  var histTokens = 0;
  // 不把当前正在发送的那句重复算进历史（调用方应先不加入或最后一条另传）
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
      final who = m.role == ChatRole.user ? '房东' : '助手';
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

/// 从闲聊里抽取槽位，合并进便签（本地规则，不依赖模型）。
SessionSticky mergeStickyFromUtterance(
  SessionSticky prev,
  String text, {
  PendingAction? pending,
}) {
  final next = SessionSticky.fromJson(prev.toJson());
  final t = text.trim();

  if (_matchAny(t, ['登记租约', '签租约', '新租约', '租给', '入住', '租出去'])) {
    next.intent = 'create_lease';
  } else if (_matchAny(t, ['加房间', '加个房', '新增房间', '添加房间']) ||
      (t.contains('加') && t.contains('房') && !t.contains('房租'))) {
    next.intent = 'add_room';
  } else if (_matchAny(t, ['加小区', '新小区', '加个房产', '新增小区'])) {
    next.intent = 'add_property';
  } else if (_matchAny(t, ['改租约', '改附加费', '改房租', '改收租日', '更新租约']) ||
      (_matchAny(t, ['附加费', '物业费', '网费']) &&
          _matchAny(t, ['改', '加', '换', '设']))) {
    next.intent = 'update_lease';
  } else if (_matchAny(t, ['抄表', '电表', '水表', '燃气表', '煤气表'])) {
    next.intent = 'meter';
  } else if (_matchAny(t, [
    '出单',
    '算房租',
    '试算',
    '少收',
    '优惠',
    '备注',
    '解冻',
    '记已收',
  ])) {
    next.intent = 'billing';
  }

  final prop = RegExp(r'([\u4e00-\u9fa5A-Za-z0-9]{2,20})(?:小区|公寓|花园|苑|里)')
          .firstMatch(t)
          ?.group(1) ??
      RegExp(r'(?:小区|房产|楼盘)[叫为是]?[:：]?\s*([\u4e00-\u9fa5A-Za-z0-9]{2,20})')
          .firstMatch(t)
          ?.group(1);
  if (prop != null) next.propertyName = prop;

  // 房号：优先「给 302 / 302室 / 房号302」，避免把「2800」当房号
  final roomCand = RegExp(r'(?:给|为)\s*([A-Za-z0-9\-]+)')
          .firstMatch(t)
          ?.group(1) ??
      RegExp(r'([A-Za-z0-9\-]+)\s*(?:室|房)')
          .firstMatch(t)
          ?.group(1) ??
      RegExp(r'房号\s*[:：]?\s*([A-Za-z0-9\-]+)').firstMatch(t)?.group(1) ??
      RegExp(r'([A-Za-z0-9\-]+)\s*(?:那间|这间)').firstMatch(t)?.group(1);
  if (roomCand != null && !_looksLikeMoneyOnly(t, roomCand)) {
    next.roomLabel = roomCand;
  }

  final tenant = RegExp(r'(?:租户|租客)[叫为是]?[:：]?\s*([\u4e00-\u9fa5A-Za-z]{1,20})')
          .firstMatch(t)
          ?.group(1) ??
      RegExp(r'(?:叫|名叫)\s*([\u4e00-\u9fa5A-Za-z]{2,20})')
          .firstMatch(t)
          ?.group(1) ??
      RegExp(r'租给\s*([\u4e00-\u9fa5A-Za-z]{1,20})').firstMatch(t)?.group(1);
  if (tenant != null &&
      !const {'每月', '这个', '那个', '什么', '多少'}.contains(tenant)) {
    next.tenantName = tenant;
  }

  final due = RegExp(r'每月?\s*(\d{1,2})\s*号').firstMatch(t)?.group(1) ??
      RegExp(r'(\d{1,2})\s*号\s*(?:收|交|给)?').firstMatch(t)?.group(1);
  if (due != null) {
    final d = int.parse(due);
    if (d >= 1 && d <= 31) next.rentDueDay = d;
  }

  final rent = RegExp(r'(?:房租|租金|月租)\s*(\d+(?:\.\d+)?)')
          .firstMatch(t)
          ?.group(1) ??
      RegExp(r'(\d{3,6})\s*元(?:一个月|／月|/月|每月)?').firstMatch(t)?.group(1);
  if (rent != null) next.baseRent = double.parse(rent);

  final deposit = RegExp(r'押金\s*(\d+(?:\.\d+)?)').firstMatch(t)?.group(1);
  if (deposit != null) next.deposit = double.parse(deposit);

  final phone = RegExp(r'1\d{10}').firstMatch(t)?.group(0);
  if (phone != null) next.tenantPhone = phone;

  if (pending != null) {
    final a = pending.args;
    // create_lease 已凑齐并进入「待确认」后清掉意图，避免后续话被当成继续登记
    if (pending.tool == 'create_lease') {
      next.intent = null;
    } else {
      next.intent = pending.tool;
    }
    if (a['property_name'] != null) next.propertyName = '${a['property_name']}';
    if (a['room_label'] != null) next.roomLabel = '${a['room_label']}';
    if (a['tenant_name'] != null) next.tenantName = '${a['tenant_name']}';
    if (a['tenant_phone'] != null) next.tenantPhone = '${a['tenant_phone']}';
    if (a['rent_due_day'] != null) {
      next.rentDueDay = (a['rent_due_day'] as num).toInt();
    }
    if (a['base_rent'] != null) {
      next.baseRent = (a['base_rent'] as num).toDouble();
    }
    if (a['deposit'] != null) {
      next.deposit = (a['deposit'] as num).toDouble();
    }
  }

  // 槽位已齐却仍标着 create_lease：多半是旧会话残留，清掉以免劫持
  if (next.intent == 'create_lease' && missingLeaseSlots(next).isEmpty) {
    next.intent = null;
  }

  return next;
}

bool _looksLikeMoneyOnly(String text, String room) =>
    RegExp(r'^\d{3,6}$').hasMatch(room) &&
    _matchAny(text, ['房租', '租金', '月租', '押金', '元', '块']);

bool _matchAny(String text, List<String> keys) => keys.any(text.contains);

List<String> missingLeaseSlots(SessionSticky s) {
  final missing = <String>[];
  if (s.roomLabel == null || s.roomLabel!.isEmpty) missing.add('房号');
  // 租户姓名可选
  if (s.rentDueDay == null) missing.add('每月几号收租');
  if (s.baseRent == null) missing.add('房租多少');
  return missing;
}
