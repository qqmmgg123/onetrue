import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../domain/models.dart';
import '../domain/note_recur.dart';
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
  /// 房源标签，或笔记类型等展示标签。
  final String roomLabel;
  /// 账期 id，或 note.id。
  final int periodId;
}

class ReminderService {
  ReminderService._();
  static final ReminderService instance = ReminderService._();

  /// 改 channel id 才能让系统重建通道（旧通道关掉声音后改代码无效）。
  static const _rentChannelId = 'rent_alarm_v3';
  static const _noteChannelId = 'note_alarm_v1';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final ReminderSettings settings = ReminderSettings.instance;

  bool _ready = false;
  bool exactAlarmAllowed = true;
  List<ScheduledAlarm> scheduled = [];
  Timer? _testTimer;

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

      try {
        await _android?.requestPermission();
      } catch (e) {
        debugPrint('requestPermission: $e');
      }

      try {
        await _android?.createNotificationChannel(
          const AndroidNotificationChannel(
            _rentChannelId,
            '收租闹钟',
            description: '到期前、当天与逾期的本地闹钟提醒',
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
            showBadge: true,
          ),
        );
        await _android?.createNotificationChannel(
          const AndroidNotificationChannel(
            _noteChannelId,
            '笔记提醒',
            description: '备忘与日程的本地提醒',
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
    try {
      final bat = await Permission.ignoreBatteryOptimizations.status;
      if (!bat.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } catch (e) {
      debugPrint('ignoreBatteryOptimizations: $e');
    }
    await _refreshExactAlarmFlag();
    if (!exactAlarmAllowed) {
      return '系统未允许「闹钟和提醒」。请到：设置 → 应用设置 → 醍醐 → 闹钟和提醒，打开后重试。';
    }
    return null;
  }

  Future<void> showTestInSeconds(int seconds) async {
    final permErr = await ensureAlarmPermissions();
    if (permErr != null) throw StateError(permErr);

    _testTimer?.cancel();
    await _plugin.cancel(999001);
    await _plugin.cancel(999002);

    final when = tz.TZDateTime.now(tz.local).add(Duration(seconds: seconds));
    try {
      await _plugin.zonedSchedule(
        999001,
        '收租闹钟测试',
        '若听到/看到这条，说明本机闹钟通道可用',
        when,
        _rentAlarmDetails(fullscreen: true),
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
        _rentAlarmDetails(fullscreen: true),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    }

    _testTimer = Timer(Duration(seconds: seconds), () async {
      try {
        await _plugin.show(
          999002,
          '收租闹钟测试',
          '前台兜底提醒（若只看到这条，请检查系统「闹钟和提醒」与通知渠道声音）',
          _rentAlarmDetails(fullscreen: true),
        );
      } catch (e) {
        debugPrint('test show failed: $e');
      }
    });
  }

  Future<void> reschedule(
    List<DueItem> pending, {
    List<Note> notes = const [],
  }) async {
    await init();
    scheduled = [];
    final next = <ScheduledAlarm>[];

    for (final item in pending) {
      if (next.length >= 48) break;
      next.addAll(await _planFor(item));
    }

    final now = DateTime.now();
    final horizon = now.add(const Duration(days: 90));
    for (final note in notes) {
      if (note.kind != kNoteKindMemo && note.kind != kNoteKindSchedule) {
        continue;
      }
      final fires = <DateTime>[];
      if (note.kind == kNoteKindSchedule && note.scheduleAt != null) {
        final occ = expandOccurrences(
          note,
          from: now.subtract(const Duration(days: 1)),
          to: horizon,
        );
        final offset =
            note.remindOffsetMin < 0 ? 0 : note.remindOffsetMin;
        for (final start in occ) {
          fires.add(start.subtract(Duration(minutes: offset)));
        }
      } else {
        final when = note.remindAt ?? note.scheduleAt;
        if (when != null) {
          fires.add(when.isUtc ? when.toLocal() : when);
        }
      }
      for (final fire in fires) {
        final localWhen = fire.isUtc ? fire.toLocal() : fire;
        if (!localWhen.isAfter(now.subtract(const Duration(minutes: 1)))) {
          continue;
        }
        if (next.length >= 64) break;
        final stamp =
            '${localWhen.year.toString().padLeft(4, '0')}'
            '${localWhen.month.toString().padLeft(2, '0')}'
            '${localWhen.day.toString().padLeft(2, '0')}'
            '${localWhen.hour.toString().padLeft(2, '0')}'
            '${localWhen.minute.toString().padLeft(2, '0')}';
        final alarmId =
            800000 + ((note.uuid.hashCode.abs() + stamp.hashCode.abs()) % 199999);
        next.add(
          ScheduledAlarm(
            id: alarmId,
            when: localWhen,
            title: note.kindLabel,
            body: note.displayTitle,
            roomLabel: note.kindLabel,
            periodId: note.id,
          ),
        );
      }
      if (next.length >= 64) break;
    }

    if (!notificationsSupported || !settings.enabled) {
      if (notificationsSupported) {
        await _plugin.cancelAll();
      }
      scheduled = next;
      return;
    }

    await _refreshExactAlarmFlag();
    await _plugin.cancelAll();
    next.sort((a, b) => a.when.compareTo(b.when));
    final mode = exactAlarmAllowed
        ? AndroidScheduleMode.alarmClock
        : AndroidScheduleMode.inexactAllowWhileIdle;
    for (final alarm in next) {
      final isRent = alarm.id < 800000;
      await _plugin.zonedSchedule(
        alarm.id,
        alarm.title,
        alarm.body,
        tz.TZDateTime.from(alarm.when, tz.local),
        isRent
            ? _rentAlarmDetails(
                fullscreen:
                    alarm.title == '今天收租' || alarm.title == '逾期未收',
              )
            : _noteAlarmDetails(),
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

  NotificationDetails _rentAlarmDetails({required bool fullscreen}) {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _rentChannelId,
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
        channelShowBadge: true,
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
  }

  NotificationDetails _noteAlarmDetails() {
    return const NotificationDetails(
      android: AndroidNotificationDetails(
        _noteChannelId,
        '笔记提醒',
        channelDescription: '备忘与日程的本地提醒',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.reminder,
        playSound: true,
        enableVibration: true,
        audioAttributesUsage: AudioAttributesUsage.notification,
        visibility: NotificationVisibility.public,
        ticker: '笔记提醒',
        channelShowBadge: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
  }
}
