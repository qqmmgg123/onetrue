import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../app_nav.dart';
import '../domain/models.dart';
import '../domain/note_recur.dart';
import '../platform_init.dart';
import '../ui/alarm_ring_page.dart';
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

  /// 新通道：闹钟类别 + 角标；旧 channel 无法改 importance，故换 id。
  static const _channelId = 'note_alarm_v2';
  /// 测试/兜底抬头通知（避免 fullScreen+ongoing 在部分机型上 show 直接失败）
  static const _headsUpChannelId = 'note_alarm_headsup_v1';
  static const actionDismiss = 'alarm_dismiss';
  static const actionSnooze = 'alarm_snooze';

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
      const ios = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      await _plugin.initialize(
        const InitializationSettings(android: android, iOS: ios),
        onDidReceiveNotificationResponse: _onNotificationResponse,
        onDidReceiveBackgroundNotificationResponse:
            reminderNotificationBackground,
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
            '日常闹钟',
            description: '日程提醒：响铃、全屏、关闭/延后',
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
            showBadge: true,
          ),
        );
        await _android?.createNotificationChannel(
          const AndroidNotificationChannel(
            _headsUpChannelId,
            '提醒抬头',
            description: '测试与兜底通知',
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
      await _openLaunchDetailsIfNeeded();
    } finally {
      _ready = true;
    }
  }

  Future<void> _openLaunchDetailsIfNeeded() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return;
      final resp = details!.notificationResponse;
      if (resp == null) return;
      // 冷启动稍后再跳，等 Navigator 挂上
      Future<void>.delayed(const Duration(milliseconds: 600), () {
        _onNotificationResponse(resp);
      });
    } catch (e) {
      debugPrint('launchDetails: $e');
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

    const title = '提醒测试';
    const body = '若出现响铃页或通知，说明本机提醒通道可用';
    final when = tz.TZDateTime.now(tz.local).add(Duration(seconds: seconds));
    final payload = _encodePayload(
      noteId: 0,
      alarmId: 999001,
      title: title,
      body: body,
    );
    final details = _headsUpDetails(badgeCount: 1);
    try {
      await _plugin.zonedSchedule(
        999001,
        title,
        body,
        when,
        details,
        androidScheduleMode: AndroidScheduleMode.alarmClock,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payload,
      );
    } catch (e) {
      debugPrint('alarmClock schedule failed: $e, fallback exact');
      try {
        await _plugin.zonedSchedule(
          999001,
          title,
          body,
          when,
          details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          payload: payload,
        );
      } catch (e2) {
        debugPrint('exact schedule failed: $e2');
      }
    }

    _testTimer = Timer(Duration(seconds: seconds), () async {
      // 无论系统通知是否成功，都弹出响铃页，避免「什么都没有」
      try {
        await _plugin.show(
          999002,
          title,
          '前台兜底提醒（若只看到响铃页，请检查通知权限）',
          details,
          payload: _encodePayload(
            noteId: 0,
            alarmId: 999002,
            title: title,
            body: body,
          ),
        );
      } catch (e) {
        debugPrint('test show failed: $e');
      }
      try {
        await _syncBadge(1);
      } catch (_) {}
      _openAlarmRing(
        noteId: 0,
        alarmId: 999002,
        title: title,
        body: body,
      );
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
      // 备忘不再排本地提醒；仅日程（含重复展开）。
      if (note.kind != kNoteKindSchedule || note.scheduleAt == null) {
        continue;
      }
      final fires = <DateTime>[];
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
      await _syncBadge(0);
      return;
    }

    await _refreshExactAlarmFlag();
    await _plugin.cancelAll();
    next.sort((a, b) => a.when.compareTo(b.when));
    final mode = exactAlarmAllowed
        ? AndroidScheduleMode.alarmClock
        : AndroidScheduleMode.inexactAllowWhileIdle;
    final badge = _badgeCountFor(next, now);
    for (final alarm in next) {
      await _plugin.zonedSchedule(
        alarm.id,
        alarm.title,
        alarm.body,
        tz.TZDateTime.from(alarm.when, tz.local),
        _alarmDetails(badgeCount: badge),
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: _encodePayload(
          noteId: alarm.periodId,
          alarmId: alarm.id,
          title: alarm.title,
          body: alarm.body,
        ),
      );
    }
    scheduled = next;
    await _syncBadge(badge);
  }

  int _badgeCountFor(List<ScheduledAlarm> alarms, DateTime now) {
    final end = now.add(const Duration(hours: 36));
    final n = alarms.where((a) => !a.when.isAfter(end)).length;
    return n.clamp(0, 99);
  }

  static const _badgeChannel = MethodChannel('rent_agent/badge');

  Future<void> _syncBadge(int count) async {
    if (!notificationsSupported) return;
    try {
      if (count <= 0) {
        await _badgeChannel.invokeMethod<void>('clear');
      } else {
        await _badgeChannel.invokeMethod<void>('set', {'count': count});
      }
    } catch (e) {
      // 未实现 / 桌面不支持角标时忽略
      debugPrint('badge: $e');
    }
  }

  /// 打开 App / 看完待办时清角标。
  Future<void> clearBadge() => _syncBadge(0);

  Future<void> dismissAlarm(int alarmId) async {
    await init();
    try {
      await _plugin.cancel(alarmId);
    } catch (_) {}
    // 测试兜底 id
    if (alarmId == 999001 || alarmId == 999002) {
      try {
        await _plugin.cancel(999001);
        await _plugin.cancel(999002);
      } catch (_) {}
    }
    await clearBadge();
  }

  Future<void> snoozeAlarm({
    required int alarmId,
    required int noteId,
    required String title,
    required String body,
    int minutes = 5,
  }) async {
    await init();
    await dismissAlarm(alarmId);
    final when = tz.TZDateTime.now(tz.local).add(Duration(minutes: minutes));
    final newId = alarmId == 0 ? 999010 : alarmId;
    final payload = _encodePayload(
      noteId: noteId,
      alarmId: newId,
      title: title,
      body: body,
    );
    final mode = exactAlarmAllowed
        ? AndroidScheduleMode.alarmClock
        : AndroidScheduleMode.exactAllowWhileIdle;
    try {
      await _plugin.zonedSchedule(
        newId,
        title,
        body,
        when,
        _alarmDetails(badgeCount: 1),
        androidScheduleMode: mode,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payload,
      );
    } catch (e) {
      debugPrint('snooze schedule: $e');
      await _plugin.zonedSchedule(
        newId,
        title,
        body,
        when,
        _alarmDetails(badgeCount: 1),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payload,
      );
    }
    await _syncBadge(1);
  }

  void _onNotificationResponse(NotificationResponse response) {
    final parsed = _decodePayload(response.payload);
    final action = response.actionId;
    if (action == actionDismiss) {
      unawaited(dismissAlarm(parsed.alarmId));
      return;
    }
    if (action == actionSnooze) {
      unawaited(
        snoozeAlarm(
          alarmId: parsed.alarmId,
          noteId: parsed.noteId,
          title: parsed.title,
          body: parsed.body,
        ),
      );
      return;
    }
    // 点通知本体 / 全屏意图 → 响铃页
    _openAlarmRing(
      noteId: parsed.noteId,
      alarmId: parsed.alarmId,
      title: parsed.title.isEmpty ? '日常提醒' : parsed.title,
      body: parsed.body,
    );
  }

  void _openAlarmRing({
    required int noteId,
    required int alarmId,
    required String title,
    required String body,
  }) {
    final nav = appNavigatorKey.currentState;
    if (nav == null) {
      Future<void>.delayed(const Duration(milliseconds: 400), () {
        _openAlarmRing(
          noteId: noteId,
          alarmId: alarmId,
          title: title,
          body: body,
        );
      });
      return;
    }
    nav.push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => AlarmRingPage(
          noteId: noteId,
          alarmId: alarmId,
          title: title,
          body: body,
        ),
      ),
    );
  }

  String _encodePayload({
    required int noteId,
    required int alarmId,
    required String title,
    required String body,
  }) {
    return 'v1|$noteId|$alarmId|${Uri.encodeComponent(title)}|${Uri.encodeComponent(body)}';
  }

  ({int noteId, int alarmId, String title, String body}) _decodePayload(
    String? raw,
  ) {
    if (raw == null || raw.isEmpty) {
      return (noteId: 0, alarmId: 0, title: '日常提醒', body: '');
    }
    final parts = raw.split('|');
    if (parts.length < 5 || parts[0] != 'v1') {
      return (noteId: 0, alarmId: 0, title: '日常提醒', body: raw);
    }
    return (
      noteId: int.tryParse(parts[1]) ?? 0,
      alarmId: int.tryParse(parts[2]) ?? 0,
      title: Uri.decodeComponent(parts[3]),
      body: Uri.decodeComponent(parts[4]),
    );
  }

  NotificationDetails _headsUpDetails({
    required int badgeCount,
  }) {
    final n = badgeCount <= 0 ? 1 : badgeCount;
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _headsUpChannelId,
        '提醒抬头',
        channelDescription: '测试与兜底通知',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.reminder,
        playSound: true,
        enableVibration: true,
        audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
        visibility: NotificationVisibility.public,
        ticker: '提醒测试',
        channelShowBadge: true,
        number: n,
        fullScreenIntent: false,
        ongoing: false,
        autoCancel: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        badgeNumber: n,
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );
  }

  NotificationDetails _alarmDetails({
    required int badgeCount,
  }) {
    final n = badgeCount <= 0 ? 1 : badgeCount;
    return NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        '日常闹钟',
        channelDescription: '日程提醒：响铃、全屏、关闭/延后',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.alarm,
        playSound: true,
        enableVibration: true,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        visibility: NotificationVisibility.public,
        ticker: '日常提醒',
        channelShowBadge: true,
        number: n,
        fullScreenIntent: true,
        ongoing: true,
        autoCancel: false,
        actions: const <AndroidNotificationAction>[
          AndroidNotificationAction(
            actionDismiss,
            '关闭',
            cancelNotification: true,
            showsUserInterface: false,
          ),
          AndroidNotificationAction(
            actionSnooze,
            '延后 5 分钟',
            cancelNotification: true,
            showsUserInterface: false,
          ),
        ],
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        badgeNumber: n,
        interruptionLevel: InterruptionLevel.timeSensitive,
      ),
    );
  }
}

@pragma('vm:entry-point')
void reminderNotificationBackground(NotificationResponse response) {
  // 后台点「关闭 / 延后」：尽量处理；完整 UI 等进前台。
  Future<void>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    final svc = ReminderService.instance;
    await svc.init();
    final parts = (response.payload ?? '').split('|');
    final noteId = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    final alarmId = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;
    final title = parts.length > 3
        ? Uri.decodeComponent(parts[3])
        : '日常提醒';
    final body = parts.length > 4 ? Uri.decodeComponent(parts[4]) : '';
    if (response.actionId == ReminderService.actionDismiss) {
      await svc.dismissAlarm(alarmId);
    } else if (response.actionId == ReminderService.actionSnooze) {
      await svc.snoozeAlarm(
        alarmId: alarmId,
        noteId: noteId,
        title: title,
        body: body,
      );
    }
  });
}
