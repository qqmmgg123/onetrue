import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../state/app_store.dart';
import 'bill_page.dart';
import 'busy.dart';
import 'format.dart';

/// 未收房源：逾期 / 今天 / 未来 14 天应收。
class RentDuesPage extends StatelessWidget {
  const RentDuesPage({super.key, this.embedded = false});

  /// 嵌在其他页时不显示 AppBar。
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    if (store.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    final overdue = store.overdue;
    final today = store.dueToday;
    final later = store.upcoming14;

    final body = RefreshIndicator(
      onRefresh: store.reload,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (store.pending.isEmpty) ...[
            const Text(
              '还没有未收的账期。先到「求索 → 陋室」加小区、房间和租约。',
              textAlign: TextAlign.center,
            ),
          ],
          if (overdue.isNotEmpty) ...[
            _SectionTitle(label: '逾期', tone: Colors.red.shade700),
            ...overdue.map((e) => _DueTile(item: e)),
          ],
          if (today.isNotEmpty) ...[
            _SectionTitle(
              label: '今天',
              tone: Theme.of(context).colorScheme.primary,
            ),
            ...today.map((e) => _DueTile(item: e)),
          ],
          if (later.isNotEmpty) ...[
            const _SectionTitle(label: '未来 14 天'),
            ...later.map((e) => _DueTile(item: e)),
          ],
          if (store.pending.isNotEmpty &&
              overdue.isEmpty &&
              today.isEmpty &&
              later.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text('14 天内没有应收。更远的账期已生成，到期前会提醒。'),
            ),
        ],
      ),
    );

    if (embedded) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('未收房源')),
      body: body,
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.label, this.tone});

  final String label;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(color: tone),
      ),
    );
  }
}

class _DueTile extends StatelessWidget {
  const _DueTile({required this.item});

  final DueItem item;

  @override
  Widget build(BuildContext context) {
    final store = context.read<AppStore>();
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          '${ymdCn(item.period.dueDate)}  ${item.roomLabel}  应收 ${formatYuan(item.period.amount)}',
        ),
        subtitle: Text(
          [
            item.propertyName,
            if (item.period.remark.trim().isNotEmpty) item.period.remark.trim(),
            '点进结算',
          ].join(' · '),
        ),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => BillPage(periodId: item.period.id),
            ),
          );
        },
        trailing: TextButton(
          onPressed: () async {
            await runBusy(
              context,
              message: '正在记账…',
              task: () => store.markPaid(item.period.id),
            );
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('${item.roomLabel} 已记收款'),
                  action: SnackBarAction(
                    label: '撤销',
                    onPressed: () => store.markUnpaid(item.period.id),
                  ),
                ),
              );
            }
          },
          child: const Text('记已收'),
        ),
      ),
    );
  }
}
