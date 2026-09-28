// v34 "记账时间"(generationMinute)回归测试。
//
// 锁死四件事:
//  1. 设置记账时间后,生成交易的 happenedAt = 目标日期 + 该时间。
//  2. "到点才生成":当天目标时刻未到时本次不生成。
//  3. 月/年首笔顺延判断感知记账时间(创建日 08:00 + 记账时间 09:00 →
//     首笔落今天 09:00,而非顺延到下月;创建日 21:00 → 顺延)。
//  4. generationMinute = null 保持既有行为一字不差(按天类继承基准时刻);
//     结束日判断按日期部分比较,记账时间不影响最后一天。

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

  // 2031-01 锚点:01-06 周一,01-07 周二,01-08 周三,01-11 周六,01-12 周日。
  DateTime d(int day, [int hour = 0, int minute = 0]) =>
      DateTime(2031, 1, day, hour, minute);

  RecurringTransaction recurring({
    required String frequency,
    int? generationMinute,
    DateTime? startDate,
    DateTime? lastGeneratedDate,
    DateTime? endDate,
    int? dayOfMonth,
  }) {
    return RecurringTransaction(
      id: 1,
      ledgerId: ledgerId,
      type: 'expense',
      amount: 10,
      frequency: frequency,
      interval: 1,
      dayOfMonth: dayOfMonth,
      generationMinute: generationMinute,
      startDate: startDate ?? d(6, 8),
      lastGeneratedDate: lastGeneratedDate,
      endDate: endDate,
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
    // 2031 注入数据:01-07(周二)法定节假日,01-11/01-12 调休上班。
    HolidayService.instance.debugSetYearData(2031, {
      '2031-01-07': {'isWorkday': false, 'name': '测试节假日'},
      '2031-01-11': {'isWorkday': true, 'name': '测试调休'},
      '2031-01-12': {'isWorkday': true, 'name': '测试调休'},
    });
  });

  tearDown(() async {
    HolidayService.instance.debugClearMemory();
    await db.close();
  });

  group('记账时间叠加与到期判断', () {
    test('每日 + 记账时间 10:00:目标时刻未到 → 不生成;到点后 → 生成当天 10:00', () {
      final service = RecurringTransactionService(repo);
      final r = recurring(
          frequency: 'daily', generationMinute: 600, lastGeneratedDate: d(6, 10));
      // now=01-07 09:30 → 当天 10:00 档未到
      expect(
          service.calculateNextDate(r, now: d(7, 9, 30)), isNull);
      // now=01-07 10:30 → 生成 01-07 10:00
      expect(service.calculateNextDate(r, now: d(7, 10, 30)), d(7, 10));
    });

    test('每月 + 记账时间 09:00:创建日 08:00 → 首笔落今天 09:00(顺延判断感知时间)',
        () {
      final service = RecurringTransactionService(repo);
      final next = service.calculateNextDate(
          recurring(
              frequency: 'monthly',
              generationMinute: 540,
              startDate: d(6, 8),
              dayOfMonth: 6),
          now: d(6, 10));
      expect(next, d(6, 9));
    });

    test('每月 + 记账时间 09:00:创建日 21:00 → 当天档已过,首笔顺延到下月 09:00',
        () {
      final service = RecurringTransactionService(repo);
      final next = service.calculateNextDate(
          recurring(
              frequency: 'monthly',
              generationMinute: 540,
              startDate: d(6, 21),
              dayOfMonth: 6),
          now: DateTime(2031, 2, 6, 10));
      expect(next, DateTime(2031, 2, 6, 9));
    });

    test('仅工作日 + 记账时间 22:00:跳过中间的节假日,生成 01-08 22:00', () {
      final service = RecurringTransactionService(repo);
      final next = service.calculateNextDate(
          recurring(
              frequency: 'workday',
              generationMinute: 1320,
              lastGeneratedDate: d(6, 22)),
          now: d(8, 23));
      expect(next, d(8, 22));
    });
  });

  group('兼容性', () {
    test('generationMinute = null:按天类继承基准时刻(旧行为一字不差)', () {
      final service = RecurringTransactionService(repo);
      final next = service.calculateNextDate(
          recurring(frequency: 'daily', lastGeneratedDate: d(6, 8)),
          now: d(7, 9));
      expect(next, d(7, 8));
    });

    test('结束日窗口内生成:记账时间照常叠加', () {
      final service = RecurringTransactionService(repo);
      final next = service.calculateNextDate(
          recurring(
              frequency: 'daily',
              generationMinute: 600,
              lastGeneratedDate: d(6, 10),
              endDate: d(8)),
          now: d(7, 11));
      expect(next, d(7, 10)); // 结束日为 01-08,01-07 的 10:00 档正常生成
    });

    test('结束日已过(now 晚于结束日零点)→ 整条跳过(既有语义)', () {
      final service = RecurringTransactionService(repo);
      final next = service.calculateNextDate(
          recurring(
              frequency: 'daily',
              generationMinute: 600,
              lastGeneratedDate: d(7, 10),
              endDate: d(7)),
          now: d(8, 12));
      expect(next, isNull);
    });
  });

  group('集成(真实 now,确定性注入)', () {
    test('记账时间 00:00 的每日周期 → 生成今天 00:00 一笔', () async {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
        frequency: 'daily',
        interval: 1,
        startDate: today,
        generationMinute: 0,
      );

      final service = RecurringTransactionService(repo);
      final generated = await service.generatePendingTransactions();

      expect(generated, hasLength(1));
      expect(generated.first.happenedAt, today); // 今天 00:00:00
    });

    test('仓库层写入/更新 generationMinute', () async {
      final id = await repo.addRecurringTransaction(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 1,
        frequency: 'daily',
        interval: 1,
        startDate: d(6),
        generationMinute: 1320,
      );
      var all = await repo.getAllRecurringTransactions();
      expect(all.firstWhere((r) => r.id == id).generationMinute, 1320);

      await repo.updateRecurringTransaction(
        id: id,
        ledgerId: ledgerId,
        type: 'expense',
        amount: 1,
        frequency: 'daily',
        interval: 1,
        startDate: d(6),
        generationMinute: null, // 清除 → 写 NULL
      );
      all = await repo.getAllRecurringTransactions();
      expect(all.firstWhere((r) => r.id == id).generationMinute, isNull);
    });
  });
}
