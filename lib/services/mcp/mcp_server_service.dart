import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/db.dart';
import '../../providers.dart';
import '../system/logger_service.dart';

/// 轻量 MCP(Model Context Protocol)服务端 —— Streamable HTTP 传输。
///
/// 目的:让系统级 AI 助手(如超级小爱)把"记账"作为工具直接调用。
/// 语音的理解由助手侧大模型完成,这里只暴露结构化工具并落库,
/// 应用内不需要配置任何 AI 提供商。
///
/// 协议要点(无状态模式):
/// - 单一端点 `POST /mcp`,JSON-RPC 2.0,响应 application/json;
/// - 不派发 Mcp-Session-Id(每次请求自包含);
/// - 鉴权:`Authorization: Bearer <token>`,缺失/不符一律 401;
/// - 绑定 0.0.0.0:本机 127.0.0.1、局域网 IP 均可访问。
class McpServerService {
  McpServerService(this._ref);

  final Ref _ref;
  static const _tag = 'Mcp';
  static const defaultPort = 8642;
  static const _protocolVersion = '2025-06-18';

  HttpServer? _server;
  bool get isRunning => _server != null;
  int? get port => _server?.port;

  /// 落库走仓库层(与 App 内记账同一条路径,触发云同步等后处理)。
  dynamic get _repo => _ref.read(repositoryProvider);

  // ---------------- 生命周期 ----------------

  /// 启动服务。已在运行时先停旧的(端口/配置可能变了)。
  Future<bool> start() async {
    await stop();
    try {
      final prefs = await SharedPreferences.getInstance();
      final port = prefs.getInt('mcp_port') ?? defaultPort;
      final token = prefs.getString('mcp_token');
      // 默认只绑回环(127.0.0.1):本机助手直连够用,不向局域网暴露端口;
      // 打开"允许局域网访问"后才绑 0.0.0.0。
      final bindLan = prefs.getBool('mcp_bind_lan') ?? false;
      final address =
          bindLan ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
      final server = await HttpServer.bind(address, port);
      _server = server;
      // 空闲 keep-alive 连接 60s 后由框架自动回收,句柄/内存有上界
      server.idleTimeout = const Duration(seconds: 60);
      server.listen(
        (request) async {
          try {
            await _handleRequest(request, token);
          } catch (e) {
            logger.warning(_tag, '请求处理异常: $e');
          }
        },
        onError: (Object e) => logger.warning(_tag, '连接异常: $e'),
      );
      logger.info(_tag,
          'MCP 服务已启动: ${address.address}:$port/mcp (lan=$bindLan)');
      return true;
    } catch (e, st) {
      logger.error(_tag, 'MCP 服务启动失败(端口可能被占用)', e, st);
      _server = null;
      return false;
    }
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
    if (server != null) logger.info(_tag, 'MCP 服务已停止');
  }

  /// 首次启用时生成随机 token(小爱侧填同一串)。
  static String generateToken() {
    final rnd = DateTime.now().microsecondsSinceEpoch;
    return 'bee-${rnd.toRadixString(36)}'
        '${DateTime.now().hashCode.abs().toRadixString(36)}';
  }

  // ---------------- 请求处理 ----------------

  Future<void> _handleRequest(HttpRequest request, String? token) async {
    Future<void> json(Object? body, {int status = 200}) async {
      final data = utf8.encode(jsonEncode(body));
      request.response.statusCode = status;
      request.response.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      // 显式 contentLength:避免 chunked 编码,简化客户端解析
      request.response.contentLength = data.length;
      request.response.add(data);
      await request.response.close();
    }

    // 鉴权:任何请求都必须带有效 Bearer token。
    if (token == null || token.isEmpty ||
        request.headers.value('authorization') != 'Bearer $token') {
      await json({
        'jsonrpc': '2.0',
        'error': {'code': -32001, 'message': 'Unauthorized'},
        'id': null,
      }, status: 401);
      return;
    }

    if (request.method != 'POST') {
      await json({
        'jsonrpc': '2.0',
        'error': {'code': -32000, 'message': 'Method Not Allowed'},
        'id': null,
      }, status: 405);
      return;
    }

    // 先收原始字节再容错解码:客户端(或代理)发出的编码不完全可信,
    // 解码失败也要回 -32700,绝不让连接悬挂。
    final rawBytes = <int>[];
    await for (final chunk in request) {
      rawBytes.addAll(chunk);
    }
    dynamic payload;
    try {
      payload = jsonDecode(utf8.decode(rawBytes, allowMalformed: true));
    } catch (_) {
      await json({
        'jsonrpc': '2.0',
        'error': {'code': -32700, 'message': 'Parse error'},
        'id': null,
      });
      return;
    }

    // 批量请求按数组处理(MCP 规范允许),通常为单条。
    final isBatch = payload is List;
    final items = isBatch ? payload : [payload];
    final responses = <Map<String, Object?>>[];
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final response = await _dispatch(item);
      // 通知(无 id)不产生响应
      if (response != null) responses.add(response);
    }

