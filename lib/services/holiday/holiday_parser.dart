import 'dart:convert';

/// 节假日 API 返回格式解析器。
///
/// 不同数据源返回结构不同,统一解析为:
/// `{ 'YYYY-MM-DD': { 'isWorkday': bool, 'name': String } }`
///
/// 注意:多数数据源只包含"特殊日"(法定节假日 + 调休上班日),普通周末
/// 不在其中 —— 查不到的日期由调用方回退到"周一至周五为工作日"的简单判断。
class HolidayParser {
  HolidayParser._();

  /// 依次尝试已知格式;全部失败返回 null。
  static Map<String, Map<String, dynamic>>? tryParse(String body) {
    dynamic json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (json is! Map<String, dynamic>) return null;
    return parseXiaoai(json) ?? parseHolidayCn(json);
  }

  /// 格式 A(xiaoai):
  /// `{ "data": [ { "date": "2026-01-01", "daytype": 0/1/2/3, "holiday": "..." } ] }`
  /// daytype: 0=工作日 1=节假日 2=双休日 3=调休上班 → 0/3 为工作日。
  static Map<String, Map<String, dynamic>>? parseXiaoai(Map<String, dynamic> json) {
    final list = json['data'];
    if (list is! List || list.isEmpty) return null;
    final out = <String, Map<String, dynamic>>{};
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final date = item['date'];
      final daytype = item['daytype'];
      if (date is! String || daytype is! int) continue;
      out[date] = {
        'isWorkday': daytype == 0 || daytype == 3,
        'name': (item['holiday'] as String?) ?? '',
      };
    }
    return out.isEmpty ? null : out;
  }

  /// 格式 B(holiday-cn):
  /// `{ "days": [ { "date": "2026-01-01", "isOffDay": true, "name": "元旦" } ] }`
  /// isOffDay=false(调休上班)为工作日,true 为休息日。
  static Map<String, Map<String, dynamic>>? parseHolidayCn(Map<String, dynamic> json) {
    final list = json['days'];
    if (list is! List || list.isEmpty) return null;
    final out = <String, Map<String, dynamic>>{};
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final date = item['date'];
      final isOffDay = item['isOffDay'];
      if (date is! String || isOffDay is! bool) continue;
      out[date] = {
        'isWorkday': !isOffDay,
        'name': (item['name'] as String?) ?? '',
      };
    }
    return out.isEmpty ? null : out;
  }
}
