import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Encrypts device credentials with Android Keystore (AES/GCM) so the
/// connection URLs aren't stored in plaintext. Non-Android platforms return
/// null (plaintext fallback).
class CredentialCipher {
  static const _channel = MethodChannel('zemote/crypto');
  static const prefix = 'enc:';

  static bool get _isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Encrypts [plain]. Returns `enc:<base64>` on Android, or null if
  /// unsupported / failed (caller falls back to plaintext).
  static Future<String?> encrypt(String plain) async {
    if (!_isSupported || plain.isEmpty) return null;
    try {
      final enc = await _channel.invokeMethod<String>('encrypt', {'value': plain});
      if (enc == null || enc.isEmpty) return null;
      return '$prefix$enc';
    } catch (_) {
      return null;
    }
  }

  /// Decrypts a stored value: strips `enc:` and decrypts via Keystore.
  /// Returns the plaintext, or null if the value isn't encrypted / failed.
  static Future<String?> decrypt(String stored) async {
    if (!_isSupported || !stored.startsWith(prefix)) return null;
    try {
      final plain = await _channel.invokeMethod<String>(
          'decrypt', {'value': stored.substring(prefix.length)});
      if (plain == null || plain.isEmpty) return null;
      return plain;
    } catch (_) {
      return null;
    }
  }

  /// Whether [stored] is an encrypted value (has the `enc:` prefix).
  static bool isEncrypted(String stored) => stored.startsWith(prefix);
}
