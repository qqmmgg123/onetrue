import 'models.dart';

/// 备忘列表排序：
/// 1) 未办结且置顶：最近置顶靠前
/// 2) 未办结未置顶：最近更新靠前
/// 3) 已办结：最近办结靠后
int compareMemosForList(Note a, Note b) {
  final ga = _memoGroup(a);
  final gb = _memoGroup(b);
  if (ga != gb) return ga.compareTo(gb);
  if (ga == 0) {
    final pa = a.pinnedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final pb = b.pinnedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final c = pb.compareTo(pa);
    if (c != 0) return c;
  } else if (ga == 2) {
    final ca = a.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final cb = b.completedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final c = ca.compareTo(cb);
    if (c != 0) return c;
  }
  final u = b.updatedAt.compareTo(a.updatedAt);
  if (u != 0) return u;
  return b.id.compareTo(a.id);
}

/// 0=置顶未办结，1=普通，2=已办结
int _memoGroup(Note n) {
  if (n.isCompleted) return 2;
  if (n.isPinned) return 0;
  return 1;
}

List<Note> sortMemosForList(Iterable<Note> notes) {
  final list = notes.where((n) => n.kind == kNoteKindMemo).toList();
  list.sort(compareMemosForList);
  return list;
}
