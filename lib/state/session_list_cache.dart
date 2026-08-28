import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SessionListCache {
  static const _prefix = 'zemote_session_list_v1_';
  static const maxEntries = 200;

  const SessionListCache();

  String keyFor(Map<String, dynamic> workspace) {
    final identity = '${workspace['workspaceIdentity'] ?? ''}'.trim();
    final path = '${workspace['workspacePath'] ?? ''}'.trim();
    final source = identity.isNotEmpty ? identity : path;
    return '$_prefix${sha256.convert(utf8.encode(source))}';
  }

  Future<List<Map<String, dynamic>>> read(
      Map<String, dynamic> workspace) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(keyFor(workspace));
      if (raw == null) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['tasks'] is! List) return const [];
      return (decoded['tasks'] as List)
          .whereType<Map>()
          .map((task) => task.cast<String, dynamic>())
          .where((task) => '${task['taskId'] ?? ''}'.isNotEmpty)
          .take(maxEntries)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> write(
    Map<String, dynamic> workspace,
    List<dynamic> tasks,
  ) async {
    final safeTasks = <Map<String, dynamic>>[];
    for (final value in tasks) {
      if (value is! Map || value['taskId'] == null) continue;
      safeTasks.add({
        'taskId': '${value['taskId']}',
        if (value['title'] != null) 'title': '${value['title']}',
        if (value['displayStatus'] != null)
          'displayStatus': '${value['displayStatus']}',
        if (value['status'] != null) 'status': '${value['status']}',
        if (value['lastAssistantPreview'] != null)
          'lastAssistantPreview': '${value['lastAssistantPreview']}',
        if (value['updatedAt'] is num) 'updatedAt': value['updatedAt'],
        if (value['createdAt'] is num) 'createdAt': value['createdAt'],
        if (value['hasBackgroundWork'] == true) 'hasBackgroundWork': true,
        if (value['needsAttention'] == true) 'needsAttention': true,
        if (value['pinned'] == true) 'pinned': true,
        if (value['unreadAt'] is num) 'unreadAt': value['unreadAt'],
        if (workspace['workspacePath'] != null)
          'workspacePath': workspace['workspacePath'],
        if (workspace['workspaceIdentity'] != null)
          'workspaceIdentity': workspace['workspaceIdentity'],
      });
      if (safeTasks.length >= maxEntries) break;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      keyFor(workspace),
      jsonEncode({
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'tasks': safeTasks,
      }),
    );
  }
}
