import 'package:shared_preferences/shared_preferences.dart';

/// 节假日数据源配置。
///
/// - 主 API + 备用 API 列表均使用 `{year}` 占位符,请求时替换为目标年份。
/// - 持久化在 SharedPreferences;读不到/非法时回落到内置默认值。
class HolidayApiConfig {
  static const String defaultPrimaryApi =
      'https://publicapi.xiaoai.me/holiday/year?date={year}';

  static const List<String> defaultBackupApis = [
    'https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master/{year}.json',
    'https://fastly.jsdelivr.net/gh/NateScarlet/holiday-cn@master/{year}.json',
  ];

  static const _primaryKey = 'holiday_api_primary';
  static const _backupsKey = 'holiday_api_backups';

  final String primaryApi;
  final List<String> backupApis;

  const HolidayApiConfig({
    required this.primaryApi,
    required this.backupApis,
  });

  static const HolidayApiConfig defaultConfig = HolidayApiConfig(
    primaryApi: defaultPrimaryApi,
    backupApis: defaultBackupApis,
  );

  /// 从本地读取配置。两个键都不存在(从未配置/已恢复默认)时回落内置默认;
  /// 存在则完全按用户配置(备用列表允许为空),主 API 非法时回落默认。
  static Future<HolidayApiConfig> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasPrimary = prefs.containsKey(_primaryKey);
      final hasBackups = prefs.containsKey(_backupsKey);
      if (!hasPrimary && !hasBackups) return defaultConfig;
      final primary = prefs.getString(_primaryKey);
      final backups = prefs.getStringList(_backupsKey) ?? const [];
      return HolidayApiConfig(
        primaryApi: isValidTemplate(primary) ? primary! : defaultPrimaryApi,
        backupApis: backups.where(isValidTemplate).toList(growable: false),
      );
    } catch (_) {
      return defaultConfig;
    }
  }

  static Future<void> save({
    required String primaryApi,
    required List<String> backupApis,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_primaryKey, primaryApi.trim());
    await prefs.setStringList(
      _backupsKey,
      backupApis.map((e) => e.trim()).where(isValidTemplate).toList(),
    );
  }

  static Future<void> resetToDefault() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_primaryKey);
    await prefs.remove(_backupsKey);
  }

  /// 合法的 API 模板:必须是 http(s) URL 且带 `{year}` 占位符。
  static bool isValidTemplate(String? url) {
    if (url == null) return false;
    final trimmed = url.trim();
    final isHttp =
        trimmed.startsWith('http://') || trimmed.startsWith('https://');
    final hasHost = Uri.tryParse(trimmed)?.host.isNotEmpty ?? false;
    return isHttp && hasHost && trimmed.contains('{year}');
  }
}
