/// Parses a ZCode web-remote connection URL, e.g.
/// https://zcode.z.ai/remote/v4?sid=...&hash=...&t=...&mid=...&name=...&app_version=...
///
/// Mirrors `zC()` in the web client bundle.
class ZemoteConnectionParams {
  final String deviceSid;
  final String passHash;
  final int timestamp;
  final String? deviceMid;
  final String? deviceName;
  final String? appVersion;
  final String? theme;
  final Uri source;

  const ZemoteConnectionParams({
    required this.deviceSid,
    required this.passHash,
    required this.timestamp,
    required this.source,
    this.deviceMid,
    this.deviceName,
    this.appVersion,
    this.theme,
  });

  static String? _get(Uri uri, String key) {
    final v = uri.queryParameters[key]?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  static ZemoteConnectionParams? parse(String raw) {
    Uri uri;
    try {
      uri = Uri.parse(raw.trim());
    } catch (_) {
      return null;
    }
    final sid = _get(uri, 'sid');
    final hash = _get(uri, 'hash');
    final t = int.tryParse(_get(uri, 't') ?? '');
    if ((uri.scheme != 'https' && uri.scheme != 'wss') ||
        sid == null ||
        hash == null ||
        t == null) return null;
    return ZemoteConnectionParams(
      deviceSid: sid,
      passHash: hash,
      timestamp: t,
      deviceMid: _get(uri, 'mid'),
      deviceName: _get(uri, 'name'),
      appVersion: _get(uri, 'app_version'),
      theme: _get(uri, 'theme'),
      source: uri,
    );
  }

  /// Relay websocket URL. Mirrors `Jc()` / `pen.connect()`:
  /// `${ws(s)://<host>/ws` plus `?mid=` when present.
  Uri get relayWsUri {
    final scheme = uriSchemeIsSecure ? 'wss' : 'ws';
    final base = Uri(
      scheme: scheme,
      host: source.host,
      port: source.hasPort ? source.port : null,
      path: '/ws',
    );
    if (deviceMid == null) return base;
    return base.replace(queryParameters: {'mid': deviceMid});
  }

  bool get uriSchemeIsSecure => source.scheme == 'https' || source.scheme == 'wss';
}
