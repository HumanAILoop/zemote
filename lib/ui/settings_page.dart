import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/relay_client.dart';
import '../protocol/zemote_client.dart';
import '../update/app_version.dart';
import '../update/update_checker.dart';
import '../update/update_dialog.dart';
import '../update/update_channel.dart';
import 'channel_explorer_page.dart';
import 'diagnostics_page.dart';
import 'log_page.dart';
import 'model_providers_page.dart';
import 'rpc_explorer_page.dart';
import 'services_page.dart';
import 'theme.dart';
import 'ui_settings.dart';
import 'usage_page.dart';

/// Builds a `{workspacePath, workspaceIdentity?}` scope from a bridge.
Map<String, dynamic> _scopeOf(BridgeSession session) => {
      'workspacePath': session.bridge['workspacePath'],
      if (session.bridge['workspaceIdentity'] != null)
        'workspaceIdentity': session.bridge['workspaceIdentity'],
    };

class SettingsPage extends StatelessWidget {
  final ZemoteClient? client;
  final BridgeSession? bridge;
  final VoidCallback onDisconnect;
  final ThemeController? themeController;

  const SettingsPage({
    super.key,
    this.client,
    this.bridge,
    required this.onDisconnect,
    this.themeController,
  });

  @override
  Widget build(BuildContext context) {
    final controller = themeController;
    final ui = UiSettingsProvider.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(tr(context, 'settings.title'),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
        const SizedBox(height: 20),
        Card(
          child: ListTile(
            leading: const Icon(Icons.system_update_alt, size: 20),
            title: const Text('检查更新'),
            subtitle: Text('当前版本 v$appVersion · 检测 GitHub 最新发布',
                style: const TextStyle(fontSize: 12)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _checkUpdates(context),
          ),
        ),
        const SizedBox(height: 12),
        if (controller != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr(context, 'settings.appearance'),
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  AnimatedBuilder(
                    animation: controller,
                    builder: (context, _) => SegmentedButton<ThemeMode>(
                      segments: [
                        ButtonSegment(
                            value: ThemeMode.dark,
                            icon:
                                const Icon(Icons.dark_mode_outlined, size: 16),
                            label: Text(tr(context, 'settings.theme.dark'),
                                style: const TextStyle(fontSize: 12))),
                        ButtonSegment(
                            value: ThemeMode.light,
                            icon:
                                const Icon(Icons.light_mode_outlined, size: 16),
                            label: Text(tr(context, 'settings.theme.light'),
                                style: const TextStyle(fontSize: 12))),
                        ButtonSegment(
                            value: ThemeMode.system,
                            icon: const Icon(Icons.settings_suggest_outlined,
                                size: 16),
                            label: Text(tr(context, 'settings.theme.system'),
                                style: const TextStyle(fontSize: 12))),
                      ],
                      selected: {controller.mode},
                      onSelectionChanged: (modes) =>
                          controller.setMode(modes.first),
                      style: const ButtonStyle(
                        visualDensity: VisualDensity.compact,
                        textStyle:
                            WidgetStatePropertyAll(TextStyle(fontSize: 12)),
                        iconSize: WidgetStatePropertyAll(16),
                      ),
                    ),
                  ),
                  if (ui != null) ...[
                    const SizedBox(height: 16),
                    Text(tr(context, 'settings.language'),
                        style: const TextStyle(fontSize: 13)),
                    const SizedBox(height: 8),
                    AnimatedBuilder(
                      animation: ui,
                      builder: (context, _) => SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                              value: 'zh-CN',
                              label:
                                  Text('中文', style: TextStyle(fontSize: 12))),
                          ButtonSegment(
                              value: 'en-US',
                              label: Text('English',
                                  style: TextStyle(fontSize: 12))),
                        ],
                        selected: {ui.locale},
                        onSelectionChanged: (v) => ui.setLocale(v.first),
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          textStyle:
                              WidgetStatePropertyAll(TextStyle(fontSize: 12)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                        '${tr(context, 'settings.textScale')} · ${ui.textScale.toStringAsFixed(2)}x',
                        style: const TextStyle(fontSize: 13)),
                    AnimatedBuilder(
                      animation: ui,
                      builder: (context, _) => Slider(
                        value: ui.textScale,
                        min: 0.8,
                        max: 1.4,
                        divisions: 12,
                        onChanged: ui.setTextScale,
                      ),
                    ),
                    Text(
                        '${tr(context, 'settings.codeFont')} · ${ui.codeFontSize.toStringAsFixed(1)}',
                        style: const TextStyle(fontSize: 13)),
                    AnimatedBuilder(
                      animation: ui,
                      builder: (context, _) => Slider(
                        value: ui.codeFontSize,
                        min: 10,
                        max: 20,
                        divisions: 20,
                        onChanged: ui.setCodeFontSize,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.terminal, size: 20),
                title: const Text('协议日志'),
                subtitle: const Text('查看 relay / IPC / V4 帧日志',
                    style: TextStyle(fontSize: 12)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => const LogPage())),
              ),
              _VerboseFramesSetting(),
              const Divider(indent: 52),
              ListTile(
                leading: const Icon(Icons.health_and_safety_outlined, size: 20),
                title: const Text('诊断中心'),
                subtitle: const Text('连接状态、订阅状态和故障记录',
                    style: TextStyle(fontSize: 12)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DiagnosticsPage(
                      client: client,
                      bridge: bridge,
                    ),
                  ),
                ),
              ),
              if (client != null) ...[
                const Divider(indent: 52),
                ListTile(
                  leading: const Icon(Icons.bug_report_outlined, size: 20),
                  title: const Text('RPC 调试器'),
                  subtitle: const Text('发送原始 relay payload',
                      style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => RpcExplorerPage(client: client!))),
                ),
              ],
              if (bridge != null) ...[
                const Divider(indent: 52),
                ListTile(
                  leading: const Icon(Icons.extension_outlined, size: 20),
                  title: const Text('服务管理'),
                  subtitle: const Text('插件 / 定时任务 / MCP / Skills',
                      style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ServicesPage(
                            session: bridge!,
                            scope: _scopeOf(bridge!),
                          ))),
                ),
                const Divider(indent: 52),
                ListTile(
                  leading: const Icon(Icons.query_stats, size: 20),
                  title: const Text('用量'),
                  subtitle: const Text('额度 / 配额限制 / 订阅详情',
                      style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => UsagePage(session: bridge!))),
                ),
                const Divider(indent: 52),
                ListTile(
                  leading: const Icon(Icons.model_training, size: 20),
                  title: const Text('模型供应商'),
                  subtitle: const Text('添加 / 启停 / 删除模型供应商',
                      style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ModelProvidersPage(session: bridge!))),
                ),
                const Divider(indent: 52),
                ListTile(
                  leading: const Icon(Icons.hub_outlined, size: 20),
                  title: const Text('Channel RPC 调试器'),
                  subtitle: const Text(
                      '调用任意 channel 方法（zcode-task / skills / mcp …）',
                      style: TextStyle(fontSize: 12)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ChannelExplorerPage(session: bridge!))),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading:
                const Icon(Icons.link_off, color: ZColors.danger, size: 20),
            title:
                const Text('断开当前设备', style: TextStyle(color: ZColors.danger)),
            onTap: onDisconnect,
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: Text('Zemote (Flutter) · 协议复刻版',
              style: TextStyle(fontSize: 11, color: ZInk.ghost(context))),
        ),
        const SizedBox(height: 6),
        Center(
          child: InkWell(
            onTap: () =>
                _copyUrl(context, 'https://github.com/HumanAILoop/zemote'),
            child: Text(
              'GitHub: https://github.com/HumanAILoop/zemote',
              style: TextStyle(
                fontSize: 11,
                color: ZInk.faint(context),
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _copyUrl(BuildContext context, String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制 GitHub 链接')));
    }
  }

  /// Manual update check: shows a spinner, then either the update prompt
  /// (Android: in-app APK download + install) or an up-to-date notice.
  Future<void> _checkUpdates(BuildContext context) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('正在检查更新…', style: TextStyle(fontSize: 13)),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      final info = await checkForUpdates(
          includePrerelease: updateChannelSettings.receiveBetaUpdates);
      if (!context.mounted) return;
      Navigator.of(context).pop(); // close the spinner
      if (info.isNewer) {
        await showUpdateDialog(context, info);
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已是最新版本 v$appVersion')));
      }
    } catch (e) {
      if (!context.mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('检查更新失败: $e')));
    }
  }
}

