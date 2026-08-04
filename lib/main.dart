import 'package:flutter/material.dart';

import 'state/account_store.dart';
import 'state/app_session.dart';
import 'ui/accounts_page.dart';
import 'ui/theme.dart';
import 'ui/ui_settings.dart';

void main() {
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
    _theme.load();
    _uiSettings.load();
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
            theme: buildLightTheme(),
            darkTheme: buildDarkTheme(),
            themeMode: _theme.mode,
            home: AccountsPage(store: _store, session: _session),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler:
                    TextScaler.linear(_uiSettings.textScale),
              ),
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
  }
}
