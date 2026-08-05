import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_version.dart';

/// Result of an update check against the GitHub latest release.
class UpdateInfo {
  final String latestVersion;
  final String releaseUrl;
  final String? body;
  final String? apkUrl;
  final bool isNewer;

  const UpdateInfo({
    required this.latestVersion,
    required this.releaseUrl,
    this.body,
    this.apkUrl,
    required this.isNewer,
  });
}

/// Queries `https://api.github.com/repos/HumanAILoop/zemote/releases/latest`
/// and compares the release tag with [currentVersion]. The release tag is
/// `vX.Y.Z`; the CI (`build-apk.yml`) uploads `app-release.apk` as an asset.
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
  final releaseUrl = '${data['html_url'] ?? 'https://github.com/HumanAILoop/zemote/releases'}';
  final body = data['body'] as String?;
  final assets = data['assets'];
  String? apkUrl;
  if (assets is List) {
    for (final a in assets.whereType<Map>()) {
      if ('${a['name'] ?? ''}'.endsWith('.apk')) {
        final url = '${a['browser_download_url'] ?? ''}';
        if (url.isNotEmpty) {
          apkUrl = url;
          break;
        }
      }
    }
  }
  return UpdateInfo(
    latestVersion: version.isEmpty ? tag : version,
    releaseUrl: releaseUrl,
    body: body,
    apkUrl: apkUrl,
    isNewer: version.isNotEmpty &&
        compareVersions(version, currentVersion) > 0,
  );
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
