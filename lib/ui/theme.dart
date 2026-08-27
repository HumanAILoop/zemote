import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Design tokens + theme controller (dark / light / system, persisted).
class ThemeController extends ChangeNotifier {
  static const _prefsKey = 'zemote_theme_mode';

  ThemeMode _mode = ThemeMode.dark;
  ThemeMode get mode => _mode;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    _mode = switch (saved) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
    notifyListeners();
  }

  Future<void> setMode(ThemeMode mode) async {
    _mode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.system => 'system',
        _ => 'dark',
      },
    );
  }
}

class ZColors {
  static const primary = Color(0xFF3B82F6);
  static const primaryDim = Color(0xFF2563EB);
  static const darkBg = Color(0xFF0B1220);
  static const darkSurface = Color(0xFF111A2E);
  static const darkCard = Color(0xFF16203A);
  static const darkBorder = Color(0x1FFFFFFF);
  static const success = Color(0xFF22C55E);
  static const warning = Color(0xFFF59E0B);
  static const danger = Color(0xFFEF4444);
  static const running = Color(0xFF38BDF8);

  static const lightBg = Color(0xFFF6F8FC);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightCard = Color(0xFFFFFFFF);
  static const lightBorder = Color(0x14000000);
}

/// Theme-aware ink colors. Replaces hardcoded `Colors.white*` (dark-theme
/// ink) which become illegible on the light surfaces. The dark theme keeps
/// the existing white ramp; the light theme maps it onto a slate ramp so
/// text/icons stay readable on white backgrounds.
class ZInk {
  static bool _isLight(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light;

  static const _slate = Color(0xFF0F172A);
  static const _slate700 = Color(0xFF334155);
  static const _slate600 = Color(0xFF475569);
  static const _slate500 = Color(0xFF64748B);
  static const _slate400 = Color(0xFF94A3B8);
  static const _slate300 = Color(0xFFCBD5E1);

  /// Primary text/ink (dark: `Colors.white`, light: slate-900).
  static Color solid(BuildContext context) =>
      _isLight(context) ? _slate : Colors.white;

  /// Secondary ink (dark: `Colors.white70`, light: slate-700).
  static Color soft(BuildContext context) =>
      _isLight(context) ? _slate700 : Colors.white70;

  /// Muted ink (dark: `Colors.white54`, light: slate-600).
  static Color muted(BuildContext context) =>
      _isLight(context) ? _slate600 : Colors.white54;

  /// Faint ink (dark: `Colors.white38`, light: slate-500).
  static Color faint(BuildContext context) =>
      _isLight(context) ? _slate500 : Colors.white38;

  /// Ghost ink (dark: `Colors.white24`, light: slate-400).
  static Color ghost(BuildContext context) =>
      _isLight(context) ? _slate400 : Colors.white24;

  /// Hairline ink (dark: `Colors.white12`, light: slate-300).
  static Color hairline(BuildContext context) =>
      _isLight(context) ? _slate300 : Colors.white12;

  /// Subtle tile fill (dark: white@4%, light: black@4%).
  static Color tile(BuildContext context) => _isLight(context)
      ? const Color(0x0A0F172A)
      : Colors.white.withValues(alpha: 0.04);

  /// Tile hairline border (dark: white@6%, light: black@6%).
  static Color tileBorder(BuildContext context) => _isLight(context)
      ? const Color(0x0F0F172A)
      : Colors.white.withValues(alpha: 0.06);

  /// High-contrast panel fill for reasoning/tool cards.
  static Color panel(BuildContext context) =>
      _isLight(context) ? const Color(0xFFE8EEF8) : const Color(0xFF17233D);

  /// Visible panel outline in both themes.
  static Color panelBorder(BuildContext context) =>
      _isLight(context) ? const Color(0xFFB8C7DD) : const Color(0xFF344563);

  /// Reasoning-specific fill, visually distinct from tool output.
  static Color reasoningPanel(BuildContext context) =>
      _isLight(context) ? const Color(0xFFE9F2FF) : const Color(0xFF132A46);

  static Color reasoningBorder(BuildContext context) =>
      _isLight(context) ? const Color(0xFF9DBCE2) : const Color(0xFF315A82);

  /// Code block background (light: slate-100 so code stays readable).
  static Color codeBlockBg(BuildContext context) =>
      _isLight(context) ? const Color(0xFFF1F5F9) : const Color(0xFF0B1220);

  /// Inline code background.
  static Color codeInlineBg(BuildContext context) => _isLight(context)
      ? const Color(0x140F172A)
      : Colors.white.withValues(alpha: 0.08);

  /// Code text (light: dark blue for contrast on the light block).
  static Color codeText(BuildContext context) =>
      _isLight(context) ? const Color(0xFF1E3A8A) : const Color(0xFF93C5FD);
}

ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: ZColors.primary,
    brightness: Brightness.dark,
  ).copyWith(
    primary: ZColors.primary,
    surface: ZColors.darkSurface,
    surfaceContainerHighest: ZColors.darkCard,
    outline: ZColors.darkBorder,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: ZColors.darkBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: ZColors.darkBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
      iconTheme: IconThemeData(color: Colors.white70),
    ),
    cardTheme: CardThemeData(
      color: ZColors.darkCard,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: ZColors.darkBorder),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ZColors.darkSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.darkBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.darkBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.primary, width: 1.5),
      ),
      hintStyle: const TextStyle(color: Colors.white30, fontSize: 14),
    ),
    dividerTheme: const DividerThemeData(
      color: ZColors.darkBorder,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: ZColors.darkCard,
      contentTextStyle: const TextStyle(color: Colors.white),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: ZColors.darkSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: ZColors.darkSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: ZColors.primary,
      unselectedLabelColor: Colors.white38,
      indicatorColor: ZColors.primary,
      dividerColor: ZColors.darkBorder,
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(color: Colors.white, fontSize: 14, height: 1.5),
      bodySmall: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
      titleMedium: TextStyle(
          color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
      labelSmall: TextStyle(color: Colors.white38, fontSize: 11),
    ),
  );
}

ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: ZColors.primary,
    brightness: Brightness.light,
  ).copyWith(
    primary: ZColors.primaryDim,
    surface: ZColors.lightSurface,
    outline: ZColors.lightBorder,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: ZColors.lightBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: ZColors.lightBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: Color(0xFF0F172A),
      ),
      iconTheme: IconThemeData(color: Color(0xFF475569)),
    ),
    cardTheme: CardThemeData(
      color: ZColors.lightCard,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: ZColors.lightBorder),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ZColors.lightSurface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.lightBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.lightBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ZColors.primary, width: 1.5),
      ),
      hintStyle: const TextStyle(color: Colors.black26, fontSize: 14),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: ZColors.lightSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: ZColors.lightSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    tabBarTheme: const TabBarThemeData(
      labelColor: ZColors.primaryDim,
      unselectedLabelColor: Colors.black38,
      indicatorColor: ZColors.primaryDim,
      dividerColor: ZColors.lightBorder,
    ),
  );
}

