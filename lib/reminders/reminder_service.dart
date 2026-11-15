import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../domain/models.dart';
import '../domain/note_recur.dart';
import '../platform_init.dart';
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
  /// 兼容旧字段名：现为笔记类型等展示标签。
  final String roomLabel;
  /// 兼容旧字段名：现为 note.id。
  final int periodId;
}

class ReminderService {
  ReminderService._();
  static final ReminderService instance = ReminderService._();

  static const _channelId = 'note_alarm_v1';

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
            _channelId,
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

  /// 请求通知 + 精确闹钟权限。
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
        '提醒测试',
        '若听到/看到这条，说明本机提醒通道可用',
        when,
        _alarmDetails(),
        androidScheduleMode: AndroidScheduleMode.alarmClock,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      debugPrint('alarmClock schedule failed: $e, fallback exact');
      await _plugin.zonedSchedule(
        999001,
        '提醒测试',
        '若听到/看到这条，说明本机提醒通道可用',
        when,
        _alarmDetails(),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    }

    _testTimer = Timer(Duration(seconds: seconds), () async {
      try {
        await _plugin.show(
          999002,
          '提醒测试',
          '前台兜底提醒（若只看到这条，请检查系统「闹钟和提醒」与通知渠道声音）',
          _alarmDetails(),
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
    // 不再根据收租账期排程；pending 参数保留以兼容旧调用。
    scheduled = [];
    final next = <ScheduledAlarm>[];
    final now = DateTime.now();
    final horizon = now.add(const Duration(days: 90));

    for (final note in notes) {
      if (note.kind != kNoteKindMemo && note.kind != kNoteKindSchedule) {
        continue;
      }
      final fires = <DateTime>[];
      if (note.kind == kNoteKindSchedule && note.scheduleAt != null) {
        // remindOffsetMin < 0：明确不提醒
        if (note.remindOffsetMin < 0) {
          continue;
        }
        final occ = expandOccurrences(
          note,
          from: now.subtract(const Duration(days: 1)),
          to: horizon,
        );
        final offset = note.remindOffsetMin;
        for (final start in occ) {
          fires.add(start.subtract(Duration(minutes: offset)));
        }
      } else {
        // 备忘：仅 remindAt；无提醒则跳过（不再回退到 scheduleAt）
        final when = note.remindAt;
        if (when != null) {
          fires.add(when.isUtc ? when.toLocal() : when);
        }
      }
      for (final fire in fires) {
        final localWhen = fire.isUtc ? fire.toLocal() : fire;
        if (!localWhen.isAfter(now.subtract(const Duration(minutes: 1)))) {
          continue;
        }
        if (next.length >= 56) break;
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
      if (next.length >= 56) break;
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
      await _plugin.zonedSchedule(
        alarm.id,
        alarm.title,
        alarm.body,
        tz.TZDateTime.from(alarm.when, tz.local),
        _alarmDetails(),
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
    scheduled = next;
  }

  NotificationDetails _alarmDetails() {
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
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
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
  }
}
