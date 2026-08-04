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
  final locale =
      UiSettingsProvider.of(context)?.locale ?? 'zh-CN';
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
  'settings.disconnect': '断开当前设备',
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
  'settings.disconnect': 'Disconnect device',
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
