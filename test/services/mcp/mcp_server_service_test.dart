// MCP Server(Streamable HTTP)协议与工具回归测试。
//
// 不 Mock HTTP:真实绑定 loopback 随机端口,用 HttpClient 模拟助手侧
// 客户端,走完整 handshake → tools/list → tools/call 流程。
//
// 网络测试必须跑在真实 async 里:flutter test 的 FakeAsync 区域会让
// HttpServer/HttpClient 无法正常完成,所以用 testWidgets + runAsync。

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beecount/data/db.dart';
import 'package:beecount/data/repositories/local/local_repository.dart';
import 'package:beecount/providers/database_providers.dart';
import 'package:beecount/services/mcp/mcp_server_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProviderContainer container;
  late McpServerService service;
  late LocalRepository repo;
  late BeeDatabase db;
  late int ledgerId;
  late int port;
  const token = 'test-token';

  /// 起内存库 + 覆盖 repositoryProvider + 启动服务(ephemeral 端口)。
  Future<void> setup() async {
    SharedPreferences.setMockInitialValues({});
    db = BeeDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledgerId = await repo.createLedger(name: 'test', currency: 'CNY');
    await repo.createCategory(name: '交通', kind: 'expense');
    await repo.createCategory(name: '餐饮', kind: 'expense');
    await repo.createCategory(name: '工资', kind: 'income');

    container = ProviderContainer(overrides: [
      repositoryProvider.overrideWithValue(repo),
    ]);
    service = container.read(mcpServerServiceProvider);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mcp_token', token);
    final ok = await service.start();
    expect(ok, isTrue);
    port = service.port!;
  }

  Future<void> teardown() async {
    await service.stop();
    await db.close();
    container.dispose();
  }

  /// 模拟助手侧客户端发起一次 JSON-RPC。
  ///
  /// 用裸 Socket 发原始 HTTP:本机测试环境里 dart:io HttpClient 会被宿主
  /// 网络层劫持(实测恒返回 400 空响应,真实设备/正常环境不受影响)。
  Future<Map<String, dynamic>> rpc(String method,
      {Map<String, dynamic>? params, String? overrideToken}) async {
    final payload = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': method,
      if (params != null) 'params': params,
    });
    final crlf = '\r\n';
    final socket = await Socket.connect('127.0.0.1', port);
    socket.write('POST /mcp HTTP/1.1$crlf'
        'Host: 127.0.0.1:$port$crlf'
        'Authorization: Bearer ${overrideToken ?? token}$crlf'
        'Content-Type: application/json$crlf'
        'Content-Length: ${utf8.encode(payload).length}$crlf'
        'Connection: close$crlf$crlf'
        '$payload');
    final raw =
        await utf8.decodeStream(socket).timeout(const Duration(seconds: 10));
    await socket.close();
    final status = int.parse(raw.split(crlf).first.split(' ')[1]);
    final body =
        raw.contains('$crlf$crlf') ? raw.split('$crlf$crlf').skip(1).join() : '';
    if (body.isEmpty) return {'status': status};
    return {'status': status, ...jsonDecode(body) as Map<String, dynamic>};
  }

  testWidgets('无 token / 错 token → 401', (tester) async {
    await tester.runAsync(() async {
      await setup();
      final noAuth = await rpc('ping', overrideToken: '');
      expect(noAuth['status'], 401);
      final wrong = await rpc('ping', overrideToken: 'wrong');
      expect(wrong['status'], 401);
      await teardown();
    });
  });

  testWidgets('initialize → 协议版本与 serverInfo', (tester) async {
    await tester.runAsync(() async {
      await setup();
      final res = await rpc('initialize', params: {
        'protocolVersion': '2025-06-18',
        'capabilities': {},
        'clientInfo': {'name': 'xiaoi', 'version': '1'},
      });
      expect(res['status'], 200);
      final result = res['result'] as Map;
      expect(result['protocolVersion'], '2025-06-18');
      expect((result['serverInfo'] as Map)['name'], 'beecount');
      await teardown();
    });
  });

  testWidgets('未知方法 → -32601;通知 → 202 无响应体', (tester) async {
    await tester.runAsync(() async {
      await setup();
      final unknown = await rpc('no/such_method');
      expect((unknown['error'] as Map)['code'], -32601);

      // 通知(无 id)→ 202,无响应体
      final notified = await rpc('notifications/initialized');
      expect(notified['status'], 202);
      await teardown();
    });
  });

  testWidgets('tools/list 含四个记账工具', (tester) async {
    await tester.runAsync(() async {
      await setup();
      final res = await rpc('tools/list');
      final tools = (res['result'] as Map)['tools'] as List;
      final names = tools.map((t) => t['name']).toList();
      expect(names,
          containsAll(['add_expense', 'add_income', 'list_categories', 'query_recent']));
      await teardown();
    });
  });

  testWidgets('tools/call add_expense:金额+分类+备注+时间 → 落库正确', (tester) async {
    await tester.runAsync(() async {
      await setup();
      final res = await rpc('tools/call', params: {
        'name': 'add_expense',
        'arguments': {
          'amount': 5,
          'category': '交通',
          'note': '通勤',
          'date': '2031-01-06',
          'time': '09:00',
        },
      });
      final result = res['result'] as Map;
      expect(result['isError'], isNull);
      expect(((result['content'] as List).first as Map)['text'],
          contains('已记支出'));

      final all =
          await repo.transactionsWithCategoryAll(ledgerId: ledgerId).first;
      final tx = all.map((e) => e.t).firstWhere((t) => t.note == '通勤');
      expect(tx.amount, 5.0);
      expect(tx.type, 'expense');
      expect(tx.happenedAt, DateTime(2031, 1, 6, 9, 0));
      expect(all.firstWhere((e) => e.t.id == tx.id).category?.name, '交通');
      await teardown();
    });
  });

  testWidgets('tools/call add_expense:未知分类 → 不臆造,落未分类', (tester) async {
    await tester.runAsync(() async {
      await setup();
      final res = await rpc('tools/call', params: {
        'name': 'add_expense',
        'arguments': {'amount': 3, 'category': '不存在的分类'},
      });
      final result = res['result'] as Map;
      expect(((result['content'] as List).first as Map)['text'],
          contains('未分类'));
      await teardown();
    });
  });

  testWidgets('tools/call add_income:金额非法 → isError 提示', (tester) async {
    await tester.runAsync(() async {
      await setup();
      final res = await rpc('tools/call', params: {
        'name': 'add_income',
        'arguments': {'amount': -1},
      });
      final result = res['result'] as Map;
      expect(result['isError'], isTrue);
      await teardown();
    });
  });

  testWidgets('tools/call query_recent 返回最近账单文本', (tester) async {
    await tester.runAsync(() async {
      await setup();
      await rpc('tools/call', params: {
        'name': 'add_expense',
        'arguments': {'amount': 8, 'category': '餐饮'},
      });
      final res = await rpc('tools/call', params: {
        'name': 'query_recent',
        'arguments': {'days': 7},
      });
      final text =
          ((res['result'] as Map)['content'] as List).first['text'] as String;
      expect(text, contains('最近 7 天'));
      expect(text, contains('餐饮'));
      await teardown();
    });
  });
}
