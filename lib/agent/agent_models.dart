enum ChatRole { user, assistant, system }

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.text,
    this.pending,
    this.confirmed,
  });

  final ChatRole role;
  final String text;
  final PendingAction? pending;
  final bool? confirmed;
}

/// 写操作先挂起，用户点确认后才真正落库。
class PendingAction {
  PendingAction({
    required this.id,
    required this.tool,
    required this.args,
    required this.summary,
  });

  final String id;
  final String tool;
  final Map<String, dynamic> args;
  final String summary;
}

class AgentReply {
  AgentReply({
    required this.text,
    this.pending,
  });

  final String text;
  final PendingAction? pending;
}
