import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/baked_env.dart';
import '../media/qiniu_uploader.dart';

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    this.force = false,
    this.changelog = '',
  });

  final int versionCode;
  final String versionName;
  final String apkUrl;
  final bool force;
  final String changelog;

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    final code = json['versionCode'] ?? json['version_code'] ?? 0;
    final name = '${json['versionName'] ?? json['version_name'] ?? ''}';
    final url = '${json['apkUrl'] ?? json['apk_url'] ?? ''}'.trim();
    // 未写 force 时默认强制更新（前期版本需对齐）；仅显式 false 才可跳过
    final forceRaw = json['force'];
    final force = forceRaw == null
        ? true
        : forceRaw == true || '$forceRaw'.toLowerCase() == 'true';
    final notes = '${json['changelog'] ?? json['notes'] ?? ''}'.trim();
    return AppUpdateInfo(
      versionCode: code is int ? code : int.tryParse('$code') ?? 0,
      versionName: name.trim().isEmpty ? '$code' : name.trim(),
      apkUrl: QiniuUploader.playableUrl(url),
      force: force,
      changelog: notes,
    );
  }
}

enum AppUpdatePhase {
  idle,
  checking,
  downloading,
  ready,
  failed,
}

/// 应用内更新：后台拉 APK；强制更新时不可跳过。
class AppUpdateService {
  AppUpdateService._();
  static final AppUpdateService instance = AppUpdateService._();

  static const _kSkipped = 'app_update_skipped_code';
  static const _kReadyCode = 'app_update_ready_code';
  static const _kReadyName = 'app_update_ready_name';
  static const _kReadyPath = 'app_update_ready_path';
  static const _kReadyForce = 'app_update_ready_force';
  static const _kReadyNotes = 'app_update_ready_notes';
  static const _kLastCheck = 'app_update_last_check_ms';

  final _phase = ValueNotifier<AppUpdatePhase>(AppUpdatePhase.idle);
  final _progress = ValueNotifier<double?>(null);
  final _message = ValueNotifier<String>('');
  AppUpdateInfo? _ready;

  ValueNotifier<AppUpdatePhase> get phase => _phase;
  ValueNotifier<double?> get progress => _progress;
  ValueNotifier<String> get message => _message;
  AppUpdateInfo? get readyInfo => _ready;

  bool get hasManifest {
    final u = manifestUrl;
    return u != null && u.isNotEmpty;
  }

  String? get manifestUrl {
    final explicit = BakedEnv.appUpdateManifestUrl.trim();
    if (explicit.isNotEmpty) return explicit;
    final q = BakedEnv.qiniuPublicBase.trim().replaceAll(RegExp(r'/+$'), '');
    if (q.isNotEmpty) return '$q/app/version.json';
    final r = BakedEnv.r2PublicBase.trim().replaceAll(RegExp(r'/+$'), '');
    if (r.isNotEmpty) return '$r/app/version.json';
    return null;
  }

