import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../domain/models.dart';
import '../platform_init.dart';
import '../ui/format.dart';
import 'reminder_settings.dart';

class ScheduledAlarm {
  const ScheduledAlarm({
    required this.id,
    required this.when,
    required this.title,
    required this.body,
    required this.roomLabel,
    required this.periodId,
  });

  final int id;
  final DateTime when;
  final String title;
  final String body;
  final String roomLabel;
  final int periodId;
}

class ReminderService {
  ReminderService._();
  static final ReminderService instance = ReminderService._();

  static const _channelId = 'rent_alarm_v2';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final ReminderSettings settings = ReminderSettings.instance;

  bool _ready = false;
  bool exactAlarmAllowed = true;
  List<ScheduledAlarm> scheduled = [];

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  Future<void> init() async {
    if (_ready) return;
    try {
      tzdata.initializeTimeZones();
      try {
        tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
      } catch (_) {
        tz.setLocalLocation(tz.UTC);
      }
      await settings.load();
      if (!notificationsSupported) {
        _ready = true;
        return;
      }

      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const ios = DarwinInitializationSettings();
      await _plugin.initialize(
        const InitializationSettings(android: android, iOS: ios),
      );

      // 小米/Android 13+：通知权限
      try {
        await _android?.requestPermission();
      } catch (e) {
        debugPrint('requestPermission: $e');
      }

      // 显式建高优先级闹钟通道（带声音振动）
      try {
        await _android?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            '收租闹钟',
            description: '到期前、当天与逾期的本地闹钟提醒',
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
            showBadge: true,
          ),
        );
      } catch (e) {
        debugPrint('createNotificationChannel: $e');
      }

      await _refreshExactAlarmFlag();
    } finally {
      _ready = true;
    }
  }

  Future<void> _refreshExactAlarmFlag() async {
    try {
      final canExact = await _android?.canScheduleExactNotifications();
      exactAlarmAllowed = canExact ?? true;
    } catch (_) {
      exactAlarmAllowed = true;
    }
  }

  /// 请求通知 + 精确闹钟权限（小米上常需用户去系统页打开）。
  Future<String?> ensureAlarmPermissions() async {
    await init();
    if (!notificationsSupported) {
      return '桌面版没有系统闹钟，请用 Android 手机测试。';
    }
    try {
      await _android?.requestPermission();
    } catch (_) {}
    try {
      // Android 12+ 精确闹钟（小米常默认关）
      final status = await Permission.scheduleExactAlarm.request();
      debugPrint('scheduleExactAlarm: $status');
      if (!status.isGranted) {
        await openAppSettings();
      }
    } catch (e) {
      debugPrint('scheduleExactAlarm request: $e');
    }
    try {
      await Permission.notification.request();
    } catch (_) {}
    await _refreshExactAlarmFlag();
    if (!exactAlarmAllowed) {
      return '系统未允许「闹钟和提醒」。请到：设置 → 应用设置 → 收租助手 → 闹钟和提醒，打开后重试。';
    }
    return null;
  }

  Future<void> showTestInSeconds(int seconds) async {
    final permErr = await ensureAlarmPermissions();
    if (permErr != null) throw StateError(permErr);

    final when = tz.TZDateTime.now(tz.local).add(Duration(seconds: seconds));
    // alarmClock 比 exactAllowWhileIdle 更不易被小米省电杀掉
    try {
      await _plugin.zonedSchedule(
        999001,
        '收租闹钟测试',
        '若听到/看到这条，说明本机闹钟通道可用',
        when,
        _alarmDetails(fullscreen: true),
        androidScheduleMode: AndroidScheduleMode.alarmClock,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      debugPrint('alarmClock schedule failed: $e, fallback exact');
      await _plugin.zonedSchedule(
        999001,
        '收租闹钟测试',
        '若听到/看到这条，说明本机闹钟通道可用',
        when,
        _alarmDetails(fullscreen: true),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
  }

  Future<void> reschedule(List<DueItem> pending) async {
    await init();
    scheduled = [];
    if (!notificationsSupported || !settings.enabled) {
      if (notificationsSupported) {
        await _plugin.cancelAll();
      }
      return;
    }

    await _refreshExactAlarmFlag();
    await _plugin.cancelAll();
    final next = <ScheduledAlarm>[];
    for (final item in pending) {
      if (next.length >= 48) break;
      next.addAll(await _planFor(item));
    }
    next.sort((a, b) => a.when.compareTo(b.when));
    final mode = exactAlarmAllowed
        ? AndroidScheduleMode.alarmClock
        : AndroidScheduleMode.inexactAllowWhileIdle;
    for (final alarm in next) {
      await _plugin.zonedSchedule(
        alarm.id,
        alarm.title,
        alarm.body,
        tz.TZDateTime.from(alarm.when, tz.local),
        _alarmDetails(
          fullscreen: alarm.title == '今天收租' || alarm.title == '逾期未收',
        ),
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
    scheduled = next;
  }

  Future<List<ScheduledAlarm>> _planFor(DueItem item) async {
    final due = dateOnly(item.period.dueDate);
    final body =
        '${md(due)} ${item.roomLabel} 应收 ${formatYuan(item.period.amount)}';
    final plans = <ScheduledAlarm>[];
    final now = tz.TZDateTime.now(tz.local);

    if (settings.advanceDays > 0) {
      final advance = due.subtract(Duration(days: settings.advanceDays));
      final when = _atHour(advance);
      if (when.isAfter(now)) {
        plans.add(
          ScheduledAlarm(
            id: item.period.id * 10,
            when: when,
            title: '还有 ${settings.advanceDays} 天收租',
            body: body,
            roomLabel: item.roomLabel,
            periodId: item.period.id,
          ),
        );
      }
    }

    final dueWhen = _atHour(due);
    if (dueWhen.isAfter(now)) {
      plans.add(
        ScheduledAlarm(
          id: item.period.id * 10 + 1,
          when: dueWhen,
          title: '今天收租',
          body: body,
          roomLabel: item.roomLabel,
          periodId: item.period.id,
        ),
      );
    }

    final today = dateOnly(DateTime.now());
    if (due.isBefore(today)) {
      for (var i = 0; i < 7; i++) {
        final day = today.add(Duration(days: i));
        final when = _atHour(day);
        if (!when.isAfter(now)) continue;
        plans.add(
          ScheduledAlarm(
            id: item.period.id * 10 + 2 + i,
            when: when,
            title: '逾期未收',
            body: body,
            roomLabel: item.roomLabel,
            periodId: item.period.id,
          ),
        );
      }
    }
    return plans;
  }

  DateTime _atHour(DateTime day) {
    return tz.TZDateTime(
      tz.local,
      day.year,
      day.month,
      day.day,
      settings.hour,
    );
  }

  NotificationDetails _alarmDetails({required bool fullscreen}) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        '收租闹钟',
        channelDescription: '到期前、当天与逾期的本地闹钟提醒（不写入系统日历）',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        fullScreenIntent: fullscreen,
        playSound: true,
        enableVibration: true,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        visibility: NotificationVisibility.public,
        ticker: '收租提醒',
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
  }
}
