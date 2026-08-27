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

  test('parseMd5Hex accepts md5sum output', () {
    expect(
      parseMd5Hex('AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA  app.apk'),
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );
    expect(parseMd5Hex('not a checksum'), isNull);
  });

  test('selectUpdateAsset follows Android supported ABI order', () {
    const assets = [
      UpdateAsset(
        abi: 'x86_64',
        fileName: 'zemote-x86_64.apk',
        apkUrl: 'x86',
      ),
      UpdateAsset(
        abi: 'arm64-v8a',
        fileName: 'zemote-arm64-v8a.apk',
        apkUrl: 'arm64',
      ),
    ];
    expect(
      selectUpdateAsset(assets, ['arm64-v8a', 'armeabi-v7a'])?.apkUrl,
      'arm64',
    );
    expect(selectUpdateAsset(assets, ['armeabi-v7a']), isNull);
  });

  test('abiFromAssetName recognizes split APK assets', () {
    expect(abiFromAssetName('zemote-arm64-v8a.apk'), 'arm64-v8a');
    expect(abiFromAssetName('zemote-armeabi-v7a.apk.md5'), 'armeabi-v7a');
    expect(abiFromAssetName('zemote-universal.apk'), isNull);
  });
}
