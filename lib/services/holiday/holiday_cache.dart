import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 节假日数据按年缓存到 SharedPreferences。
///
/// - `holiday_data_{year}`:统一格式数据的 JSON 字符串(约 10-20KB/年)。
/// - `holiday_updated_at_{year}`:毫秒时间戳,设置页展示"上次更新"。
class HolidayCache {
  HolidayCache._();

  static String _dataKey(int year) => 'holiday_data_$year';
  static String _updatedAtKey(int year) => 'holiday_updated_at_$year';

  static Future<Map<String, Map<String, dynamic>>?> load(int year) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_dataKey(year));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      final out = <String, Map<String, dynamic>>{};
      decoded.forEach((key, value) {
        if (value is Map<String, dynamic>) out[key] = value;
      });
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(int year, Map<String, Map<String, dynamic>> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dataKey(year), jsonEncode(data));
    await prefs.setInt(_updatedAtKey(year), DateTime.now().millisecondsSinceEpoch);
  }

  static Future<void> clear(int year) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_dataKey(year));
    await prefs.remove(_updatedAtKey(year));
  }

  /// 上次更新时间;从无缓存返回 null。
  static Future<DateTime?> lastUpdated(int year) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_updatedAtKey(year));
      return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    } catch (_) {
      return null;
    }
  }
}
