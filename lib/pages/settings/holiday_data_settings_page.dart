import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../services/holiday/holiday_api_config.dart';
import '../../services/holiday/holiday_cache.dart';
import '../../services/holiday/holiday_service.dart';
import '../../styles/tokens.dart';
import '../../widgets/ui/toast.dart';
import '../../widgets/ui/ui.dart';

/// 节假日数据源设置页。
///
/// 维护"仅工作日/仅节假日"周期记账所依赖的节假日数据:
/// 主/备用 API 配置、测试连接、恢复默认、手动刷新当年数据。
class HolidayDataSettingsPage extends ConsumerStatefulWidget {
  const HolidayDataSettingsPage({super.key});

  @override
  ConsumerState<HolidayDataSettingsPage> createState() =>
      _HolidayDataSettingsPageState();
}

class _HolidayDataSettingsPageState
    extends ConsumerState<HolidayDataSettingsPage> {
  final _primaryController = TextEditingController();
  final _backupControllers = <TextEditingController>[];

  DateTime? _lastUpdated;
  bool _loading = true;
  bool _testing = false;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _primaryController.dispose();
    for (final c in _backupControllers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final config = await HolidayApiConfig.load();
    final lastUpdated =
        await HolidayCache.lastUpdated(DateTime.now().year);
    if (!mounted) return;
    setState(() {
      _primaryController.text = config.primaryApi;
      _backupControllers.clear();
      for (final url in config.backupApis) {
        _backupControllers.add(TextEditingController(text: url));
      }
      _lastUpdated = lastUpdated;
      _loading = false;
    });
  }

  List<String> get _backupUrls =>
      _backupControllers.map((c) => c.text.trim()).toList();

  /// 保存配置并立即生效(下次拉取即用新数据源)。
  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final primary = _primaryController.text.trim();
    if (!HolidayApiConfig.isValidTemplate(primary)) {
      showToast(context, l10n.holidayDataInvalidUrl('{year}'));
      return;
    }
    await HolidayApiConfig.save(primaryApi: primary, backupApis: _backupUrls);
    await HolidayService.instance.reloadConfig();
    if (!mounted) return;
    showToast(context, l10n.holidayDataSaved);
  }

  /// 测试连接:用当前输入的主 API 拉当年数据,成功提示解析条数。
  Future<void> _testConnection() async {
    final l10n = AppLocalizations.of(context);
    final url = _primaryController.text.trim();
    if (!HolidayApiConfig.isValidTemplate(url)) {
      showToast(context, l10n.holidayDataInvalidUrl('{year}'));
      return;
    }
    setState(() => _testing = true);
    final count = await HolidayService.instance.testConnection(url);
    if (!mounted) return;
    setState(() => _testing = false);
    if (count != null) {
      showToast(context, l10n.holidayDataTestOk(count));
    } else {
      showToast(context, l10n.holidayDataTestFail);
    }
  }

  /// 一键还原内置主 API 与备用列表(立即生效)。
  Future<void> _restoreDefaults() async {
    final l10n = AppLocalizations.of(context);
    await HolidayApiConfig.resetToDefault();
    await HolidayService.instance.reloadConfig();
    if (!mounted) return;
    setState(() {
      _primaryController.text = HolidayApiConfig.defaultPrimaryApi;
      for (final c in _backupControllers) {
        c.dispose();
      }
      _backupControllers
        ..clear()
        ..addAll(HolidayApiConfig.defaultBackupApis
            .map((url) => TextEditingController(text: url)));
    });
    showToast(context, l10n.holidayDataRestored);
  }

  /// 强制重新拉取当年数据并覆盖缓存。
  Future<void> _refreshNow() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _refreshing = true);
    final ok = await HolidayService.instance.manualRefreshCurrentYear();
    final lastUpdated = await HolidayCache.lastUpdated(DateTime.now().year);
    if (!mounted) return;
    setState(() {
      _refreshing = false;
      _lastUpdated = lastUpdated;
    });
    showToast(context, ok ? l10n.holidayDataRefreshOk : l10n.holidayDataRefreshFail);
  }

  void _addBackup() {
    setState(() => _backupControllers.add(TextEditingController()));
  }

  void _removeBackup(int index) {
    setState(() {
      _backupControllers[index].dispose();
      _backupControllers.removeAt(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDark = BeeTokens.isDark(context);

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      body: Column(
        children: [
          PrimaryHeader(
            title: l10n.holidayDataTitle,
            subtitle: l10n.holidayDataSubtitle,
            showBack: true,
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildStatusCard(l10n, isDark),
                      const SizedBox(height: 16),
                      _buildPrimaryApiCard(l10n, isDark),
                      const SizedBox(height: 16),
                      _buildBackupApisCard(l10n, isDark),
                      const SizedBox(height: 24),
                      _buildActions(l10n),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard({
    required Widget child,
    required bool isDark,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: BeeTokens.surface(context),
        borderRadius: BorderRadius.circular(12),
        border: isDark ? Border.all(color: BeeTokens.border(context)) : null,
      ),
      child: child,
    );
  }

  /// 当年数据状态 + 手动刷新。
  Widget _buildStatusCard(AppLocalizations l10n, bool isDark) {
    return _buildCard(
      isDark: isDark,
      child: ListTile(
        leading: const Icon(Icons.calendar_month),
        title: Text(
          l10n.holidayDataRefreshNow,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: BeeTokens.textPrimary(context),
          ),
        ),
        subtitle: Text(
          _lastUpdated == null
              ? l10n.holidayDataCacheEmpty
              : l10n.holidayDataLastUpdated(
                  DateFormat.yMd().add_Hm().format(_lastUpdated!)),
          style: TextStyle(
            fontSize: 14,
            color: BeeTokens.textSecondary(context),
          ),
        ),
        trailing: _refreshing
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _refreshing ? null : _refreshNow,
              ),
      ),
    );
  }

  Widget _buildPrimaryApiCard(AppLocalizations l10n, bool isDark) {
    return _buildCard(
      isDark: isDark,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.holidayDataPrimaryApi,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: BeeTokens.textPrimary(context),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _primaryController,
              decoration: InputDecoration(
                hintText: HolidayApiConfig.defaultPrimaryApi,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBackupApisCard(AppLocalizations l10n, bool isDark) {
    return _buildCard(
      isDark: isDark,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.holidayDataBackupApis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: BeeTokens.textPrimary(context),
              ),
            ),
            const SizedBox(height: 4),
            for (var i = 0; i < _backupControllers.length; i++)
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _backupControllers[i],
                      decoration: InputDecoration(
                        labelText:
                            l10n.holidayDataBackupApiLabel(i + 1),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      keyboardType: TextInputType.url,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: l10n.commonDelete,
                    onPressed: () => _removeBackup(i),
                  ),
                ],
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addBackup,
                icon: const Icon(Icons.add, size: 18),
                label: Text(l10n.holidayDataAddBackup),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActions(AppLocalizations l10n) {
    return Column(
      children: [
        Text(
          l10n.holidayDataUrlHint('{year}'),
          style: TextStyle(
            fontSize: 12,
            color: BeeTokens.textSecondary(context),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _testing ? null : _testConnection,
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.network_check, size: 18),
                label: Text(l10n.holidayDataTestConnection),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _restoreDefaults,
                icon: const Icon(Icons.restore, size: 18),
                label: Text(l10n.holidayDataRestoreDefaults),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _save,
            child: Text(l10n.commonSave),
          ),
        ),
      ],
    );
  }
}
