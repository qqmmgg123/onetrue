import 'package:uuid/uuid.dart';

import 'agent_models.dart';
import 'agent_tools.dart';
import 'chat_memory.dart';

/// 不配大模型也能用的本地意图解析（笔记相关常用说法）。
class LocalAgent {
  LocalAgent(this.runner);

  final AgentToolRunner runner;
  final _uuid = const Uuid();

  Future<AgentReply> handle(String raw, {SessionSticky? sticky}) async {
    final text = raw.trim();
    if (text.isEmpty) {
      return AgentReply(
        text: '想到啥说啥就行，比如「记一下明天开会」或「帮我写篇短文」。',
      );
    }

    if (_isHelp(text)) {
      return AgentReply(
        text: '可以这样说：\n'
            '· 记一条：周五下午见客户\n'
            '· 备忘：明天带护照\n'
            '· 日程：下周一 10 点开会，每周重复\n'
            '· 列出我的笔记 / 备忘\n'
            '· 把某篇整理成文章并上架市集\n'
            '写操作会先确认。',
      );
    }

    if (_matchAny(text, ['列出笔记', '有哪些笔记', '笔记本', '我的笔记', '看看笔记'])) {
      return AgentReply(text: await runner.runRead('list_notes', {}));
    }
    if (_matchAny(text, ['列出备忘', '有哪些备忘'])) {
      return AgentReply(
        text: await runner.runRead('list_notes', {'kind': 'memo'}),
      );
    }
    if (_matchAny(text, ['列出日程', '有哪些日程'])) {
      return AgentReply(
        text: await runner.runRead('list_notes', {'kind': 'schedule'}),
      );
    }

    final noteWrite = await tryDirectWrite(text, sticky: sticky);
    if (noteWrite != null) return noteWrite;

    return AgentReply(
      text: '可以说「记一下…」「备忘…」「日程…」，或让我列出/改笔记。'
          '配了大模型后，闲聊和更复杂整理也能直接说。',
    );
  }

  /// 本地能稳定解析的写操作（供编排器优先于大模型）。
  Future<AgentReply?> tryDirectWrite(
    String raw, {
    SessionSticky? sticky,
  }) async {
    final text = raw.trim();
    if (text.isEmpty) return null;

    // 记一条 / 备忘 / 日程
    final memo = RegExp(r'^(?:备忘|提醒我)[:：\s]*(.+)$').firstMatch(text);
    if (memo != null) {
      return _pending('create_note', {
        'kind': 'memo',
        'body': memo.group(1)!.trim(),
      });
    }
    final schedule = RegExp(r'^(?:日程|安排)[:：\s]*(.+)$').firstMatch(text);
    if (schedule != null) {
      return _pending('create_note', {
        'kind': 'schedule',
        'title': schedule.group(1)!.trim(),
        'body': schedule.group(1)!.trim(),
      });
    }
    final note = RegExp(
      r'^(?:记一下|记下|记条|笔记|写一下)[:：\s]*(.+)$',
    ).firstMatch(text);
    if (note != null) {
      return _pending('create_note', {
        'kind': 'note',
        'body': note.group(1)!.trim(),
      });
    }

    return null;
  }

  AgentReply _pending(String tool, Map<String, dynamic> args) {
    final action = PendingAction(
      id: _uuid.v4(),
      tool: tool,
      args: args,
      summary: runner.summarize(tool, args),
    );
    return AgentReply(
      text: '确认一下：${action.summary}\n点下方确认后执行。',
      pending: action,
    );
  }

  bool _isHelp(String text) {
    return _matchAny(text, ['帮助', '怎么用', '你会什么', '能做什么', 'help']);
  }

  bool _matchAny(String text, List<String> keys) {
    for (final k in keys) {
      if (text.contains(k)) return true;
    }
    return false;
  }
}
