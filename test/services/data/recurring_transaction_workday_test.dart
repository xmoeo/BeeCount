// "仅工作日/仅节假日"周期生成逻辑回归测试。
//
// 锁死三件事:
//  1. 仅工作日:法定节假日/周末不生成,调休上班日(含周日)生成。
//  2. 仅节假日:周末+法定节假日生成,调休上班日不生成。
//  3. 跳过不顺延:候选日不满足时不生成也不推进 lastGeneratedDate,
//     引擎内部逐候选推进,不会卡死在"过去的非工作日"上。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/services/data/recurring_transaction_service.dart';
import 'package:beecount/services/holiday/holiday_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BeeDatabase db;
  late LocalRepository repo;
  late int ledgerId;

  // 2031-01 的锚点日期(均为 2031 年 1 月,便于注入判断数据):
  // 01-06 周一,01-07 周二,01-08 周三,01-09 周四,01-10 周五,
  // 01-11 周六,01-12 周日。
  DateTime d(int day) => DateTime(2031, 1, day);

  /// 注入 2031 年判断数据:01-07(周二)法定节假日,01-11/01-12 调休上班。
  void seedHolidayData() {
    HolidayService.instance.debugSetYearData(2031, {
      '2031-01-07': {'isWorkday': false, 'name': '测试节假日'},
      '2031-01-11': {'isWorkday': true, 'name': '测试调休'},
      '2031-01-12': {'isWorkday': true, 'name': '测试调休'},
    });
  }

  RecurringTransaction recurring({
    required String frequency,
    int interval = 1,
    DateTime? startDate,
    DateTime? lastGeneratedDate,
  }) {
    return RecurringTransaction(
      id: 1,
      ledgerId: ledgerId,
      type: 'expense',
      amount: 10,
      frequency: frequency,
      interval: interval,
      startDate: startDate ?? d(6),
      lastGeneratedDate: lastGeneratedDate,
      enabled: true,
      createdAt: d(1),
      updatedAt: d(1),
    );
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    HolidayService.instance.debugClearMemory();
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledgerId = await repo.createLedger(name: 'test', currency: 'CNY');
    seedHolidayData();
  });

  tearDown(() async {
    HolidayService.instance.debugClearMemory();
    await db.close();
  });

  group('isWorkday / isHoliday 判断', () {
    test('法定节假日(周二)→ 节假日;普通周三 → 工作日', () {
      final service = HolidayService.instance;
      expect(service.isHoliday(d(7)), isTrue);
      expect(service.isWorkday(d(8)), isTrue);
    });

    test('调休上班的周六/周日 → 工作日', () {
      final service = HolidayService.instance;
      expect(service.isWorkday(d(11)), isTrue);
      expect(service.isWorkday(d(12)), isTrue);
      expect(service.isHoliday(d(11)), isFalse);
    });

    test('数据缺失时回退简单周末判断', () {
      HolidayService.instance.debugClearMemory();
      final service = HolidayService.instance;
      expect(service.isWorkday(d(9)), isTrue); // 周四
      expect(service.isWorkday(d(11)), isFalse); // 周六
      expect(service.isHoliday(d(11)), isTrue);
    });
  });

  group('calculateNextDate: 仅工作日', () {
    test('普通工作日(周三)首次 → 当天生成', () {
      final service = RecurringTransactionService(repo);
      final next = service.calculateNextDate(
          recurring(frequency: 'workday', startDate: d(8)),
          now: d(8));
      expect(next, d(8));
    });

    test('法定节假日(周二)首次 → 不生成', () {
      final service = RecurringTransactionService(repo);
      final next = service.calculateNextDate(
          recurring(frequency: 'workday', startDate: d(7)),
          now: d(7));
      expect(next, isNull);
    });

    test('调休上班的周日首次 → 当天生成', () {
      final service = RecurringTransactionService(repo);
      final next = service.calculateNextDate(
          recurring(frequency: 'workday', startDate: d(12)),
          now: d(12));
      expect(next, d(12));
    });

    test('上次周一,今周三(中间周二放假)→ 跳过周二生成周三(跳过不顺延且不卡死)', () {
      final service = RecurringTransactionService(repo);
      final next = service.calculateNextDate(
          recurring(frequency: 'workday', lastGeneratedDate: d(6)),
          now: d(8));
      expect(next, d(8));
    });

    test('上次周五,今周日(周六调休上班)→ 生成周六', () {
      final service = RecurringTransactionService(repo);
      final next = service.calculateNextDate(
          recurring(frequency: 'workday', lastGeneratedDate: d(10)),
          now: d(12));
      expect(next, d(11));
    });
  });

  group('calculateNextDate: 仅节假日', () {
    test('法定节假日(周二)首次 → 当天生成', () {
      final service = RecurringTransactionService(repo);
      final next = service.calculateNextDate(
          recurring(frequency: 'holiday', startDate: d(7)),
          now: d(7));
      expect(next, d(7));
    });

    test('普通工作日(周五)首次 → 不生成', () {
      final service = RecurringTransactionService(repo);
      final next = service.calculateNextDate(
          recurring(frequency: 'holiday', startDate: d(10)),
          now: d(10));
      expect(next, isNull);
    });

    test('调休上班的周六首次 → 不生成(调休不算节假日)', () {
      final service = RecurringTransactionService(repo);
      final next = service.calculateNextDate(
          recurring(frequency: 'holiday', startDate: d(11)),
          now: d(11));
      expect(next, isNull);
    });

    test('无数据回退:周六 → 生成;周三 → 不生成', () {
      HolidayService.instance.debugClearMemory();
      final service = RecurringTransactionService(repo);
      expect(
        service.calculateNextDate(
            recurring(frequency: 'holiday', startDate: d(11)),
            now: d(11)),
        d(11),
      );
      expect(
        service.calculateNextDate(
            recurring(frequency: 'holiday', startDate: d(8)),
            now: d(8)),
        isNull,
      );
    });
  });

  group('generatePendingTransactions 集成', () {
    test('今天是注入的节假日:仅工作日不生成,仅节假日生成今天一笔', () async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final mm = today.month.toString().padLeft(2, '0');
      final dd = today.day.toString().padLeft(2, '0');
      final key = '${today.year}-$mm-$dd';
      HolidayService.instance.debugClearMemory();
      HolidayService.instance
          .debugSetYearData(today.year, {key: {'isWorkday': false, 'name': '测试'}});

      await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'workday',
        interval: 1,
        startDate: today,
      );
      await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 20,
        frequency: 'holiday',
        interval: 1,
        startDate: today,
      );

      final service = RecurringTransactionService(repo);
      final generated = await service.generatePendingTransactions();

      expect(generated, hasLength(1));
      expect(generated.first.amount, 20);
      expect(generated.first.happenedAt, today);

      // 未生成的仅工作日模板 lastGeneratedDate 不应被推进
      final all = await repo.getAllRecurringTransactions();
      final workdayRow = all.firstWhere((r) => r.frequency == 'workday');
      expect(workdayRow.lastGeneratedDate, isNull);
    });

    test('今天是注入的调休上班日:仅工作日生成今天一笔', () async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final mm = today.month.toString().padLeft(2, '0');
      final dd = today.day.toString().padLeft(2, '0');
      final key = '${today.year}-$mm-$dd';
      HolidayService.instance.debugClearMemory();
      HolidayService.instance
          .debugSetYearData(today.year, {key: {'isWorkday': true, 'name': '测试调休'}});

      await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'workday',
        interval: 1,
        startDate: today,
      );

      final service = RecurringTransactionService(repo);
      final generated = await service.generatePendingTransactions();

      expect(generated, hasLength(1));
      expect(generated.first.happenedAt, today);
    });
  });
}
