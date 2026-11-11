import 'package:intl/intl.dart';

final _ymd = DateFormat('yyyy-MM-dd');
final _ymdCn = DateFormat('yyyy年M月d日');
final _md = DateFormat('M月d日');
final _ymdHm = DateFormat('yyyy年M月d日 HH:mm');
final _yuan = NumberFormat('#,##0.##');

String ymd(DateTime date) => _ymd.format(dateOnly(date));

/// 带年份，用于账期列表，避免跨年时「3月10日」分不清。
String ymdCn(DateTime date) => _ymdCn.format(dateOnly(date));

String md(DateTime date) => _md.format(dateOnly(date));

String ymdHm(DateTime date) => _ymdHm.format(date);

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime? parseYmd(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return DateTime.parse(raw);
}

String formatYuan(double value) => _yuan.format(value);

/// 相对编辑/提醒时间：几分钟前、昨天上午 9:30、3月2日 等。
String formatFriendlyWhen(DateTime raw, {DateTime? now}) {
  final t = raw.isUtc ? raw.toLocal() : raw;
  final n = now ?? DateTime.now();
  final diff = n.difference(t);
  if (diff.inSeconds.abs() < 60) return '刚刚';
  if (diff.isNegative) {
    // 未来
    final mins = diff.abs().inMinutes;
    if (mins < 60) return '$mins 分钟后';
    final hours = diff.abs().inHours;
    if (hours < 24 && dateOnly(t) == dateOnly(n)) {
      return '今天 ${_hm(t)}';
    }
  } else {
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 6 && dateOnly(t) == dateOnly(n)) {
      return '${diff.inHours} 小时前';
    }
  }
  final today = dateOnly(n);
  final day = dateOnly(t);
  final period = t.hour < 12 ? '上午' : '下午';
  final hm = _hm(t);
  if (day == today) return '今天$period $hm';
  if (day == today.subtract(const Duration(days: 1))) {
    return '昨天$period $hm';
  }
  if (day == today.subtract(const Duration(days: 2))) {
    return '前天$period $hm';
  }
  if (t.year == n.year) {
    return '${t.month}月${t.day}日 $period $hm';
  }
  return '${t.year}年${t.month}月${t.day}日 $period $hm';
}

String _hm(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

double? parseYuan(String raw) {
  final cleaned = raw.trim().replaceAll(',', '').replaceAll('，', '');
  if (cleaned.isEmpty) return null;
  return double.tryParse(cleaned);
}
