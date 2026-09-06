import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// UI preferences: locale (zh-CN / en-US), text scale, code font size.
class UiSettings extends ChangeNotifier {
  static const _localeKey = 'zemote_ui_locale';
  static const _scaleKey = 'zemote_ui_text_scale';
  static const _codeFontKey = 'zemote_ui_code_font_size';

  String locale = 'zh-CN';
  double textScale = 1.0;
  double codeFontSize = 12.5;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    locale = prefs.getString(_localeKey) ?? 'zh-CN';
    textScale = prefs.getDouble(_scaleKey) ?? 1.0;
    codeFontSize = prefs.getDouble(_codeFontKey) ?? 12.5;
    notifyListeners();
  }

  Future<void> setLocale(String value) async {
    locale = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localeKey, value);
  }

  Future<void> setTextScale(double value) async {
    textScale = value.clamp(0.8, 1.4);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_scaleKey, textScale);
  }

  Future<void> setCodeFontSize(double value) async {
    codeFontSize = value.clamp(10, 20);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_codeFontKey, codeFontSize);
  }
}

class UiSettingsProvider extends InheritedWidget {
  final UiSettings settings;

  const UiSettingsProvider({
    super.key,
    required this.settings,
    required super.child,
  });

  static UiSettings? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<UiSettingsProvider>()
      ?.settings;

  @override
  bool updateShouldNotify(UiSettingsProvider oldWidget) =>
      settings != oldWidget.settings;
}

/// Lightweight i18n lookup.
String tr(BuildContext context, String key) {
  final locale = UiSettingsProvider.of(context)?.locale ?? 'zh-CN';
  final table = locale.startsWith('en') ? _en : _zh;
  return table[key] ?? _zh[key] ?? key;
}

const _zh = {
  'app.title': 'Zemote 远程控制',
  'nav.tasks': '任务',
  'nav.settings': '设置',
  'home.search': '搜索任务…',
  'home.tab.tasks': '任务',
  'home.tab.pinned': '置顶',
  'home.tab.archived': '已归档',
  'home.empty.tasks': '暂无任务，点击右下角新建',
  'home.empty.pinned': '没有置顶任务',
  'home.empty.archived': '没有已归档任务',
  'home.newTask': '新建任务',
  'home.loadOlder': '加载更早消息',
  'chat.inputHint': '向 ZCode 发送消息…',
  'chat.empty': '输入消息开始新会话',
  'chat.stop': '停止',
  'settings.title': '设置',
  'settings.appearance': '外观',
  'settings.theme.dark': '深色',
  'settings.theme.light': '浅色',
  'settings.theme.system': '跟随系统',
  'settings.language': '语言',
  'settings.textScale': '界面字号',
  'settings.codeFont': '代码字号',
  'settings.log': '协议日志',
  'settings.log.subtitle': '查看 relay / IPC / V4 帧日志',
  'settings.disconnect': '断开当前设备',
  'settings.section.general': '通用',
  'settings.section.advanced': '调试与高级',
  'settings.section.device': '设备',
  'settings.checkUpdate': '检查更新',
  'settings.version': '当前版本 v',
  'settings.version.hint': '检测 GitHub 最新发布',
  'settings.checking': '正在检查更新…',
  'settings.upToDate': '已是最新版本 v',
  'settings.checkFailed': '检查更新失败: ',
  'settings.betaUpdates': '接收 Beta 更新',
  'settings.betaUpdates.reading': '正在读取更新通道…',
  'settings.betaUpdates.stable': '当前通道：稳定版（推荐）',
  'settings.betaUpdates.beta': '当前通道：稳定版 + Beta 版',
  'settings.voiceInput': '离线语音输入',
  'settings.voiceInput.subtitle': '下载、启用和管理本地语音识别模型',
  'settings.verboseFrames': '协议帧日志（详细）',
  'settings.verboseFrames.subtitle': '记录完整 relay 帧，可能包含敏感数据',
  'settings.diagnostics': '诊断中心',
  'settings.diagnostics.subtitle': '连接状态、订阅状态和故障记录',
  'settings.rpc': 'RPC 调试器',
  'settings.rpc.subtitle': '发送原始 relay payload',
  'settings.services': '服务管理',
  'settings.services.subtitle': '插件 / 定时任务 / MCP / Skills',
  'settings.usage': '用量',
  'settings.usage.subtitle': '额度 / 配额限制 / 订阅详情',
  'settings.models': '模型供应商',
  'settings.models.subtitle': '添加 / 启停 / 删除模型供应商',
  'settings.channelRpc': 'Channel RPC 调试器',
  'settings.channelRpc.subtitle':
      '调用任意 channel 方法（zcode-task / skills / mcp …）',
  'settings.copyLink': '已复制 GitHub 链接',
  'accounts.add': '添加设备',
  'accounts.empty.title': '还没有设备',
  'accounts.scan': '扫码添加',
  'accounts.paste': '粘贴链接添加',
  'action.rename': '重命名',
  'action.delete': '删除',
  'action.archive': '归档',
  'action.unarchive': '取消归档',
  'action.pin': '置顶',
  'action.unpin': '取消置顶',
};

