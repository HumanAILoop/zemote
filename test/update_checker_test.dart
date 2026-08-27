import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/update/update_checker.dart';

void main() {
  group('compareVersions', () {
    test('equal versions', () {
      expect(compareVersions('0.2.0', '0.2.0'), 0);
      expect(compareVersions('1.2', '1.2.0'), 0);
    });

    test('newer detection', () {
      expect(compareVersions('0.3.0', '0.2.0'), greaterThan(0));
      expect(compareVersions('1.0.0', '0.9.9'), greaterThan(0));
      expect(compareVersions('0.2.10', '0.2.9'), greaterThan(0));
    });

    test('older detection', () {
      expect(compareVersions('0.1.0', '0.2.0'), lessThan(0));
      expect(compareVersions('0.2.9', '0.2.10'), lessThan(0));
    });

    test('malformed segments treated as zero', () {
      expect(compareVersions('x.y', '0.0.0'), 0);
      expect(compareVersions('1.x', '1.0.0'), 0);
    });
  });

  test('parseChecksumHex accepts sha256sum output', () {
    expect(
      parseChecksumHex(
          'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  app.apk'),
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    expect(parseChecksumHex('not a checksum'), isNull);
  });
}
