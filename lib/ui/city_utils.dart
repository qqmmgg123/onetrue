import 'dart:async';
import 'dart:math' as math;

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

/// 常用城市（广场筛选快捷项）。
const kCommonCities = [
  '北京',
  '上海',
  '广州',
  '深圳',
  '杭州',
  '南京',
  '苏州',
  '成都',
  '重庆',
  '武汉',
  '西安',
  '长沙',
  '郑州',
  '天津',
  '青岛',
  '厦门',
  '合肥',
  '福州',
  '济南',
  '宁波',
  '南昌',
  '昆明',
  '大连',
  '无锡',
  '佛山',
];

/// 主要城市中心坐标，作逆地理失败时的兜底（约 80km 内匹配）。
const _cityCenters = <(String, double, double)>[
  ('北京', 39.9042, 116.4074),
  ('上海', 31.2304, 121.4737),
  ('广州', 23.1291, 113.2644),
  ('深圳', 22.5431, 114.0579),
  ('杭州', 30.2741, 120.1551),
  ('南京', 32.0603, 118.7969),
  ('苏州', 31.2989, 120.5853),
  ('成都', 30.5728, 104.0668),
  ('重庆', 29.5630, 106.5516),
  ('武汉', 30.5928, 114.3055),
  ('西安', 34.3416, 108.9398),
  ('长沙', 28.2282, 112.9388),
  ('郑州', 34.7466, 113.6254),
  ('天津', 39.3434, 117.3616),
  ('青岛', 36.0671, 120.3826),
  ('厦门', 24.4798, 118.0894),
  ('合肥', 31.8206, 117.2272),
  ('福州', 26.0745, 119.2965),
  ('济南', 36.6512, 117.1201),
  ('宁波', 29.8683, 121.5440),
  ('南昌', 28.6820, 115.8579),
  ('昆明', 25.0389, 102.7183),
  ('大连', 38.9140, 121.6147),
  ('无锡', 31.4912, 120.3119),
  ('佛山', 23.0215, 113.1214),
  ('东莞', 23.0207, 113.7518),
  ('沈阳', 41.8057, 123.4315),
  ('哈尔滨', 45.8038, 126.5349),
  ('石家庄', 38.0428, 114.5149),
  ('太原', 37.8706, 112.5489),
];

/// 规范化城市名（去「市」等后缀）。
String normalizeCityName(String raw) {
  var s = raw.trim();
  for (final suffix in ['特别行政区', '自治区', '壮族自治区', '回族自治区', '维吾尔自治区', '市', '地区']) {
    if (s.endsWith(suffix) && s.length > suffix.length) {
      s = s.substring(0, s.length - suffix.length);
      break;
    }
  }
  // 「江西省」→ 不要当城市；省名过长则丢弃，交给坐标兜底
  if (s.endsWith('省') && s.length <= 4) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// 尝试定位并解析到城市名；失败返回 null（不抛超时异常）。
Future<String?> detectCityName() async {
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied ||
      permission == LocationPermission.deniedForever) {
    return null;
  }
  final enabled = await Geolocator.isLocationServiceEnabled();
  if (!enabled) return null;

  final pos = await _resolvePosition();
  if (pos == null) return null;

  final fromGeo = await _cityFromGeocoding(pos.latitude, pos.longitude);
  if (fromGeo != null && fromGeo.isNotEmpty) return fromGeo;

  return nearestCity(pos.latitude, pos.longitude);
}

Future<Position?> _resolvePosition() async {
  // 1) 先用缓存，室内/弱 GPS 时也能立刻有结果
  Position? last;
  try {
    last = await Geolocator.getLastKnownPosition();
  } catch (_) {}

  // 2) 低精度（网络/Wi‑Fi），国内比高精度 GPS 快得多
  try {
    return await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.low,
      timeLimit: const Duration(seconds: 8),
      forceAndroidLocationManager: true,
    );
  } on TimeoutException {
    // fall through
  } catch (_) {
    // fall through
  }

  if (last != null) return last;

  // 3) 再试一次稍长超时
  try {
    return await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.low,
      timeLimit: const Duration(seconds: 15),
      forceAndroidLocationManager: true,
    );
  } catch (_) {
    return last;
  }
}

Future<String?> _cityFromGeocoding(double lat, double lng) async {
  try {
    final places = await placemarkFromCoordinates(lat, lng)
        .timeout(const Duration(seconds: 6));
    if (places.isEmpty) return null;
    final p = places.first;
    for (final candidate in [
      p.locality,
      p.subAdministrativeArea,
      p.administrativeArea,
    ]) {
      final raw = candidate?.trim() ?? '';
      if (raw.isEmpty) continue;
      final n = normalizeCityName(raw);
      if (n.isEmpty) continue;
      // 省名通常不是广场筛选项，跳过过宽的「江西」类结果，交给坐标兜底
      if (_looksLikeProvinceOnly(n, raw)) continue;
      return n;
    }
  } catch (_) {}
  return null;
}

bool _looksLikeProvinceOnly(String normalized, String raw) {
  const provinces = {
    '河北', '山西', '辽宁', '吉林', '黑龙江', '江苏', '浙江', '安徽', '福建', '江西',
    '山东', '河南', '湖北', '湖南', '广东', '海南', '四川', '贵州', '云南', '陕西',
    '甘肃', '青海', '台湾', '内蒙古', '广西', '西藏', '宁夏', '新疆',
  };
  return provinces.contains(normalized) && !raw.contains('市');
}

/// 按直线距离找最近城市中心（阈值约 100km）。
String? nearestCity(double lat, double lng, {double maxKm = 100}) {
  String? best;
  var bestKm = maxKm;
  for (final (name, clat, clng) in _cityCenters) {
    final d = _haversineKm(lat, lng, clat, clng);
    if (d < bestKm) {
      bestKm = d;
      best = name;
    }
  }
  return best;
}

double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = _rad(lat2 - lat1);
  final dLon = _rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(_rad(lat1)) *
          math.cos(_rad(lat2)) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  return 2 * r * math.asin(math.sqrt(a));
}

double _rad(double deg) => deg * math.pi / 180;
