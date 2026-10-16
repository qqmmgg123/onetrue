import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../billing/bill_models.dart';
import '../state/app_store.dart';
import '../ui/format.dart';
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
                        Text('租户：${bill.tenantName}'),
                        Text(
                          '账期 ${ymd(bill.periodStart)} ~ ${ymd(bill.periodEnd)} · 到期 ${ymd(bill.dueDate)}',
                        ),
                        if (bill.isIssued)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '已出单冻结'
                              '${bill.issuedAt == null ? '' : ' · ${ymd(bill.issuedAt!)}'}'
                              '（改抄表/优惠前请先解除冻结）',
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
                              await store.issueBill(widget.periodId);
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('已出单冻结')),
                              );
                              await _load();
                            },
                            child: const Text('确认出单（冻结清单）'),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: () => _editDiscount(bill),
                            child: const Text('改本月优惠'),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton(
                            onPressed: () => _addMeter(bill),
                            child: const Text('录入/更新抄表'),
                          ),
                        ],
                        const SizedBox(height: 8),
                        OutlinedButton(
                          onPressed: () => Share.share(bill.toShareText()),
                          child: const Text('分享给租户'),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '抄表、优惠、解除冻结也可在「对话」里说：\n'
                          '「302 电表 1180 到 1234，水表 80 到 95」\n'
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
        content: const Text('清单将恢复为试算，可再改抄表和优惠，改完需重新出单。'),
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
      await context.read<AppStore>().unfreezeBill(bill.periodId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已解除冻结')),
      );
      await _load();
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
      await context.read<AppStore>().applyDiscount(
            periodId: bill.periodId,
            amount: (result['amount'] as num).toDouble(),
            note: '${result['note'] ?? ''}',
          );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
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
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('抄表已保存')),
      );
      await _load();
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