class _VerboseFramesSetting extends StatefulWidget {
  @override
  State<_VerboseFramesSetting> createState() => _VerboseFramesSettingState();
}

class _VerboseFramesSettingState extends State<_VerboseFramesSetting> {
  @override
  Widget build(BuildContext context) => SwitchListTile(
        secondary: const Icon(Icons.article_outlined, size: 20),
        title: const Text('协议帧日志（详细）'),
        subtitle:
            const Text('记录完整 relay 帧，可能包含敏感数据', style: TextStyle(fontSize: 12)),
        value: RelayClient.verboseFrames,
        onChanged: (value) async {
          RelayClient.verboseFrames = value;
          setState(() {});
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('relayVerboseFrames', value);
        },
      );
}

class _BetaUpdateSetting extends StatefulWidget {
  const _BetaUpdateSetting();

  @override
  State<_BetaUpdateSetting> createState() => _BetaUpdateSettingState();
}

class _BetaUpdateSettingState extends State<_BetaUpdateSetting> {
  final _settings = updateChannelSettings;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _settings.load();
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) => Card(
        child: SwitchListTile(
          secondary: Icon(
            _settings.receiveBetaUpdates
                ? Icons.science
                : Icons.verified_outlined,
            size: 20,
          ),
          title: const Text('接收 Beta 更新'),
          subtitle: Text(
            _loading
                ? '正在读取更新通道…'
                : _settings.receiveBetaUpdates
                    ? '当前通道：稳定版 + Beta 版'
                    : '当前通道：稳定版（推荐）',
            style: const TextStyle(fontSize: 12),
          ),
          value: !_loading && _settings.receiveBetaUpdates,
          onChanged: _loading
              ? null
              : (value) async {
                  setState(() => _settings.receiveBetaUpdates = value);
                  await _settings.setReceiveBetaUpdates(value);
                },
        ),
      );
}