  /// 启动后静默检查；已下载则直接进入 ready。
  Future<void> bootstrap({bool manual = false}) async {
    if (!Platform.isAndroid) return;
    if (!hasManifest) {
      if (manual) {
        _phase.value = AppUpdatePhase.failed;
        _message.value = '未配置更新地址（需七牛/R2 或 APP_UPDATE_MANIFEST_URL）';
      }
      return;
    }

    try {
      final restored = await _restoreReady();
      if (restored != null) {
        _ready = restored;
        _phase.value = AppUpdatePhase.ready;
        _message.value = '新版本 ${restored.versionName} 已就绪';
        _progress.value = 1;
        return;
      }

      _phase.value = AppUpdatePhase.checking;
      _message.value = '正在检查更新…';
      _progress.value = null;

      // 先拉清单：强制更新每次启动都查；非强制才做间隔节流
      final remote = await fetchManifest();
      final prefs = await SharedPreferences.getInstance();
      if (!manual && remote != null && !remote.force) {
        final last = prefs.getInt(_kLastCheck) ?? 0;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - last < const Duration(hours: 6).inMilliseconds) {
          _phase.value = AppUpdatePhase.idle;
          _message.value = '';
          return;
        }
      }
      await prefs.setInt(
        _kLastCheck,
        DateTime.now().millisecondsSinceEpoch,
      );

      if (remote == null) {
        _phase.value = manual ? AppUpdatePhase.failed : AppUpdatePhase.idle;
        if (manual) _message.value = '无法读取版本信息';
        return;
      }

      final info = await PackageInfo.fromPlatform();
      final localCode = int.tryParse(info.buildNumber) ?? 0;
      if (remote.versionCode <= localCode) {
        _phase.value = AppUpdatePhase.idle;
        _message.value = manual ? '已是最新版本（${info.version}）' : '';
        await _clearReady();
        return;
      }

      final skipped = prefs.getInt(_kSkipped) ?? 0;
      if (!manual && !remote.force && skipped >= remote.versionCode) {
        _phase.value = AppUpdatePhase.idle;
        return;
      }

      final wifiOk = await _onWifi();
      if (!wifiOk && !remote.force && !manual) {
        // 非 Wi‑Fi：非强制才推迟；强制更新仍下载
        _phase.value = AppUpdatePhase.idle;
        _message.value = '';
        return;
      }

      await _download(remote);
    } catch (e) {
      _message.value = '检查更新失败：$e';
      // 自动检查失败保持静默，避免启动时闪失败窗；手动检查才标 failed
      _phase.value = manual ? AppUpdatePhase.failed : AppUpdatePhase.idle;
    }
  }

  Future<AppUpdateInfo?> fetchManifest() async {
    final url = manifestUrl;
    if (url == null || url.isEmpty) return null;
    final bust = url.contains('?')
        ? '$url&_=${DateTime.now().millisecondsSinceEpoch}'
        : '$url?_=${DateTime.now().millisecondsSinceEpoch}';
    final res = await http.get(Uri.parse(bust)).timeout(
      const Duration(seconds: 20),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    final decoded = jsonDecode(utf8.decode(res.bodyBytes));
    if (decoded is! Map) return null;
    final info = AppUpdateInfo.fromJson(Map<String, dynamic>.from(decoded));
    if (info.versionCode <= 0 || info.apkUrl.isEmpty) return null;
    return info;
  }

  Future<void> skipReady() async {
    final info = _ready;
    if (info == null) return;
    // 强制更新不允许跳过
    if (info.force) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSkipped, info.versionCode);
    _ready = null;
    _phase.value = AppUpdatePhase.idle;
    _message.value = '';
    _progress.value = null;
  }

  Future<OpenResult> installReady() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_kReadyPath) ?? '';
    if (path.isEmpty || !await File(path).exists()) {
      _phase.value = AppUpdatePhase.failed;
      _message.value = '安装包丢失，请重新检查更新';
      await _clearReady();
      return OpenResult(type: ResultType.error, message: 'missing apk');
    }
    return OpenFilex.open(path, type: 'application/vnd.android.package-archive');
  }

  Future<void> _download(AppUpdateInfo remote) async {
    _phase.value = AppUpdatePhase.downloading;
    _message.value = '正在下载 ${remote.versionName}…';
    _progress.value = 0;

    final dir = await getTemporaryDirectory();
    final out = File(p.join(dir.path, 'rent_agent_update_${remote.versionCode}.apk'));
    final tmp = File('${out.path}.part');

    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(remote.apkUrl));
      final streamed =
          await client.send(req).timeout(const Duration(minutes: 30));
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw StateError('下载失败 HTTP ${streamed.statusCode}');
      }
      final total = streamed.contentLength ?? -1;
      final sink = tmp.openWrite();
      var got = 0;
      var lastReport = DateTime.fromMillisecondsSinceEpoch(0);
      await for (final chunk in streamed.stream) {
        sink.add(chunk);
        got += chunk.length;
        final now = DateTime.now();
        if (total > 0 &&
            now.difference(lastReport).inMilliseconds >= 300) {
          lastReport = now;
          _progress.value = (got / total).clamp(0.0, 1.0);
          _message.value =
              '正在下载 ${remote.versionName}… ${((got / total) * 100).round()}%';
        }
      }
      await sink.close();
      if (await out.exists()) await out.delete();
      await tmp.rename(out.path);
    } catch (e) {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      _phase.value = AppUpdatePhase.failed;
      _message.value = '下载失败：$e';
      rethrow;
    } finally {
      client.close();
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kReadyCode, remote.versionCode);
    await prefs.setString(_kReadyName, remote.versionName);
    await prefs.setString(_kReadyPath, out.path);
    await prefs.setBool(_kReadyForce, remote.force);
    await prefs.setString(_kReadyNotes, remote.changelog);
    // 新版本到来时清掉旧的「稍后」
    final skipped = prefs.getInt(_kSkipped) ?? 0;
    if (skipped < remote.versionCode) {
      await prefs.remove(_kSkipped);
    }

    _ready = remote;
    _phase.value = AppUpdatePhase.ready;
    _progress.value = 1;
    _message.value = '新版本 ${remote.versionName} 已就绪';
  }

  Future<AppUpdateInfo?> _restoreReady() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getInt(_kReadyCode) ?? 0;
    final path = prefs.getString(_kReadyPath) ?? '';
    if (code <= 0 || path.isEmpty) return null;
    final info = await PackageInfo.fromPlatform();
    final localCode = int.tryParse(info.buildNumber) ?? 0;
    if (code <= localCode) {
      await _clearReady();
      return null;
    }
    if (!await File(path).exists()) {
      await _clearReady();
      return null;
    }
    final skipped = prefs.getInt(_kSkipped) ?? 0;
    final force = prefs.getBool(_kReadyForce) ?? false;
    if (!force && skipped >= code) return null;
    return AppUpdateInfo(
      versionCode: code,
      versionName: prefs.getString(_kReadyName) ?? '$code',
      apkUrl: '',
      force: force,
      changelog: prefs.getString(_kReadyNotes) ?? '',
    );
  }

  Future<void> _clearReady() async {
    final prefs = await SharedPreferences.getInstance();
    final path = prefs.getString(_kReadyPath);
    await prefs.remove(_kReadyCode);
    await prefs.remove(_kReadyName);
    await prefs.remove(_kReadyPath);
    await prefs.remove(_kReadyForce);
    await prefs.remove(_kReadyNotes);
    if (path != null && path.isNotEmpty) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  Future<bool> _onWifi() async {
    try {
      final r = await Connectivity().checkConnectivity();
      return r == ConnectivityResult.wifi;
    } catch (_) {
      // 探测失败时允许下载，避免永远更不了
      return true;
    }
  }
}
