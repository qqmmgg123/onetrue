import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../billing/bill_models.dart';
import '../state/app_store.dart';
import '../ui/format.dart';
import 'busy.dart';
import 'meter_dialog.dart';

class BillPage extends StatefulWidget {
  const BillPage({super.key, required this.periodId});

  final int periodId;

  @override
  State<BillPage> createState() => _BillPageState();
}

class _BillPageState extends State<BillPage> {
  BillPreview? _bill;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bill =
          await context.read<AppStore>().previewBill(widget.periodId);
      if (!mounted) return;
      setState(() {
        _bill = bill;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bill = _bill;
    return Scaffold(
      appBar: AppBar(
        title: Text(bill == null ? '结算清单' : '${bill.roomLabel} 清单'),
        actions: [
          if (bill != null)
            IconButton(
              tooltip: '分享',
              onPressed: () => Share.share(bill.toShareText()),
              icon: const Icon(Icons.share_outlined),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : bill == null
                  ? const SizedBox.shrink()
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                      children: [
                        Text(
                          '${bill.propertyName} · ${bill.roomLabel}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '账期 ${ymd(bill.periodStart)} ~ ${ymd(bill.periodEnd)}',
                        ),
                        if (bill.remark.trim().isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '备注：${bill.remark.trim()}',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        if (bill.isIssued)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '已出单冻结'
                              '${bill.issuedAt == null ? '' : ' · ${ymd(bill.issuedAt!)}'}'
                              '（改抄表/优惠/额外费用前请先解除冻结）',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        const Divider(height: 28),
                        ...bill.lines.map(
                          (l) => ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(l.label),
                            subtitle: l.detail.isEmpty ? null : Text(l.detail),
                            trailing: Text(
                              formatYuan(l.amount),
                              style: TextStyle(
                                color: l.amount < 0
                                    ? Colors.green.shade700
                                    : null,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const Divider(),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('合计'),
                          trailing: Text(
                            formatYuan(bill.total),
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (bill.isIssued) ...[
                          FilledButton(
                            onPressed: () => _unfreeze(bill),
                            child: const Text('解除冻结'),
                          ),
                          const SizedBox(height: 8),
                        ] else ...[
                          FilledButton(
                            onPressed: () async {
                              final store = context.read<AppStore>();
                              await runBusy(
                                context,
                                message: '正在出单…',
                                task: () async {
                                  await store.issueBill(widget.periodId);
                                  await _load();
                                },
                              );
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已出单冻结')),
                              );
                            },
                            child: const Text('确认出单（冻结清单）'),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: () => _editRemark(bill),
                            child: Text(
                              bill.remark.trim().isEmpty ? '填写备注' : '改备注',
                            ),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: () => _editDiscount(bill),
                            child: const Text('改本月优惠'),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: () => _editPeriodFees(bill),
                            child: const Text('本月额外费用'),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: () => _addMeter(bill),
                            child: const Text('录入/更新抄表'),
                          ),
                        ],
                        if (bill.isIssued) ...[
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: () => _editRemark(bill),
                            child: Text(
                              bill.remark.trim().isEmpty ? '填写备注' : '改备注',
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        OutlinedButton(
                          onPressed: () => Share.share(bill.toShareText()),
                          child: const Text('分享给租户'),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '抄表、优惠、额外费用、解除冻结也可在「对话」里说：\n'
                          '「302 电表 1180 到 1234，水表 80 到 95」\n'
                          '「302 加收维修费 200」\n'
                          '「302 解除冻结」',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
    );
  }

  Future<void> _unfreeze(BillPreview bill) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解除冻结？'),
        content: const Text('清单将恢复为试算，可再改抄表、优惠和额外费用，改完需重新出单。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('解除冻结'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await runBusy(
        context,
        message: '正在解除冻结…',
        task: () async {
          await context.read<AppStore>().unfreezeBill(bill.periodId);
          await _load();
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已解除冻结')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  Future<void> _editRemark(BillPreview bill) async {
    final ctrl = TextEditingController(text: bill.remark);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('本月备注'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: '备注',
            hintText: '例如：已口头说好本月少几天',
          ),
          maxLines: 3,
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final text = ctrl.text;
    ctrl.dispose();
    if (ok != true || !mounted) return;
    try {
      await runBusy(
        context,
        message: '正在保存…',
        task: () async {
          await context.read<AppStore>().updatePeriodRemark(
                periodId: bill.periodId,
                remark: text,
              );
          await _load();
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  Future<void> _editDiscount(BillPreview bill) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _DiscountDialog(),
    );
    if (result == null || !mounted) return;
    try {
      await runBusy(
        context,
        message: '正在保存…',
        task: () async {
          await context.read<AppStore>().applyDiscount(
                periodId: bill.periodId,
                amount: (result['amount'] as num).toDouble(),
                note: '${result['note'] ?? ''}',
              );
          await _load();
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  Future<void> _editPeriodFees(BillPreview bill) async {
    final store = context.read<AppStore>();
    final fees = await store.db.listPeriodFees(bill.periodId);
    if (!mounted) return;
    final changed = await showDialog<bool>(
      context: context,
      builder: (ctx) => _PeriodFeesDialog(
        initial: fees,
        onSave: (items) async {
          final old = await store.db.listPeriodFees(bill.periodId);
          for (final f in old) {
            await store.removePeriodFee(periodId: bill.periodId, name: f.name);
          }
          for (final f in items) {
            if (f.amount <= 0 || f.name.trim().isEmpty) continue;
            await store.upsertPeriodFee(
              periodId: bill.periodId,
              name: f.name,
              amount: f.amount,
            );
          }
        },
      ),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _addMeter(BillPreview bill) async {
    final store = context.read<AppStore>();
    final ctx = await store.db.periodContext(bill.periodId);
    if (ctx == null || !mounted) return;

    final seeds = <String, MeterFieldSeed>{};
    final recent =
        await store.db.recentMeterReadings(ctx.lease.id, limit: 80);
    for (final kind in const ['electric', 'water', 'gas']) {
      final pair =
          await store.db.meterPairForPeriod(ctx.lease.id, kind, ctx.period);
      if (pair != null) {
        seeds[kind] = MeterFieldSeed(
          previous: pair.previous,
          current: pair.current,
        );
      } else {
        MeterReading? last;
        for (final e in recent) {
          if (e.kind == kind &&
              e.recordedAt.isBefore(ctx.period.periodStart)) {
            last = e;
            break; // recent 已按时间倒序
          }
        }
        if (last != null) {
          seeds[kind] = MeterFieldSeed(previous: last.reading);
        }
      }
    }

    if (!mounted) return;
    final result = await showDialog<Map<String, Map<String, double?>>>(
      context: context,
      builder: (_) => MeterReadingDialog(seeds: seeds),
    );
    if (result == null || !mounted) return;
    try {
      await runBusy(
        context,
        message: '正在保存抄表…',
        task: () async {
          for (final entry in result.entries) {
            final current = entry.value['current'];
            if (current == null) continue;
            await store.recordMeterReading(
              leaseId: ctx.lease.id,
              kind: entry.key,
              reading: current,
              periodId: bill.periodId,
              previousReading: entry.value['previous'],
            );
          }
          await _load();
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('抄表已保存')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }
}

class _DiscountDialog extends StatefulWidget {
  @override
  State<_DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends State<_DiscountDialog> {
  final _amount = TextEditingController();
  final _note = TextEditingController(text: '心情减免');

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('本月优惠'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _amount,
            decoration: const InputDecoration(labelText: '减免金额（元，0=清除）'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            autofocus: true,
          ),
          TextField(
            controller: _note,
            decoration: const InputDecoration(labelText: '备注'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context, {
              'amount': parseYuan(_amount.text) ?? 0,
              'note': _note.text.trim(),
            });
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _PeriodFeesDialog extends StatefulWidget {
  const _PeriodFeesDialog({
    required this.initial,
    required this.onSave,
  });

  final List<({String name, double amount})> initial;
  final Future<void> Function(List<({String name, double amount})> items)
      onSave;

  @override
  State<_PeriodFeesDialog> createState() => _PeriodFeesDialogState();
}

class _PeriodFeesDialogState extends State<_PeriodFeesDialog> {
  late final List<TextEditingController> _names;
  late final List<TextEditingController> _amounts;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.initial.isEmpty) {
      _names = [TextEditingController()];
      _amounts = [TextEditingController()];
    } else {
      _names = [
        for (final f in widget.initial) TextEditingController(text: f.name),
      ];
      _amounts = [
        for (final f in widget.initial)
          TextEditingController(
            text: f.amount == f.amount.roundToDouble()
                ? f.amount.toInt().toString()
                : f.amount.toString(),
          ),
      ];
    }
  }

  @override
  void dispose() {
    for (final c in _names) {
      c.dispose();
    }
    for (final c in _amounts) {
      c.dispose();
    }
    super.dispose();
  }

  void _addRow() {
    setState(() {
      _names.add(TextEditingController());
      _amounts.add(TextEditingController());
    });
  }

  void _removeRow(int i) {
    setState(() {
      _names[i].dispose();
      _amounts[i].dispose();
      _names.removeAt(i);
      _amounts.removeAt(i);
      if (_names.isEmpty) {
        _names.add(TextEditingController());
        _amounts.add(TextEditingController());
      }
    });
  }

  Future<void> _save() async {
    final items = <({String name, double amount})>[];
    for (var i = 0; i < _names.length; i++) {
      final name = _names[i].text.trim();
      final amount = parseYuan(_amounts[i].text) ?? 0;
      if (name.isEmpty && amount <= 0) continue;
      if (name.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('费用名称不能为空')),
        );
        return;
      }
      items.add((name: name, amount: amount));
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(items);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('本月额外费用'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '只加在本期账单，不是每月固定附加费。可多项。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _names.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _names[i],
                          decoration: const InputDecoration(
                            labelText: '名称',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _amounts[i],
                          decoration: const InputDecoration(
                            labelText: '金额',
                            isDense: true,
                          ),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '删除',
                        onPressed: () => _removeRow(i),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
              TextButton.icon(
                onPressed: _addRow,
                icon: const Icon(Icons.add),
                label: const Text('再加一项'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
