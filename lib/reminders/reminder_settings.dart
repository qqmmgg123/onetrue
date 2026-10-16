import 'package:shared_preferences/shared_preferences.dart';

class ReminderSettings {
  ReminderSettings._();
  static final ReminderSettings instance = ReminderSettings._();

  static const _kHour = 'reminder_hour';
  static const _kEnabled = 'reminder_enabled';
  static const _kAdvanceDays = 'reminder_advance_days';

  /// 每天几点响（0–23），默认早上 9 点。
  int hour = 9;
  bool enabled = true;
  /// 到期前几天提醒，默认 3。
  int advanceDays = 3;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    hour = prefs.getInt(_kHour) ?? 9;
    enabled = prefs.getBool(_kEnabled) ?? true;
    advanceDays = prefs.getInt(_kAdvanceDays) ?? 3;
    if (hour < 0 || hour > 23) hour = 9;
    if (advanceDays < 0) advanceDays = 0;
    if (advanceDays > 14) advanceDays = 14;
  }

  Future<void> save({
    int? hour,
    bool? enabled,
    int? advanceDays,
  }) async {
    if (hour != null) this.hour = hour.clamp(0, 23);
    if (enabled != null) this.enabled = enabled;
    if (advanceDays != null) this.advanceDays = advanceDays.clamp(0, 14);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kHour, this.hour);
    await prefs.setBool(_kEnabled, this.enabled);
    await prefs.setInt(_kAdvanceDays, this.advanceDays);
  }
}
