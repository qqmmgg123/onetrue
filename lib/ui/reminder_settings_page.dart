import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../reminders/reminder_service.dart';
import '../reminders/reminder_settings.dart';
import '../state/app_store.dart';

class ReminderSettingsPage extends StatefulWidget {
  const ReminderSettingsPage({super.key});

  @override
  State<ReminderSettingsPage> createState() => _ReminderSettingsPageState();
}

class _ReminderSettingsPageState extends State<ReminderSettingsPage> {
  final _settings = ReminderSettings.instance;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _settings.load();
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('收租闹钟')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用闹钟提醒'),
                  subtitle: const Text('只在本 App 排程，不写入系统日历'),
                  value: _settings.enabled,
                  onChanged: (v) => setState(() => _settings.enabled = v),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('提醒时刻'),
                  subtitle: Text(
                    '每天 ${_settings.hour.toString().padLeft(2, '0')}:00',
                  ),
                  trailing: const Icon(Icons.schedule),
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(hour: _settings.hour, minute: 0),
                      builder: (context, child) {
                        return MediaQuery(
                          data: MediaQuery.of(context).copyWith(
                            alwaysUse24HourFormat: true,
                          ),
                          child: child!,
                        );
                      },
                    );
                    if (picked != null) {
                      setState(() => _settings.hour = picked.hour);
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('提前几天提醒'),
                  subtitle: Text('${_settings.advanceDays} 天（另有到期当天与逾期催收）'),
                ),
                Slider(
                  value: _settings.advanceDays.toDouble(),
                  min: 0,
                  max: 7,
                  divisions: 7,
                  label: '${_settings.advanceDays} 天',
                  onChanged: (v) =>
                      setState(() => _settings.advanceDays = v.round()),
                ),
                if (!ReminderService.instance.exactAlarmAllowed)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        '系统未允许精确闹钟，提醒可能被推迟。'
                        '请到系统设置里给「缘初」打开精确闹钟权限。',
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  '记已收或改租约后，闹钟会按账本自动重排；已收款的账期不再响铃。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () async {
                    await _settings.save(
                      hour: _settings.hour,
                      enabled: _settings.enabled,
                      advanceDays: _settings.advanceDays,
                    );
                    if (!mounted) return;
                    await context.read<AppStore>().reload();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已保存并重新排程')),
                    );
                    Navigator.pop(context);
                  },
                  child: const Text('保存并重排闹钟'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () async {
                    try {
                      await ReminderService.instance.showTestInSeconds(8);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('约 8 秒后应弹出闹钟测试')),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('$e')),
                      );
                    }
                  },
                  child: const Text('8 秒后测试闹钟'),
                ),
              ],
            ),
    );
  }
}
