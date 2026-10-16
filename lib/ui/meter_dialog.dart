import 'package:flutter/material.dart';

import '../billing/bill_models.dart';

class MeterFieldSeed {
  const MeterFieldSeed({this.previous, this.current});
  final double? previous;
  final double? current;
}

/// 一次可改电/水/燃；预填已有读数。返回非空 map：kind -> {previous?, current}
class MeterReadingDialog extends StatefulWidget {
  const MeterReadingDialog({
    super.key,
    this.seeds = const {},
    this.initialKind = 'electric',
  });

  final Map<String, MeterFieldSeed> seeds;
  final String initialKind;

  @override
  State<MeterReadingDialog> createState() => _MeterReadingDialogState();
}

class _MeterReadingDialogState extends State<MeterReadingDialog> {
  static const _kinds = ['electric', 'water', 'gas'];

  late final Map<String, TextEditingController> _prev;
  late final Map<String, TextEditingController> _curr;

  @override
  void initState() {
    super.initState();
    _prev = {
      for (final k in _kinds)
        k: TextEditingController(
          text: _fmt(widget.seeds[k]?.previous),
        ),
    };
    _curr = {
      for (final k in _kinds)
        k: TextEditingController(
          text: _fmt(widget.seeds[k]?.current),
        ),
    };
  }

  String _fmt(double? v) {
    if (v == null) return '';
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }

  @override
  void dispose() {
    for (final c in _prev.values) {
      c.dispose();
    }
    for (final c in _curr.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('抄表（电 / 水 / 燃）'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final kind in _kinds) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${meterKindLabel(kind)}表',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              TextField(
                controller: _prev[kind],
                decoration: const InputDecoration(
                  labelText: '上期读数',
                  isDense: true,
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              TextField(
                controller: _curr[kind],
                decoration: const InputDecoration(
                  labelText: '本期读数',
                  isDense: true,
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
            ],
            Text(
              '只改要更新的表即可；本期留空表示本表不改。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final out = <String, Map<String, double?>>{};
            for (final kind in _kinds) {
              final currText = _curr[kind]!.text.trim();
              if (currText.isEmpty) continue;
              final current = double.tryParse(currText);
              if (current == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${meterKindLabel(kind)}表本期读数无效')),
                );
                return;
              }
              final prevText = _prev[kind]!.text.trim();
              out[kind] = {
                'current': current,
                'previous':
                    prevText.isEmpty ? null : double.tryParse(prevText),
              };
            }
            if (out.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请至少填写一种表的本期读数')),
              );
              return;
            }
            Navigator.pop(context, out);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}