/// Provides the app-wide [ThemeController] down the tree.
class ThemeControllerProvider extends InheritedWidget {
  final ThemeController controller;

  const ThemeControllerProvider({
    super.key,
    required this.controller,
    required super.child,
  });

  static ThemeController? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ThemeControllerProvider>()
      ?.controller;

  @override
  bool updateShouldNotify(ThemeControllerProvider oldWidget) =>
      controller != oldWidget.controller;
}

/// Status color mapping shared by task/chat UIs. The unknown-status fallback
/// is theme-aware so it stays visible on light surfaces too.
Color statusColor(String status, BuildContext context) {
  switch (status) {
    case 'running':
    case 'prewarming':
      return ZColors.running;
    case 'error':
    case 'failed':
      return ZColors.danger;
    case 'completed':
    case 'completedSuccess':
      return ZColors.success;
    case 'completedInterrupted':
    case 'cancelled':
      return ZColors.warning;
    default:
      return ZInk.faint(context);
  }
}

/// Human relative time, e.g. `刚刚` / `5分钟前` / `昨天` / `3天前`.
String relativeTime(int? millis) {
  if (millis == null || millis <= 0) return '';
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes}分钟前';
  if (diff.inHours < 24) return '${diff.inHours}小时前';
  if (diff.inDays == 1) return '昨天';
  if (diff.inDays < 30) return '${diff.inDays}天前';
  return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
      '${time.day.toString().padLeft(2, '0')}';
}
