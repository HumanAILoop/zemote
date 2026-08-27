import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_version.dart';

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

  const UpdateInfo({
    required this.latestVersion,
    required this.releaseUrl,
    this.body,
    this.assets = const [],
    required this.isNewer,
  });
}

/// Queries `https://api.github.com/repos/HumanAILoop/zemote/releases/latest`
/// and compares the release tag with [currentVersion]. The release tag is
/// `vX.Y.Z`; the CI uploads one APK and MD5 file per Android ABI.
Future<UpdateInfo> checkForUpdates({
  String currentVersion = appVersion,
}) async {
  final res = await http
      .get(Uri.parse(
          'https://api.github.com/repos/HumanAILoop/zemote/releases/latest'))
      .timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) {
    throw UpdateCheckException(
        'GitHub API ${res.statusCode}: ${res.body.isEmpty ? res.reasonPhrase : res.body}');
  }
  final data = jsonDecode(res.body);
  if (data is! Map) {
    throw const UpdateCheckException('invalid GitHub response');
  }
  final tag = '${data['tag_name'] ?? ''}';
  final version = tag.startsWith('v') ? tag.substring(1) : tag;
  final releaseUrl =
      '${data['html_url'] ?? 'https://github.com/HumanAILoop/zemote/releases'}';
  final body = data['body'] as String?;
  final assets = data['assets'];
  final apkUrls = <String, String>{};
  final apkNames = <String, String>{};
  final md5Urls = <String, String>{};
  if (assets is List) {
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
  );
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
  final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
  for (var i = 0; i < 3; i++) {
    final x = pa.length > i ? pa[i] : 0;
    final y = pb.length > i ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}
