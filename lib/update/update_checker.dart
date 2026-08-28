import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_version.dart';
import 'update_channel.dart';

/// Result of an update check against the GitHub latest release.
class UpdateAsset {
  final String abi;
  final String fileName;
  final String apkUrl;
  final String? md5Url;

  const UpdateAsset({
    required this.abi,
    required this.fileName,
    required this.apkUrl,
    this.md5Url,
  });
}

class UpdateInfo {
  final String latestVersion;
  final String releaseUrl;
  final String? body;
  final List<UpdateAsset> assets;
  final bool isNewer;
  final bool isPrerelease;

  const UpdateInfo({
    required this.latestVersion,
    required this.releaseUrl,
    this.body,
    this.assets = const [],
    required this.isNewer,
    this.isPrerelease = false,
  });
}

/// Queries `https://api.github.com/repos/HumanAILoop/zemote/releases/latest`
/// and compares the release tag with [currentVersion]. The release tag is
/// `vX.Y.Z`; the CI uploads one APK and MD5 file per Android ABI.
Future<UpdateInfo> checkForUpdates({
  String currentVersion = appVersion,
  bool? includePrerelease,
}) async {
  if (includePrerelease == null) {
    await updateChannelSettings.load();
  }
  final allowBeta =
      includePrerelease ?? updateChannelSettings.receiveBetaUpdates;
  final endpoint = allowBeta
      ? 'https://api.github.com/repos/HumanAILoop/zemote/releases?per_page=30'
      : 'https://api.github.com/repos/HumanAILoop/zemote/releases/latest';
  final res =
      await http.get(Uri.parse(endpoint)).timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) {
    throw UpdateCheckException(
        'GitHub API ${res.statusCode}: ${res.body.isEmpty ? res.reasonPhrase : res.body}');
  }
  final decoded = jsonDecode(res.body);
  final data = decoded is List
      ? decoded.whereType<Map>().where((item) => item['draft'] != true).toList()
      : decoded is Map
          ? [decoded]
          : const <Map>[];
  if (data.isEmpty) {
    throw const UpdateCheckException('invalid GitHub response');
  }
  final releases = data
      .map((item) => _ReleaseData.fromJson(item.cast<String, dynamic>()))
      .where((release) => allowBeta || !release.prerelease)
      .toList()
    ..sort((a, b) => compareVersions(b.version, a.version));
  if (releases.isEmpty) throw const UpdateCheckException('no usable release');
  final release = releases.first;
  final tag = release.tag;
  final version = tag.startsWith('v') ? tag.substring(1) : tag;
  final releaseUrl = release.url;
  final body = release.body;
  final assets = release.assets;
  final apkUrls = <String, String>{};
  final apkNames = <String, String>{};
  final md5Urls = <String, String>{};
  for (final a in assets.whereType<Map>()) {
    final name = '${a['name'] ?? ''}';
    final url = '${a['browser_download_url'] ?? ''}';
    if (url.isEmpty) continue;
    final abi = abiFromAssetName(name);
    if (abi == null) continue;
    if (name.endsWith('.apk')) {
      apkUrls[abi] = url;
      apkNames[abi] = name;
    } else if (name.endsWith('.apk.md5')) {
      md5Urls[abi] = url;
    }
  }
  final updateAssets = <UpdateAsset>[
    for (final abi in apkUrls.keys)
      UpdateAsset(
        abi: abi,
        fileName: apkNames[abi]!,
        apkUrl: apkUrls[abi]!,
        md5Url: md5Urls[abi],
      ),
  ];
  return UpdateInfo(
    latestVersion: version.isEmpty ? tag : version,
    releaseUrl: releaseUrl,
    body: body,
    assets: updateAssets,
    isNewer: version.isNotEmpty && compareVersions(version, currentVersion) > 0,
    isPrerelease: release.prerelease,
  );
}

class _ReleaseData {
  final String tag;
  final String version;
  final String url;
  final String? body;
  final bool prerelease;
  final List assets;

  const _ReleaseData({
    required this.tag,
    required this.version,
    required this.url,
    required this.body,
    required this.prerelease,
    required this.assets,
  });

  factory _ReleaseData.fromJson(Map<String, dynamic> json) {
    final tag = '${json['tag_name'] ?? ''}';
    return _ReleaseData(
      tag: tag,
      version: tag.startsWith('v') ? tag.substring(1) : tag,
      url:
          '${json['html_url'] ?? 'https://github.com/HumanAILoop/zemote/releases'}',
      body: json['body'] as String?,
      prerelease: json['prerelease'] == true,
      assets: json['assets'] is List ? json['assets'] as List : const [],
    );
  }
}

String? abiFromAssetName(String name) {
  for (final abi in const ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
    if (name.contains(abi)) return abi;
  }
  return null;
}

UpdateAsset? selectUpdateAsset(
    List<UpdateAsset> assets, List<String> supportedAbis) {
  for (final abi in supportedAbis) {
    for (final asset in assets) {
      if (asset.abi == abi) return asset;
    }
  }
  return null;
}

String? parseMd5Hex(String content) {
  return RegExp(r'\b[0-9a-fA-F]{32}\b')
      .firstMatch(content)
      ?.group(0)
      ?.toLowerCase();
}

class UpdateCheckException implements Exception {
  final String message;
  const UpdateCheckException(this.message);

  @override
  String toString() => 'UpdateCheckException: $message';
}

/// Semantic version compare on the first three numeric segments
/// (`major.minor.patch`). Handles `1.2` vs `1.2.0` as equal.
int compareVersions(String a, String b) {
  final va = _SemVer.parse(a);
  final vb = _SemVer.parse(b);
  if (va.major != vb.major) return va.major.compareTo(vb.major);
  if (va.minor != vb.minor) return va.minor.compareTo(vb.minor);
  if (va.patch != vb.patch) return va.patch.compareTo(vb.patch);
  if (va.prerelease.isEmpty && vb.prerelease.isNotEmpty) return 1;
  if (va.prerelease.isNotEmpty && vb.prerelease.isEmpty) return -1;
  for (var i = 0; i < va.prerelease.length || i < vb.prerelease.length; i++) {
    if (i >= va.prerelease.length) return -1;
    if (i >= vb.prerelease.length) return 1;
    final aPart = va.prerelease[i];
    final bPart = vb.prerelease[i];
    if (aPart == bPart) continue;
    final aNum = int.tryParse(aPart);
    final bNum = int.tryParse(bPart);
    if (aNum != null && bNum != null) return aNum.compareTo(bNum);
    if (aNum != null) return -1;
    if (bNum != null) return 1;
    return aPart.compareTo(bPart);
  }
  return 0;
}

class _SemVer {
  final int major;
  final int minor;
  final int patch;
  final List<String> prerelease;

  const _SemVer(this.major, this.minor, this.patch, this.prerelease);

  factory _SemVer.parse(String value) {
    final parts = value.split('+').first.split('-');
    final numbers =
        parts.first.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    return _SemVer(
      numbers.isNotEmpty ? numbers[0] : 0,
      numbers.length > 1 ? numbers[1] : 0,
      numbers.length > 2 ? numbers[2] : 0,
      parts.length > 1 ? parts.sublist(1).join('-').split('.') : const [],
    );
  }
}
