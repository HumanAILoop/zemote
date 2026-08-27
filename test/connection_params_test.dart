import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/protocol/connection_params.dart';

void main() {
  group('uriSchemeIsSecure', () {
    test('https → secure', () {
      final params = ZemoteConnectionParams(
        deviceSid: 'sid',
        passHash: 'hash',
        timestamp: 1,
        source: Uri.parse('https://zcode.z.ai/remote'),
      );
      expect(params.uriSchemeIsSecure, isTrue);
    });

    test('wss → secure', () {
      final params = ZemoteConnectionParams(
        deviceSid: 'sid',
        passHash: 'hash',
        timestamp: 1,
        source: Uri.parse('wss://zcode.z.ai/ws'),
      );
      expect(params.uriSchemeIsSecure, isTrue);
    });

    test('http → not secure', () {
      final params = ZemoteConnectionParams(
        deviceSid: 'sid',
        passHash: 'hash',
        timestamp: 1,
        source: Uri.parse('http://zcode.z.ai/remote'),
      );
      expect(params.uriSchemeIsSecure, isFalse);
    });

    test('ws → not secure', () {
      final params = ZemoteConnectionParams(
        deviceSid: 'sid',
        passHash: 'hash',
        timestamp: 1,
        source: Uri.parse('ws://zcode.z.ai/ws'),
      );
      expect(params.uriSchemeIsSecure, isFalse);
    });

    test('ftp → not secure (was bug)', () {
      final params = ZemoteConnectionParams(
        deviceSid: 'sid',
        passHash: 'hash',
        timestamp: 1,
        source: Uri.parse('ftp://bad.example.com/remote'),
      );
      expect(params.uriSchemeIsSecure, isFalse);
    });

    test('unknown scheme → not secure', () {
      final params = ZemoteConnectionParams(
        deviceSid: 'sid',
        passHash: 'hash',
        timestamp: 1,
        source: Uri.parse('file:///etc/passwd'),
      );
      expect(params.uriSchemeIsSecure, isFalse);
    });
  });

  group('relayWsUri', () {
    test('https → wss', () {
      final params = ZemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=m',
      );
      expect(params!.relayWsUri.toString(), 'wss://zcode.z.ai/ws?mid=m');
    });

    test('http is rejected', () {
      final params = ZemoteConnectionParams.parse(
        'http://localhost:3000/remote/v4?sid=s&hash=h&t=1',
      );
      expect(params, isNull);
    });

    test('port is preserved', () {
      final params = ZemoteConnectionParams.parse(
        'https://zcode.z.ai:8443/remote/v4?sid=s&hash=h&t=1',
      );
      expect(params!.relayWsUri.toString(), 'wss://zcode.z.ai:8443/ws');
    });

    test('no mid → no query params', () {
      final params = ZemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1',
      );
      expect(params!.relayWsUri.toString(), 'wss://zcode.z.ai/ws');
    });
  });

  group('parse edge cases', () {
    test('missing sid returns null', () {
      expect(
        ZemoteConnectionParams.parse(
            'https://zcode.z.ai/remote/v4?hash=h&t=1'),
        isNull,
      );
    });

    test('missing hash returns null', () {
      expect(
        ZemoteConnectionParams.parse(
            'https://zcode.z.ai/remote/v4?sid=s&t=1'),
        isNull,
      );
    });

    test('missing t returns null', () {
      expect(
        ZemoteConnectionParams.parse(
            'https://zcode.z.ai/remote/v4?sid=s&hash=h'),
        isNull,
      );
    });

    test('invalid timestamp returns null', () {
      expect(
        ZemoteConnectionParams.parse(
            'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=abc'),
        isNull,
      );
    });

    test('trimmed query values', () {
      final params = ZemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid= SID &hash= HASH &t=1',
      );
      expect(params, isNotNull);
      expect(params!.deviceSid, 'SID');
      expect(params.passHash, 'HASH');
    });

    test('empty optional fields are null', () {
      final params = ZemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&mid=&name=',
      );
      expect(params!.deviceMid, isNull);
      expect(params.deviceName, isNull);
    });

    test('theme is parsed', () {
      final params = ZemoteConnectionParams.parse(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&theme=dark',
      );
      expect(params!.theme, 'dark');
    });
  });
}