const _en = {
  'app.title': 'Zemote Remote',
  'nav.tasks': 'Tasks',
  'nav.settings': 'Settings',
  'home.search': 'Search tasks…',
  'home.tab.tasks': 'Tasks',
  'home.tab.pinned': 'Pinned',
  'home.tab.archived': 'Archived',
  'home.empty.tasks': 'No tasks yet. Tap + to start one.',
  'home.empty.pinned': 'No pinned tasks',
  'home.empty.archived': 'No archived tasks',
  'home.newTask': 'New task',
  'home.loadOlder': 'Load earlier messages',
  'chat.inputHint': 'Message ZCode…',
  'chat.empty': 'Type a message to start a new session',
  'chat.stop': 'Stop',
  'settings.title': 'Settings',
  'settings.appearance': 'Appearance',
  'settings.theme.dark': 'Dark',
  'settings.theme.light': 'Light',
  'settings.theme.system': 'System',
  'settings.language': 'Language',
  'settings.textScale': 'Text size',
  'settings.codeFont': 'Code font size',
  'settings.log': 'Protocol log',
  'settings.log.subtitle': 'View relay / IPC / V4 frame logs',
  'settings.disconnect': 'Disconnect device',
  'settings.section.general': 'General',
  'settings.section.advanced': 'Debug & Advanced',
  'settings.section.device': 'Device',
  'settings.checkUpdate': 'Check for updates',
  'settings.version': 'Current version v',
  'settings.version.hint': 'Checks the latest GitHub release',
  'settings.checking': 'Checking for updates…',
  'settings.upToDate': 'You are up to date v',
  'settings.checkFailed': 'Update check failed: ',
  'settings.betaUpdates': 'Receive Beta updates',
  'settings.betaUpdates.reading': 'Reading update channel…',
  'settings.betaUpdates.stable': 'Channel: Stable (recommended)',
  'settings.betaUpdates.beta': 'Channel: Stable + Beta',
  'settings.voiceInput': 'Offline voice input',
  'settings.voiceInput.subtitle':
      'Download, enable and manage local speech models',
  'settings.verboseFrames': 'Verbose protocol frames',
  'settings.verboseFrames.subtitle':
      'Log full relay frames (may contain sensitive data)',
  'settings.diagnostics': 'Diagnostics',
  'settings.diagnostics.subtitle':
      'Connection, subscription and failure records',
  'settings.rpc': 'RPC debugger',
  'settings.rpc.subtitle': 'Send raw relay payloads',
  'settings.services': 'Services',
  'settings.services.subtitle': 'Plugins / schedules / MCP / Skills',
  'settings.usage': 'Usage',
  'settings.usage.subtitle': 'Quota / limits / subscription details',
  'settings.models': 'Model providers',
  'settings.models.subtitle': 'Add / enable / remove model providers',
  'settings.channelRpc': 'Channel RPC debugger',
  'settings.channelRpc.subtitle':
      'Call any channel method (zcode-task / skills / mcp …)',
  'settings.copyLink': 'Copied GitHub link',
  'accounts.add': 'Add device',
  'accounts.empty.title': 'No devices yet',
  'accounts.scan': 'Scan QR code',
  'accounts.paste': 'Paste link',
  'action.rename': 'Rename',
  'action.delete': 'Delete',
  'action.archive': 'Archive',
  'action.unarchive': 'Unarchive',
  'action.pin': 'Pin',
  'action.unpin': 'Unpin',
};
