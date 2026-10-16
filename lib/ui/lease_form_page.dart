import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../domain/models.dart';
import '../state/app_store.dart';
import 'format.dart';

class _ExtraRow {
  _ExtraRow({String name = '', String amount = ''})
      : name = TextEditingController(text: name),
        amount = TextEditingController(text: amount);

  final TextEditingController name;
  final TextEditingController amount;

  void dispose() {
    name.dispose();
    amount.dispose();
  }
}

class LeaseFormPage extends StatefulWidget {
  const LeaseFormPage({
    super.key,
    required this.roomId,
    required this.roomLabel,
    this.lease,
    this.tenant,
  });

  final int roomId;
  final String roomLabel;
  final Lease? lease;
  final Tenant? tenant;

  @override
  State<LeaseFormPage> createState() => _LeaseFormPageState();
}

class _LeaseFormPageState extends State<LeaseFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _dueDay;
  late final TextEditingController _rent;
  late final TextEditingController _deposit;
  late final TextEditingController _electric;
  late final TextEditingController _water;
  late final TextEditingController _gas;
  late final List<_ExtraRow> _extras;
  late DateTime _start;
  DateTime? _end;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final lease = widget.lease;
    final tenant = widget.tenant;
    _name = TextEditingController(text: tenant?.name ?? '');
    _phone = TextEditingController(text: tenant?.phone ?? '');
    _dueDay = TextEditingController(
      text: '${lease?.rentDueDay ?? DateTime.now().day}',
    );
    _rent = TextEditingController(
      text: lease == null ? '' : formatYuan(lease.baseRent).replaceAll(',', ''),
    );
    _deposit = TextEditingController(
      text: lease == null ? '' : formatYuan(lease.deposit).replaceAll(',', ''),
    );
    _electric = TextEditingController(
      text: lease == null || lease.electricPrice == 0
          ? ''
          : '${lease.electricPrice}',
    );
    _water = TextEditingController(
      text: lease == null || lease.waterPrice == 0 ? '' : '${lease.waterPrice}',
    );
    _gas = TextEditingController(
      text: lease == null || lease.gasPrice == 0 ? '' : '${lease.gasPrice}',
    );
    final existing = lease?.effectiveExtras ?? const <LeaseExtraItem>[];
    if (existing.isEmpty) {
      _extras = [_ExtraRow()];
    } else {
      _extras = existing
          .map(
            (e) => _ExtraRow(
              name: e.name,
              amount: e.amount == 0 ? '' : '${e.amount}',
            ),
          )
          .toList();
    }
    _start = lease?.startDate ?? dateOnly(DateTime.now());
    _end = lease?.endDate;
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _dueDay.dispose();
    _rent.dispose();
    _deposit.dispose();
    _electric.dispose();
    _water.dispose();
    _gas.dispose();
    for (final e in _extras) {
      e.dispose();
    }
    super.dispose();
  }

  List<LeaseExtraItem> _collectExtras() {
    final out = <LeaseExtraItem>[];
    var i = 0;
    for (final row in _extras) {
      final name = row.name.text.trim();
      final amount = parseYuan(row.amount.text) ?? 0;
      if (name.isEmpty || amount == 0) continue;
      out.add(LeaseExtraItem(name: name, amount: amount, sortOrder: i++));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.lease == null
              ? '登记租约 · ${widget.roomLabel}'
              : '改租约 · ${widget.roomLabel}',
        ),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: '租户姓名'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请填写姓名' : null,
            ),
            TextFormField(
              controller: _phone,
              decoration: const InputDecoration(labelText: '电话（可选）'),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('起租日'),
              subtitle: Text(ymd(_start)),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _start,
                  firstDate: DateTime(2018),
                  lastDate: DateTime(2040),
                );
                if (picked != null) setState(() => _start = dateOnly(picked));
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('结束日（可空，表示还在租）'),
              subtitle: Text(_end == null ? '未填' : ymd(_end!)),
              trailing: _end == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() => _end = null),
                    ),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _end ?? _start,
                  firstDate: DateTime(2018),
                  lastDate: DateTime(2040),
                );
                if (picked != null) setState(() => _end = dateOnly(picked));
              },
            ),
            TextFormField(
              controller: _dueDay,
              decoration: const InputDecoration(labelText: '每月几号收租（1–31）'),
              keyboardType: TextInputType.number,
              validator: (v) {
                final n = int.tryParse(v ?? '');
                if (n == null || n < 1 || n > 31) return '填 1 到 31';
                return null;
              },
            ),
            TextFormField(
              controller: _rent,
              decoration: const InputDecoration(labelText: '月租金（元）'),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: (v) => parseYuan(v ?? '') == null ? '填金额' : null,
            ),
            TextFormField(
              controller: _deposit,
              decoration: const InputDecoration(labelText: '押金（元，可 0）'),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 12),
            Text(
              '单价（元，可空=不按表计费）',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            TextFormField(
              controller: _electric,
              decoration: const InputDecoration(labelText: '电费单价'),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            TextFormField(
              controller: _water,
              decoration: const InputDecoration(labelText: '水费单价'),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            TextFormField(
              controller: _gas,
              decoration: const InputDecoration(labelText: '燃气单价'),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  '每月附加费（可多项）',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => setState(() => _extras.add(_ExtraRow())),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('加一项'),
                ),
              ],
            ),
            Text(
              '例如：物业费 150、网费 50、卫生费 20',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            ...List.generate(_extras.length, (i) {
              final row = _extras[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextFormField(
                        controller: row.name,
                        decoration: const InputDecoration(
                          labelText: '名称',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: row.amount,
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
                      tooltip: '删除这项',
                      onPressed: _extras.length <= 1
                          ? null
                          : () {
                              setState(() {
                                _extras.removeAt(i).dispose();
                              });
                            },
                      icon: const Icon(Icons.remove_circle_outline),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '保存中…' : '保存并生成账期'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await context.read<AppStore>().saveLease(
            leaseId: widget.lease?.id,
            roomId: widget.roomId,
            tenantName: _name.text.trim(),
            tenantPhone: _phone.text.trim(),
            startDate: _start,
            endDate: _end,
            rentDueDay: int.parse(_dueDay.text.trim()),
            baseRent: parseYuan(_rent.text)!,
            deposit: parseYuan(_deposit.text) ?? 0,
            electricPrice: parseYuan(_electric.text) ?? 0,
            waterPrice: parseYuan(_water.text) ?? 0,
            gasPrice: parseYuan(_gas.text) ?? 0,
            extras: _collectExtras(),
          );
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
