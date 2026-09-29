import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers.dart';
import '../../services/mcp/mcp_server_service.dart';
import '../../styles/tokens.dart';
import '../../widgets/ui/toast.dart';
import '../../widgets/ui/ui.dart';

/// MCP 记账服务设置页。
///
/// 把"记账"暴露为 MCP 工具(Streamable HTTP + Bearer token),供系统级
/// AI 助手(如超级小爱)直连调用 —— 语音的理解由助手侧完成,应用内
/// 不需要配置任何 AI 提供商。
class McpSettingsPage extends ConsumerStatefulWidget {
  const McpSettingsPage({super.key});

  @override
  ConsumerState<McpSettingsPage> createState() => _McpSettingsPageState();
}

class _McpSettingsPageState extends ConsumerState<McpSettingsPage> {
  bool _running = false;
  bool _busy = false;
  bool _bindLan = false;
  int _port = McpServerService.defaultPort;
  String _token = '';
  String _ip = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = await _localIp();
    if (!mounted) return;
    setState(() {
      _port = prefs.getInt('mcp_port') ?? McpServerService.defaultPort;
      _token = prefs.getString('mcp_token') ?? '';
      _ip = ip;
      _bindLan = prefs.getBool('mcp_bind_lan') ?? false;
      _running = ref.read(mcpServerServiceProvider).isRunning;
    });
  }

  Future<String> _localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final itf in interfaces) {
        for (final addr in itf.addresses) {
          if (!addr.isLoopback) return addr.address;
        }
      }
    } catch (_) {}
    return '';
  }

  Future<void> _toggle(bool enable) async {
    setState(() => _busy = true);
    final prefs = await SharedPreferences.getInstance();
    final service = ref.read(mcpServerServiceProvider);
    if (enable) {
      if (_token.isEmpty) {
        _token = McpServerService.generateToken();
        await prefs.setString('mcp_token', _token);
      }
      await prefs.setInt('mcp_port', _port);
      final ok = await service.start();
      await prefs.setBool('mcp_enabled', ok);
      if (!mounted) return;
      setState(() => _running = ok);
      showToast(context, ok ? 'MCP 服务已启动' : '启动失败(端口被占用?)');
    } else {
      await service.stop();
      await prefs.setBool('mcp_enabled', false);
      if (!mounted) return;
      setState(() => _running = false);
      showToast(context, 'MCP 服务已停止');
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _editPort() async {
    final controller = TextEditingController(text: '$_port');
    final value = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('服务端口'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '1024 - 65535'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(int.tryParse(controller.text)),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (value == null || value < 1024 || value > 65535) return;
    setState(() => _port = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('mcp_port', value);
    if (_running) await _toggle(true); // 以新端口重启
  }

  Future<void> _regenerateToken() async {
    setState(() => _token = McpServerService.generateToken());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('mcp_token', _token);
    if (!mounted) return;
    showToast(context, '已重新生成(原 token 立即失效)');
  }

  @override
  Widget build(BuildContext context) {
    final isDark = BeeTokens.isDark(context);
    final baseUrl = _ip.isEmpty ? '' : 'http://$_ip:$_port/mcp';

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          PrimaryHeader(
            title: 'MCP 记账服务',
            subtitle: '让系统 AI 助手(超级小爱)直接语音记账',
            showBack: true,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _card(isDark, [
                  SwitchListTile(
                    title: Text(
                      '启用服务',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: BeeTokens.textPrimary(context),
                      ),
                    ),
                    subtitle: Text(
                      _running
                          ? '运行中 (${_bindLan ? "$_ip:" : "127.0.0.1:"}$_port)'
                          : '未运行(应用启动后会自动拉起)',
                      style: TextStyle(
                        fontSize: 13,
                        color: BeeTokens.textSecondary(context),
                      ),
                    ),
                    value: _running,
                    onChanged: _busy ? null : _toggle,
                    activeColor: Theme.of(context).primaryColor,
                  ),
                  ListTile(
                    title: Text('允许局域网访问',
                        style: TextStyle(
                            fontSize: 15,
                            color: BeeTokens.textPrimary(context))),
                    subtitle: Text(
                      '默认关闭:仅本机(127.0.0.1)可连,更安全省电。'
                      '同 WiFi 其它设备要连时再打开',
                      style: TextStyle(
                          fontSize: 12,
                          color: BeeTokens.textSecondary(context)),
                    ),
                    trailing: Switch.adaptive(
                      value: _bindLan,
                      onChanged: _busy
                          ? null
                          : (value) async {
                              setState(() => _bindLan = value);
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.setBool('mcp_bind_lan', value);
                              if (_running) await _toggle(true); // 以新绑定重启
                            },
                      activeColor: Theme.of(context).primaryColor,
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                _card(isDark, [
                  ListTile(
                    title: Text('端口',
                        style: TextStyle(
                            fontSize: 16,
                            color: BeeTokens.textPrimary(context))),
                    trailing: Text('$_port',
                        style: TextStyle(
                            fontSize: 14,
                            color: BeeTokens.textSecondary(context))),
                    onTap: _editPort,
                  ),
                  ListTile(
                    title: Text('访问令牌',
                        style: TextStyle(
                            fontSize: 16,
                            color: BeeTokens.textPrimary(context))),
                    subtitle: Text(
                      _token.isEmpty ? '(开启服务时自动生成)' : _token,
                      style: TextStyle(
                          fontSize: 13,
                          color: BeeTokens.textSecondary(context)),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.copy, size: 20),
                          tooltip: '复制',
                          onPressed: _token.isEmpty
                              ? null
                              : () async {
                                  await Clipboard.setData(
                                      ClipboardData(text: _token));
                                  if (!mounted) return;
                                  showToast(context, '已复制');
                                },
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 20),
                          tooltip: '重新生成',
                          onPressed: _regenerateToken,
                        ),
                      ],
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                _card(isDark, [
                  Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('超级小爱接入方法',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: BeeTokens.textPrimary(context))),
                        const SizedBox(height: 8),
                        Text(
                          '1. 开启上方服务,保持应用在后台运行\n'
                          '2. 小爱 → 设置 → MCP 服务 → 添加个人 MCP 服务器\n'
                          '3. 地址填: ${_bindLan ? baseUrl : "http://127.0.0.1:$_port/mcp"}\n'
                          '4. 鉴权选 Bearer Token,填上面那串访问令牌\n'
                          '5. 对小爱说:"记一笔交通 5 元通勤"试试\n\n'
                          '· 本机直连(推荐):http://127.0.0.1:$_port/mcp\n'
                          '· 同 WiFi 其它设备:打开"允许局域网访问"后用 $baseUrl\n'
                          '· 公网接入需自行内网穿透,并注意令牌保管',
                          style: TextStyle(
                              fontSize: 13,
                              height: 1.5,
                              color: BeeTokens.textSecondary(context)),
                        ),
                      ],
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(bool isDark, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: BeeTokens.surface(context),
        borderRadius: BorderRadius.circular(12),
        border:
            isDark ? Border.all(color: BeeTokens.border(context)) : null,
      ),
      child: Column(children: children),
    );
  }
}
