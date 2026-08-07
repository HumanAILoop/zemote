import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Global instance initialized once in `main()`.
final notificationsService = Notifications();

/// Thin wrapper over the Android notification/nav platform channels
/// (`zemote/notifications`, `zemote/nav`). Non-Android platforms no-op.
class Notifications {
  static const _channel = MethodChannel('zemote/notifications');
  static const _nav = MethodChannel('zemote/nav');

  Future<void> Function(Map<String, dynamic> payload)? _tapHandler;
  bool _initialized = false;

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Registers the native→Dart tap callback and drains any cold-start payload
  /// (accepted behavior: cold-start payloads are dropped, warm taps are routed).
  void init() {
    if (_initialized || !isSupported) return;
    _initialized = true;
    _nav.setMethodCallHandler((call) async {
      if (call.method == 'onNotificationTap' && call.arguments is String) {
        _dispatch(call.arguments as String);
      }
      return null;
    });
    // Cold start: just consume the payload so it doesn't linger.
    _nav.invokeMethod<String>('getLaunchPayload').then((p) {
      if (p != null) _dispatch(p);
    }).catchError((_) {});
  }

  void _dispatch(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _tapHandler?.call(decoded.cast<String, dynamic>());
      }
    } catch (_) {}
  }

  void setTapHandler(Future<void> Function(Map<String, dynamic> payload)? h) {
    _tapHandler = h;
  }

  Future<void> startForeground(String title, String text) =>
      _channel.invokeMethod('startForeground', {'title': title, 'text': text});

  Future<void> updateForeground(String title, String text) =>
      _channel.invokeMethod(
          'updateForeground', {'title': title, 'text': text});

  Future<void> stopForeground() => _channel.invokeMethod('stopForeground');

  Future<void> notifyTaskCompleted({
    required String title,
    required String text,
    required Map<String, dynamic> payload,
  }) =>
      _channel.invokeMethod('notifyTaskCompleted', {
        'title': title,
        'text': text,
        'payload': jsonEncode(payload),
      });

  Future<bool> hasPermission() async {
    final ok = await _channel.invokeMethod<bool>('hasNotificationPermission');
    return ok ?? true;
  }

  Future<void> requestPermission() =>
      _channel.invokeMethod('requestNotificationPermission');
}
