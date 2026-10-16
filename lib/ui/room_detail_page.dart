import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_database.dart';
import '../domain/models.dart';
import '../state/app_store.dart';
import 'bill_page.dart';
import 'format.dart';
import 'lease_form_page.dart';

class RoomDetailPage extends StatefulWidget {
  const RoomDetailPage({super.key, required this.roomId});

  final int roomId;

  @override
  State<RoomDetailPage> createState() => _RoomDetailPageState();
}

class _RoomDetailPageState extends State<RoomDetailPage> {
  Room? _room;
  Property? _property;
  Lease? _lease;
  Tenant? _tenant;
  List<RentPeriod> _periods = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = AppDatabase.instance;
    final room = await db.getRoom(widget.roomId);
    Property? property;
    Lease? lease;
    Tenant? tenant;
    List<RentPeriod> periods = [];
    if (room != null) {
      property = await db.getProperty(room.propertyId);
      lease = await db.activeLeaseForRoom(room.id);
      if (lease != null) {
        tenant = await db.getTenant(lease.tenantId);
        periods = await db.periodsForLease(lease.id);
      }
    }
    if (!mounted) return;
    setState(() {
      _room = room;
      _property = property;
      _lease = lease;
      _tenant = tenant;
      _periods = periods;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    return Scaffold(
      appBar: AppBar(
        title: Text(room?.label ?? '房间'),
        actions: [
          if (room != null)
            IconButton(
              tooltip: '删除房间',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('删除这个房间？'),
                    content: const Text('租约和账期会一起删掉。'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('删除'),
                      ),
                    ],
                  ),
                );
                if (ok == true && mounted) {
                  await context.read<AppStore>().removeRoom(room.id);
                  if (mounted) Navigator.pop(context);
                }
              },
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                if (_property != null) Text(_property!.name),
                const SizedBox(height: 12),
                if (_lease == null)
                  FilledButton(
                    onPressed: _editLease,
                    child: const Text('登记租约'),
                  )
                else ...[
                  Text(
                    '${_tenant?.name ?? ''}  ${_tenant?.phone ?? ''}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '每月${_lease!.rentDueDay}号 · 房租 ${formatYuan(_lease!.baseRent)} · 押金 ${formatYuan(_lease!.deposit)}',
                  ),
                  Text(
                    '电${_lease!.electricPrice}/水${_lease!.waterPrice}/燃${_lease!.gasPrice}',
                  ),
                  if (_lease!.effectiveExtras.isNotEmpty)
                    Text(
                      '附加费：${_lease!.effectiveExtras.map((e) => '${e.name} ${formatYuan(e.amount)}').join(' · ')}',
                    ),
                  Text(
                    '起 ${ymdCn(_lease!.startDate)}${_lease!.endDate == null ? ' · 未填结束' : ' 至 ${ymdCn(_lease!.endDate!)}'}',
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _editLease,
                    child: const Text('改租约 / 单价 / 附加费 / 租户'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: _endLease,
                    child: const Text('办理退租'),
                  ),
                  const SizedBox(height: 16),
                  Text('账期（点进结算）', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  ..._periods.map((p) {
                    final paid = p.isPaid;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '${ymdCn(p.dueDate)}  ${formatYuan(p.amount)}  ${paid ? '已收' : (p.status == 'invoiced' ? '已出单' : '未收')}',
                      ),
                      subtitle: Text('${ymdCn(p.periodStart)} – ${ymdCn(p.periodEnd)}'),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => BillPage(periodId: p.id),
                          ),
                        );
                        await _load();
                      },
                      trailing: TextButton(
                        onPressed: () async {
                          if (paid) {
                            await context.read<AppStore>().markUnpaid(p.id);
                          } else {
                            await context.read<AppStore>().markPaid(p.id);
                          }
                          await _load();
                        },
                        child: Text(paid ? '撤销' : '记已收'),
                      ),
                    );
                  }),
                ],
              ],
            ),
    );
  }

  String _md(DateTime d) => md(d);

  Future<void> _editLease() async {
    if (_room == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LeaseFormPage(
          roomId: _room!.id,
          roomLabel: _room!.label,
          lease: _lease,
          tenant: _tenant,
        ),
      ),
    );
    await _load();
  }

  Future<void> _endLease() async {
    final lease = _lease;
    if (lease == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('办理退租？'),
        content: const Text('租约会标为已结束，房间变空房。已收账期保留，未收账期仍在。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认退租'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<AppStore>().endLease(leaseId: lease.id);
      await _load();
    }
  }
}
