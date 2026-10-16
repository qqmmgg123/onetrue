import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../state/app_store.dart';
import 'bill_page.dart';
import 'format.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    if (store.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (store.error != null) {
      return Center(child: Text('加载失败：${store.error}'));
    }

    final overdue = store.overdue;
    final today = store.dueToday;
    final later = store.upcoming14;

    return RefreshIndicator(
      onRefresh: store.reload,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Text('应收', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text(
            '看整月请到「日历」。闹钟在 App 内按账本自动排，不同步系统日历。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (store.pending.isEmpty) ...[
            const Text('还没有未收的账期。先到「房源」里加小区、房间和租约。'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () async {
                await store.seedDemo();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已写入 302 / 张三，本月到期日为今天')),
                  );
                }
              },
              child: const Text('填入一条演示数据'),
            ),
          ],
          if (overdue.isNotEmpty) ...[
            _SectionTitle(label: '逾期', tone: Colors.red.shade700),
            ...overdue.map((e) => DueTile(item: e)),
          ],
          if (today.isNotEmpty) ...[
            _SectionTitle(label: '今天', tone: Theme.of(context).colorScheme.primary),
            ...today.map((e) => DueTile(item: e)),
          ],
          if (later.isNotEmpty) ...[
            const _SectionTitle(label: '未来 14 天'),
            ...later.map((e) => DueTile(item: e)),
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

class DueTile extends StatelessWidget {
  const DueTile({super.key, required this.item});

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
        subtitle: Text('${item.propertyName} · ${item.tenantName} · 点进结算'),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => BillPage(periodId: item.period.id),
            ),
          );
        },
        trailing: TextButton(
          onPressed: () async {
            await store.markPaid(item.period.id);
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
