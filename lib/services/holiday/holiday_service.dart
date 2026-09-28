import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../system/logger_service.dart';
import 'holiday_api_config.dart';
import 'holiday_cache.dart';
import 'holiday_parser.dart';

/// 中国法定节假日/调休数据服务(供"仅工作日/仅节假日"周期记账判断)。
///
/// 数据流:内存 → 本地按年缓存 → 主 API → 备用 API 列表 → 简单周末判断。
/// 所有网络异常都吞掉并降级,绝不抛出阻塞记账主流程。
class HolidayService {
  static final HolidayService instance = HolidayService._();

  static const _tag = 'Holiday';

  /// 单个 API 请求超时。链式回退时逐个尝试,最坏情况受
  /// [fetchTimeoutBudget] 约束(周期生成路径用它限制总阻塞时长)。
  static const requestTimeout = Duration(seconds: 10);

  /// 周期生成路径等待整条回退链的总预算;超时后本次判断降级为周末判断,
  /// 拉取仍在后台继续,缓存写好后下次生效。
  static const fetchTimeoutBudget = Duration(seconds: 15);

  HolidayService._();

  /// 内存中的年份数据(key: 年份)。同步判断只读这里,不碰 IO。
  final Map<int, Map<String, Map<String, dynamic>>> _memory = {};

  /// 进行中的拉取任务(key: 年份),避免并发重复请求。
  final Map<int, Future<bool>> _fetching = {};

  HolidayApiConfig? _config;

  HolidayApiConfig get config => _config ?? HolidayApiConfig.defaultConfig;

  Future<HolidayApiConfig> loadConfig() async {
    _config ??= await HolidayApiConfig.load();
    return _config!;
  }

  Future<void> reloadConfig() async {
    _config = await HolidayApiConfig.load();
  }

  /// 确保某年数据在内存中:先查内存,再查本地缓存,[allowNetwork] 为 true
  /// 且缓存缺失时走网络回退链。返回是否拿到了数据。
  Future<bool> ensureYearLoaded(int year, {bool allowNetwork = true}) async {
    if (_memory.containsKey(year)) return true;
    final cached = await HolidayCache.load(year);
    if (cached != null) {
      _memory[year] = cached;
      logger.info(_tag, '$year 年数据来自本地缓存,共 ${cached.length} 条');
      return true;
    }
    if (!allowNetwork) return false;
    return fetchAndCacheYear(year);
  }

  /// 拉取某年数据:主 API → 备用 API 列表,任一成功即写缓存并返回 true。
  /// 同一年份的并发请求共享同一个 Future。
  Future<bool> fetchAndCacheYear(int year) {
    final existing = _fetching[year];
    if (existing != null) return existing;
    final task = _doFetch(year).whenComplete(() => _fetching.remove(year));
    _fetching[year] = task;
    return task;
  }

  Future<bool> _doFetch(int year) async {
    final cfg = await loadConfig();
    final templates = [cfg.primaryApi, ...cfg.backupApis];
    for (final template in templates) {
      if (!HolidayApiConfig.isValidTemplate(template)) continue;
      final url = template.replaceAll('{year}', year.toString());
      try {
        logger.info(_tag, '拉取 $year 年节假日数据: $url');
        final response = await http.get(Uri.parse(url)).timeout(requestTimeout);
        if (response.statusCode != 200) {
          logger.warning(_tag, '$url 返回 ${response.statusCode},尝试下一数据源');
          continue;
        }
        final data = HolidayParser.tryParse(response.body);
        if (data == null) {
          logger.warning(_tag, '$url 响应无法解析,尝试下一数据源');
          continue;
        }
        _memory[year] = data;
        await HolidayCache.save(year, data);
        logger.info(_tag, '$year 年数据拉取成功: $url,共 ${data.length} 条');
        return true;
      } catch (e) {
        logger.warning(_tag, '$url 请求失败: $e,尝试下一数据源');
      }
    }
    logger.warning(_tag, '$year 年所有数据源均失败,将降级为简单周末判断');
    return false;
  }

  /// 判断是否工作日(周一至五 + 调休上班日,排除法定节假日)。
  /// 该日期不在数据集里时回退到简单周末判断。
  bool isWorkday(DateTime date) {
    final entry = _memory[date.year]?[_formatDate(date)];
    if (entry != null) return entry['isWorkday'] == true;
    return _isSimpleWorkday(date);
  }

  /// 判断是否节假日/非工作日(周末 + 法定节假日,排除调休上班日)。
  bool isHoliday(DateTime date) => !isWorkday(date);

  /// 周期频率对应的判断:workday → isWorkday,holiday → isHoliday。
  bool qualifies(DateTime date, bool wantWorkday) =>
      wantWorkday ? isWorkday(date) : isHoliday(date);

  bool _isSimpleWorkday(DateTime date) => date.weekday >= 1 && date.weekday <= 5;

  String _formatDate(DateTime date) {
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    return '${date.year}-$mm-$dd';
  }

  /// 应用启动时调用:确保当年数据可用(有缓存则不请求网络)。
  Future<void> ensureCurrentYearData() => ensureYearLoaded(DateTime.now().year);

  /// 12 月后预拉下一年数据,跨年切换时不至于断档。
  Future<void> ensureNextYearDataIfNeeded() {
    final now = DateTime.now();
    if (now.month == 12) return ensureYearLoaded(now.year + 1);
    return Future.value();
  }

  /// 设置页"立即刷新当年数据":忽略缓存强制重新请求并覆盖。
  Future<bool> manualRefreshCurrentYear() {
    final year = DateTime.now().year;
    _memory.remove(year);
    return fetchAndCacheYear(year);
  }

  /// 设置页"测试连接":用给定模板拉取当年数据,成功返回解析到的条数。
  Future<int?> testConnection(String urlTemplate) async {
    if (!HolidayApiConfig.isValidTemplate(urlTemplate)) return null;
    final year = DateTime.now().year;
    final url = urlTemplate.trim().replaceAll('{year}', year.toString());
    try {
      final response = await http.get(Uri.parse(url)).timeout(requestTimeout);
      if (response.statusCode != 200) return null;
      final data = HolidayParser.tryParse(response.body);
      return data?.length;
    } catch (_) {
      return null;
    }
  }

  /// 测试注入:直接塞入某年数据,绕过缓存与网络。
  @visibleForTesting
  void debugSetYearData(int year, Map<String, Map<String, dynamic>> data) {
    _memory[year] = data;
  }

  /// 测试清理。
  @visibleForTesting
  void debugClearMemory() {
    _memory.clear();
  }
}