    if (responses.isEmpty) {
      request.response.statusCode = 202;
      await request.response.close();
      return;
    }
    await json(isBatch ? responses : responses.first);
  }

  /// 分发单条 JSON-RPC。返回 null 表示是通知(无需响应)。
  Future<Map<String, Object?>?> _dispatch(Map<String, dynamic> req) async {
    final id = req['id'];
    final method = req['method'] as String? ?? '';
    final params = (req['params'] as Map<String, dynamic>?) ?? const {};

    Future<Map<String, Object?>> result(Object result) async =>
        {'jsonrpc': '2.0', 'id': id, 'result': result};
    Future<Map<String, Object?>> error(int code, String message) async =>
        {'jsonrpc': '2.0', 'id': id, 'error': {'code': code, 'message': message}};

    try {
      switch (method) {
        case 'initialize':
          return await result({
            'protocolVersion': _protocolVersion,
            'capabilities': {'tools': {}},
            'serverInfo': {'name': 'beecount', 'version': '0.0.1'},
            'instructions':
                'BeeCount 记账应用。用 add_expense/add_income 记账;'
                '不确定分类名时先调 list_categories;用 query_recent 查最近账单。',
          });
        case 'notifications/initialized':
        case 'notifications/cancelled':
          return null;
        case 'ping':
          return await result({});
        case 'tools/list':
          return await result({'tools': _toolSchemas()});
        case 'tools/call':
          final name = params['name'] as String? ?? '';
          final args =
              (params['arguments'] as Map<String, dynamic>?) ?? const {};
          final out = await _callTool(name, args);
          return await result({
            'content': [
              {'type': 'text', 'text': out.text}
            ],
            if (out.isError) 'isError': true,
          });
        default:
          return await error(-32601, 'Unknown method: $method');
      }
    } catch (e, st) {
      logger.error(_tag, 'tools/call 执行失败: $method', e, st);
      return await error(-32603, 'Internal error: $e');
    }
  }

  // ---------------- 工具定义与实现 ----------------

  List<Map<String, Object?>> _toolSchemas() => [
        {
          'name': 'add_expense',
          'description': '记一笔支出。date/time 缺省为现在;'
              'category 缺省不分类。金额为数字(元)。',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'amount': {'type': 'number', 'description': '金额(元)'},
              'category': {'type': 'string', 'description': '分类名,如"交通"'},
              'note': {'type': 'string', 'description': '备注'},
              'date': {'type': 'string', 'description': '日期 YYYY-MM-DD,缺省今天'},
              'time': {'type': 'string', 'description': '时间 HH:mm,缺省现在'},
            },
            'required': ['amount'],
          },
        },
        {
          'name': 'add_income',
          'description': '记一笔收入。参数含义同 add_expense。',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'amount': {'type': 'number'},
              'category': {'type': 'string'},
              'note': {'type': 'string'},
              'date': {'type': 'string'},
              'time': {'type': 'string'},
            },
            'required': ['amount'],
          },
        },
        {
          'name': 'list_categories',
          'description': '列出账本的分类名(用于选择 add_expense 的 category)。',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'kind': {
                'type': 'string',
                'enum': ['expense', 'income'],
                'description': '缺省列出全部',
              },
            },
          },
        },
        {
          'name': 'query_recent',
          'description': '查询最近 N 天(默认 7)的账单概要。',
          'inputSchema': {
            'type': 'object',
            'properties': {
              'days': {'type': 'number', 'description': '天数,默认 7'},
            },
          },
        },
      ];

  Future<_ToolOutput> _callTool(
      String name, Map<String, dynamic> args) async {
    switch (name) {
      case 'add_expense':
      case 'add_income':
        return _addTransaction(name == 'add_income' ? 'income' : 'expense', args);
      case 'list_categories':
        return _listCategories(args['kind'] as String?);
      case 'query_recent':
        final days = (args['days'] as num?)?.toInt() ?? 7;
        return _queryRecent(days);
      default:
        return _ToolOutput('未知工具: $name', isError: true);
    }
  }

  Future<_ToolOutput> _addTransaction(
      String type, Map<String, dynamic> args) async {
    final amount = (args['amount'] as num?)?.toDouble();
    if (amount == null || amount <= 0) {
      return _ToolOutput('金额无效:需要正数(元)', isError: true);
    }

    final ledgers = await _repo.getAllLedgers();
    if (ledgers.isEmpty) return _ToolOutput('没有可用账本', isError: true);
    final ledger = ledgers.first;

    final note = (args['note'] as String?)?.trim();
    final dateStr = args['date'] as String?;
    final timeStr = args['time'] as String?;

    var when = DateTime.now();
    final parsedDate = dateStr == null ? null : DateTime.tryParse(dateStr);
    if (dateStr != null && parsedDate == null) {
      return _ToolOutput('日期格式无效: $dateStr(应为 YYYY-MM-DD)', isError: true);
    }
    if (parsedDate != null) {
      var hour = when.hour;
      var minute = when.minute;
      if (timeStr != null) {
        final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(timeStr.trim());
        if (m == null) {
          return _ToolOutput('时间格式无效: $timeStr(应为 HH:mm)', isError: true);
        }
        hour = int.parse(m.group(1)!);
        minute = int.parse(m.group(2)!);
      }
      when = DateTime(
          parsedDate.year, parsedDate.month, parsedDate.day, hour, minute);
    }

    // 分类:精确名 → 包含名 → 无分类(不臆造)。
    int? categoryId;
    String categoryUsed = '未分类';
    final categoryName = (args['category'] as String?)?.trim();
    if (categoryName != null && categoryName.isNotEmpty) {
      final all = await _repo.getAllCategories();
      final kind = type == 'income' ? 'income' : 'expense';
      final candidates =
          all.where((c) => c.kind == kind && c.parentId == null).toList();
      Category? matched;
      for (final c in candidates) {
        if (c.name == categoryName) matched = c;
      }
      if (matched == null) {
        // 退而求其次:名称包含匹配(如"打车"匹配"交通"不成立,但"餐饮外卖"
        // 匹配"餐饮"成立);仍不中则落未分类,不臆造。
        for (final c in candidates) {
          if (c.name.contains(categoryName)) {
            matched = c;
            break;
          }
        }
      }
      if (matched != null) {
        categoryId = matched.id;
        categoryUsed = matched.name;
      }
    }

    final id = await _repo.addTransaction(
      ledgerId: ledger.id,
      type: type,
      amount: amount,
      categoryId: categoryId,
      happenedAt: when,
      note: (note == null || note.isEmpty) ? null : note,
    );
    logger.info(_tag,
        'MCP 记账成功: #$id $type $amount 元($categoryUsed) @ $when note=$note');
    final typeName = type == 'income' ? '收入' : '支出';
    return _ToolOutput(
        '已记$typeName $amount 元($categoryUsed)'
        '${note == null || note.isEmpty ? '' : ':$note'}'
        '，时间 ${when.year}-${when.month.toString().padLeft(2, '0')}-${when.day.toString().padLeft(2, '0')} '
        '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}');
  }

  Future<_ToolOutput> _listCategories(String? kind) async {
    final all = await _repo.getAllCategories();
    final expense = all
        .where((c) => c.kind == 'expense' && c.parentId == null)
        .map((c) => c.name)
        .join('、');
    final income = all
        .where((c) => c.kind == 'income' && c.parentId == null)
        .map((c) => c.name)
        .join('、');
    final text = kind == 'expense'
        ? '支出分类: $expense'
        : kind == 'income'
            ? '收入分类: $income'
            : '支出分类: $expense\n收入分类: $income';
    return _ToolOutput(text);
  }

  Future<_ToolOutput> _queryRecent(int days) async {
    final ledgers = await _repo.getAllLedgers();
    if (ledgers.isEmpty) return _ToolOutput('没有可用账本', isError: true);
    final items =
        await _repo.transactionsWithCategoryAll(ledgerId: ledgers.first.id).first;
    final since = DateTime.now().subtract(Duration(days: days));
    // 注意:这里用显式循环而非 where 链 —— drift 记录类型的闭包推断
    // 在 where/sort 链上会退化成 dynamic,触发运行时子类型错误。
    final recent = <Transaction>[];
    for (final e in items) {
      if (e.t.happenedAt.isAfter(since)) recent.add(e.t);
    }
    recent.sort((a, b) => b.happenedAt.compareTo(a.happenedAt));
    if (recent.isEmpty) return _ToolOutput('最近 $days 天没有账单');
    final categoryNames = <int, String>{};
    for (final e in items) {
      if (e.category != null) categoryNames[e.t.categoryId ?? -1] = e.category!.name;
    }
    final lines = recent.take(20).map((t) {
      final sign = t.type == 'income' ? '+' : '-';
      final cat = t.categoryId != null
          ? (categoryNames[t.categoryId] ?? '未分类')
          : (t.type == 'transfer' ? '转账' : '未分类');
      final note = (t.note == null || t.note!.isEmpty) ? '' : '(${t.note})';
      return '${t.happenedAt.month}-${t.happenedAt.day} $cat $sign${t.amount.toStringAsFixed(2)}元$note';
    });
    return _ToolOutput('最近 $days 天共 ${recent.length} 笔:\n${lines.join('\n')}');
  }
}

class _ToolOutput {
  _ToolOutput(this.text, {this.isError = false});
  final String text;
  final bool isError;
}
