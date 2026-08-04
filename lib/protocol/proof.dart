import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Mirrors `aen()` / `ien()` in the web client:
/// proof = base64url_nopad(HMAC-SHA256(key: utf8(passHash),
///                                    msg: utf8('$nonce|$role|$deviceSid')))
String calculateProof({
  required String passHash,
  required String nonce,
  required String role,
  required String deviceSid,
}) {
  final hmac = Hmac(sha256, utf8.encode(passHash));
  final digest = hmac.convert(utf8.encode('$nonce|$role|$deviceSid'));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}
