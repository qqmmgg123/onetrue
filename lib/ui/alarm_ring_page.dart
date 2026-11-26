import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../reminders/reminder_service.dart';

/// 闹钟响铃页：大按钮关闭 / 延后，持续震动提示（系统闹钟声由通知通道播放）。
class AlarmRingPage extends StatefulWidget {
  const AlarmRingPage({
    super.key,
    required this.noteId,
    required this.alarmId,
    required this.title,
    required this.body,
  });

  final int noteId;
  final int alarmId;
  final String title;
  final String body;

  @override
  State<AlarmRingPage> createState() => _AlarmRingPageState();
}

class _AlarmRingPageState extends State<AlarmRingPage> {
  Timer? _pulse;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _pulse = Timer.periodic(const Duration(seconds: 2), (_) {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      HapticFeedback.heavyImpact();
      SystemSound.play(SystemSoundType.alert);
    });
  }

  @override
  void dispose() {
    _pulse?.cancel();
    super.dispose();
  }

  Future<void> _dismiss() async {
    if (_closing) return;
    _closing = true;
    _pulse?.cancel();
    await ReminderService.instance.dismissAlarm(widget.alarmId);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _snooze() async {
    if (_closing) return;
    _closing = true;
    _pulse?.cancel();
    await ReminderService.instance.snoozeAlarm(
      alarmId: widget.alarmId,
      noteId: widget.noteId,
      title: widget.title,
      body: widget.body,
      minutes: 5,
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async => false,
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0B0B),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '日常提醒',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFFAAAAAA),
                    fontSize: 14,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  widget.body,
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFDDDDDD),
                    fontSize: 18,
                    height: 1.4,
                  ),
                ),
                const Spacer(),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    minimumSize: const Size.fromHeight(56),
                  ),
                  onPressed: _dismiss,
                  child: const Text('关闭', style: TextStyle(fontSize: 18)),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Color(0xFF555555)),
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: _snooze,
                  child: const Text('延后 5 分钟'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
