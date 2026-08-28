import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'protocol/relay_client.dart';
import 'state/account_store.dart';
import 'state/app_session.dart';
import 'state/log_store.dart';
import 'state/crash_report_service.dart';
import 'ui/accounts_page.dart';
import 'ui/theme.dart';
import 'ui/ui_settings.dart';
import 'update/update_checker.dart';
import 'update/update_dialog.dart';
import 'update/update_channel.dart';
import 'notifications/notifications.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final prefs = await SharedPreferences.getInstance();
    RelayClient.verboseFrames =
        prefs.getBool('relayVerboseFrames') ?? kDebugMode;
  } catch (_) {
    RelayClient.verboseFrames = kDebugMode;
  }
  if (!kIsWeb) {
    try {
      await crashReports.initialize();
      final previous = await crashReports.read();
      if (previous != null) {
        log('[诊断] 检测到上次异常退出（${previous.kind}）— 请检查诊断日志');
      }
    } catch (_) {}
  }
  runApp(const ZemoteApp());
}

class ZemoteApp extends StatefulWidget {
  const ZemoteApp({super.key});

  @override
  State<ZemoteApp> createState() => _ZemoteAppState();
}

class _ZemoteAppState extends State<ZemoteApp> {
  final AccountStore _store = AccountStore();
  final AppSession _session = AppSession();
  final ThemeController _theme = ThemeController();
  final UiSettings _uiSettings = UiSettings();

  @override
  void initState() {
    super.initState();
    notificationsService.init();
    _theme.load();
    _uiSettings.load();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdates());
  }

  /// Silent update check on startup — prompts only when a newer release
  /// exists; Android builds can download + install the APK in-app.
  Future<void> _checkForUpdates() async {
    try {
      await updateChannelSettings.load();
      final info = await checkForUpdates(
          includePrerelease: updateChannelSettings.receiveBetaUpdates);
      if (!info.isNewer) return;
      final context = navigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      await showUpdateDialog(context, info);
    } catch (_) {
      // Offline / API errors are ignored on startup.
    }
  }

  @override
  Widget build(BuildContext context) {
    return ThemeControllerProvider(
      controller: _theme,
      child: UiSettingsProvider(
        settings: _uiSettings,
        child: AnimatedBuilder(
          animation: Listenable.merge([_theme, _uiSettings]),
          builder: (context, _) => MaterialApp(
            title: 'Zemote',
            debugShowCheckedModeBanner: false,
            navigatorKey: navigatorKey,
            theme: buildLightTheme(),
            darkTheme: buildDarkTheme(),
            themeMode: _theme.mode,
            home: AccountsPage(store: _store, session: _session),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(_uiSettings.textScale),
              ),
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }
}
