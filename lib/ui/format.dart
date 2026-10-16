import 'package:intl/intl.dart';

final _ymd = DateFormat('yyyy-MM-dd');
final _ymdCn = DateFormat('yyyy年M月d日');
final _md = DateFormat('M月d日');
final _yuan = NumberFormat('#,##0.##');

String ymd(DateTime date) => _ymd.format(dateOnly(date));

/// 带年份，用于账期列表，避免跨年时「3月10日」分不清。
String ymdCn(DateTime date) => _ymdCn.format(dateOnly(date));

String md(DateTime date) => _md.format(dateOnly(date));

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime? parseYmd(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  return DateTime.parse(raw);
}

String formatYuan(double value) => _yuan.format(value);

double? parseYuan(String raw) {
  final cleaned = raw.trim().replaceAll(',', '').replaceAll('，', '');
  if (cleaned.isEmpty) return null;
  return double.tryParse(cleaned);
}
