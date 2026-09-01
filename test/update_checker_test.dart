import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zemote/update/update_checker.dart';
import 'package:zemote/update/update_channel.dart';
import 'package:zemote/update/app_version.dart';

void main() {
  test('bundled app version matches the beta release currently being built',
      () {
    expect(appVersion, '0.5.2-beta.3');
    expect(appBuildNumber, 13);
  });

  test('beta channel setting persists', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = UpdateChannelSettings();
    await settings.load();
    expect(settings.receiveBetaUpdates, isFalse);
    await settings.setReceiveBetaUpdates(true);
    final reloaded = UpdateChannelSettings();
    await reloaded.load();
    expect(reloaded.receiveBetaUpdates, isTrue);
  });
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

    test('pre-release versions sort before stable versions', () {
      expect(compareVersions('0.5.0-beta.2', '0.5.0-beta.1'), greaterThan(0));
      expect(compareVersions('0.5.0-rc.1', '0.5.0-beta.9'), greaterThan(0));
      expect(compareVersions('0.5.0', '0.5.0-rc.1'), greaterThan(0));
      expect(compareVersions('0.5.0-beta.1', '0.5.0'), lessThan(0));
    });

    test('same beta release is not newer than the installed beta', () {
      expect(compareVersions('0.5.2-beta.3', appVersion), 0);
      expect(compareVersions('0.5.2-beta.4', appVersion), greaterThan(0));
      expect(compareVersions('0.5.2-beta.2', appVersion), lessThan(0));
    });

    test('build metadata does not affect precedence', () {
      expect(compareVersions('0.5.0+10', '0.5.0+1'), 0);
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
