import '../ui/format.dart';

class BillLine {
  const BillLine({
    required this.code,
    required this.label,
    required this.amount,
    this.detail = '',
  });

  final String code;
  final String label;
  final double amount;
  final String detail;

  Map<String, dynamic> toJson() => {
        'code': code,
        'label': label,
        'amount': amount,
        'detail': detail,
      };

  factory BillLine.fromJson(Map<String, dynamic> json) => BillLine(
        code: '${json['code']}',
        label: '${json['label']}',
        amount: (json['amount'] as num).toDouble(),
        detail: '${json['detail'] ?? ''}',
      );
}

class BillPreview {
  const BillPreview({
    required this.periodId,
    required this.roomLabel,
    required this.tenantName,
    required this.propertyName,
    required this.periodStart,
    required this.periodEnd,
    required this.dueDate,
    required this.lines,
    required this.total,
    this.invoiceId,
    this.issuedAt,
  });

  final int periodId;
  final String roomLabel;
  final String tenantName;
  final String propertyName;
  final DateTime periodStart;
  final DateTime periodEnd;
  final DateTime dueDate;
  final List<BillLine> lines;
  final double total;
  final int? invoiceId;
  final DateTime? issuedAt;

  bool get isIssued => invoiceId != null;

  String toShareText() {
    final buf = StringBuffer()
      ..writeln('收租清单')
      ..writeln('$propertyName · $roomLabel')
      ..writeln('租户：$tenantName')
      ..writeln('账期：${ymd(periodStart)} ~ ${ymd(periodEnd)}')
      ..writeln('到期：${ymd(dueDate)}')
      ..writeln('----------');
    for (final line in lines) {
      final detail = line.detail.isEmpty ? '' : '（${line.detail}）';
      buf.writeln('${line.label}$detail  ${formatYuan(line.amount)}');
    }
    buf
      ..writeln('----------')
      ..writeln('合计：${formatYuan(total)}')
      ..writeln(isIssued ? '（已出单）' : '（试算，未冻结）');
    return buf.toString();
  }
}

class MeterReading {
  const MeterReading({
    required this.id,
    required this.leaseId,
    required this.kind,
    required this.reading,
    required this.recordedAt,
    this.periodId,
    this.note = '',
  });

  final int id;
  final int leaseId;
  /// electric | water | gas
  final String kind;
  final double reading;
  final DateTime recordedAt;
  final int? periodId;
  final String note;
}

String meterKindLabel(String kind) {
  switch (kind) {
    case 'electric':
      return '电';
    case 'water':
      return '水';
    case 'gas':
      return '燃气';
    default:
      return kind;
  }
}

/// 用量单位：电=度，水/燃气=吨或立方米（水用「吨」更口语）。
String meterUsageUnit(String kind) {
  switch (kind) {
    case 'electric':
      return '度';
    case 'water':
      return '吨';
    case 'gas':
      return '立方米';
    default:
      return '';
  }
}

String meterUsageName(String kind) {
  switch (kind) {
    case 'electric':
      return '用电量';
    case 'water':
      return '用水量';
    case 'gas':
      return '用气量';
    default:
      return '用量';
  }
}

String? parseMeterKind(String raw) {
  final t = raw.trim().toLowerCase();
  if (t.contains('电') || t == 'electric' || t == 'e') return 'electric';
  if (t.contains('水') || t == 'water' || t == 'w') return 'water';
  if (t.contains('燃') || t.contains('煤') || t == 'gas' || t == 'g') {
    return 'gas';
  }
  return null;
}
