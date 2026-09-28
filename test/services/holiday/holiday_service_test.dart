// HolidayService 单元测试:解析器 / 配置 / 缓存 / 判断逻辑。
// 不测真实网络 —— 拉取路径由手动刷新入口覆盖,单测只锁解析与降级。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/services/holiday/holiday_api_config.dart';
import 'package:beecount/services/holiday/holiday_cache.dart';
import 'package:beecount/services/holiday/holiday_parser.dart';
import 'package:beecount/services/holiday/holiday_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    HolidayService.instance.debugClearMemory();
  });

  tearDown(() {
    HolidayService.instance.debugClearMemory();
  });

  group('HolidayParser', () {
    test('格式 A(xiaoai):daytype 0/3 → 工作日,1/2 → 节假日', () {
      const body = '{"code":0,"msg":"ok","data":['
          '{"daytype":1,"holiday":"元旦节","date":"2026-01-01"},'
          '{"daytype":2,"holiday":"周末","date":"2026-01-03"},'
          '{"daytype":3,"holiday":"元旦节调休","date":"2026-01-04"},'
          '{"daytype":0,"holiday":"","date":"2026-01-05"}'
          ']}';
      final data = HolidayParser.tryParse(body);
      expect(data, isNotNull);
      expect(data!.length, 4);
      expect(data['2026-01-01']!['isWorkday'], isFalse);
      expect(data['2026-01-03']!['isWorkday'], isFalse);
      expect(data['2026-01-04']!['isWorkday'], isTrue);
      expect(data['2026-01-04']!['name'], '元旦节调休');
      expect(data['2026-01-05']!['isWorkday'], isTrue);
    });

    test('格式 B(holiday-cn):isOffDay 取反为 isWorkday', () {
      const body = '{"year":2026,"days":['
          '{"name":"元旦","date":"2026-01-01","isOffDay":true},'
          '{"name":"春节后调休","date":"2026-02-22","isOffDay":false}'
          ']}';
      final data = HolidayParser.tryParse(body);
      expect(data, isNotNull);
      expect(data!.length, 2);
      expect(data['2026-01-01']!['isWorkday'], isFalse);
      expect(data['2026-01-01']!['name'], '元旦');
      expect(data['2026-02-22']!['isWorkday'], isTrue);
    });

    test('非法 JSON / 空结构 → null', () {
      expect(HolidayParser.tryParse('not json'), isNull);
      expect(HolidayParser.tryParse('{"foo":1}'), isNull);
      expect(HolidayParser.tryParse('{"days":[]}'), isNull);
    });
  });

  group('HolidayApiConfig', () {
    test('模板校验:必须 http(s) 且含 {year} 占位符', () {
      expect(
          HolidayApiConfig.isValidTemplate(
              'https://example.com/api/{year}.json'),
          isTrue);
      expect(HolidayApiConfig.isValidTemplate('https://example.com/api.json'),
          isFalse);
      expect(HolidayApiConfig.isValidTemplate('ftp://x/{year}'), isFalse);
      expect(HolidayApiConfig.isValidTemplate(null), isFalse);
    });

    test('保存/读取/恢复默认 roundtrip', () async {
      await HolidayApiConfig.save(
        primaryApi: 'https://example.com/{year}.json',
        backupApis: ['https://backup.example.com/{year}', 'not-a-url'],
      );
      final loaded = await HolidayApiConfig.load();
      expect(loaded.primaryApi, 'https://example.com/{year}.json');
      // 非法备用项在保存时被过滤
      expect(loaded.backupApis, ['https://backup.example.com/{year}']);

      await HolidayApiConfig.resetToDefault();
      final restored = await HolidayApiConfig.load();
      expect(restored.primaryApi, HolidayApiConfig.defaultPrimaryApi);
      expect(restored.backupApis, HolidayApiConfig.defaultBackupApis);
    });

    test('主 API 为非法值时回落默认', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('holiday_api_primary', 'javascript:alert(1)');
      final config = await HolidayApiConfig.load();
      expect(config.primaryApi, HolidayApiConfig.defaultPrimaryApi);
    });
  });

  group('HolidayCache', () {
    test('save/load roundtrip 与 lastUpdated', () async {
      final data = {
        '2026-01-01': {'isWorkday': false, 'name': '元旦'},
        '2026-01-04': {'isWorkday': true, 'name': '调休'},
      };
      expect(await HolidayCache.load(2026), isNull);
      expect(await HolidayCache.lastUpdated(2026), isNull);

      await HolidayCache.save(2026, data);
      final loaded = await HolidayCache.load(2026);
      expect(loaded, isNotNull);
      expect(loaded!.length, 2);
      expect(loaded['2026-01-04']!['isWorkday'], isTrue);
      expect(await HolidayCache.lastUpdated(2026), isNotNull);
    });
  });

  group('HolidayService', () {
    test('debugSetYearData 后判断走数据,清理后回退周末判断', () {
      final service = HolidayService.instance;
      // 2026-10-01 周四:数据标记为节假日 → 节假日;无数据时周四本应是工作日
      service.debugSetYearData(2026, {
        '2026-10-01': {'isWorkday': false, 'name': '国庆节'},
      });
      final d = DateTime(2026, 10, 1);
      expect(service.isWorkday(d), isFalse);
      expect(service.isHoliday(d), isTrue);

      service.debugClearMemory();
      expect(service.isWorkday(d), isTrue); // 回退:周四 → 工作日
    });

    test('ensureYearLoaded:内存命中不触发网络', () async {
      final service = HolidayService.instance;
      service.debugSetYearData(2026, {
        '2026-10-01': {'isWorkday': false, 'name': '国庆节'},
      });
      expect(await service.ensureYearLoaded(2026), isTrue);
      expect(service.isHoliday(DateTime(2026, 10, 1)), isTrue);
    });
  });

  group('LocalRepository + workday 频率写入', () {
    test('addRecurringTransaction 接受 workday/holiday 频率字符串', () async {
      final db = BeeDatabase.forTesting(NativeDatabase.memory());
      final repo = LocalRepository(db);
      final ledgerId = await repo.createLedger(name: 't', currency: 'CNY');
      await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 1,
        frequency: 'workday',
        interval: 1,
        startDate: DateTime(2026, 10, 1),
      );
      await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 1,
        frequency: 'holiday',
        interval: 1,
        startDate: DateTime(2026, 10, 1),
      );
      final all = await repo.getAllRecurringTransactions();
      expect(all.map((e) => e.frequency), containsAll(['workday', 'holiday']));
      await db.close();
    });
  });
}
