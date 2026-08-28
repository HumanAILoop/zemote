import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zemote/protocol/connection_params.dart';
import 'package:zemote/protocol/zemote_client.dart';

// ignore_for_file: avoid_print

void main() {
  test('read-only real feature probe', () async {
    final url = _readUrl();
    final params = url.isEmpty ? null : ZemoteConnectionParams.parse(url);
    if (params == null) {
      print('SKIP: probe URL not set.');
      return;
    }

    final client = ZemoteClient(params);
    await client.connect();
    await client.waitPaired(timeout: const Duration(seconds: 60));
    final bootstrap = await client.bootstrap();
    final workspace =
        (bootstrap['workspaces'].first as Map).cast<String, dynamic>();
    final scope = <String, dynamic>{
      'workspacePath': workspace['workspacePath'],
      if (workspace['workspaceIdentity'] != null)
        'workspaceIdentity': workspace['workspaceIdentity'],
    };
    final key =
        '${workspace['workspaceIdentity'] ?? workspace['workspacePath']}';
    final bridge = await client.openBridge(key);
    final channels = bridge.channels;

    Future<void> probe(String name, Future<dynamic> Function() call) async {
      try {
        final value = await call();
        final shape = value is List
            ? 'list(${value.length})'
            : value is Map
                ? 'map(${value.keys.take(12).join(',')})'
                : '${value.runtimeType}';
        print('REAL $name: $shape');
      } catch (e) {
        print('REAL $name: FAIL ${e.runtimeType}');
      }
    }

    await probe('prepareWorkspace',
        () => bridge.conversation(scope).prepareWorkspace());
    await probe(
        'plugins', () => channels.call('zcode-agent', 'listPlugins', [scope]));
    await probe('automations',
        () => channels.call('zcode-agent', 'listAllAutomations', [scope]));
    await probe('skills', () => channels.call('skills', 'list', [scope]));
    await probe('commands', () => channels.call('commands', 'list', [scope]));
    await probe(
        'usage',
        () => channels.call('usage-stats', 'getEntitlementSnapshot', [
              {'includeSubscription': true},
            ]));

    final sessions = await bridge.conversation(scope).subscribeSessionsIndex();
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!sessions.state.ready && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    print(
        'REAL sessions: ready=${sessions.state.ready} count=${sessions.state.list.length}');

    if (sessions.state.list.isNotEmpty) {
      final conversation = await bridge
          .conversation(scope)
          .subscribe(sessions.state.list.first.sessionId);
      final conversationDeadline =
          DateTime.now().add(const Duration(seconds: 20));
      while (!conversation.state.ready &&
          DateTime.now().isBefore(conversationDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await probe(
          'plans',
          () => bridge
              .conversation(scope)
              .plans(sessions.state.list.first.sessionId));
      final headers = conversation.state.rows
          .where((row) => row['kind'] == 'turnHeader')
          .where((row) => row['state'] == 'completedSuccess')
          .toList();
      if (headers.isNotEmpty) {
        final row = headers.last;
        await probe(
            'fileChanges',
            () => bridge.conversation(scope).fileChanges(
                  sessions.state.list.first.sessionId,
                  target: {
                    'rowId': row['rowId'],
                    if (row['entityId'] != null) 'entityId': row['entityId'],
                  },
                  baseRevision: conversation.state.revision,
                  baseLogEpoch: conversation.state.logEpoch,
                ));
      } else {
        print('REAL fileChanges: SKIP no completed turn header');
      }
      await conversation.dispose();
    }

    await sessions.dispose();
    bridge.dispose();
    await client.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));
}

String _readUrl() {
  try {
    return File(r'C:\Users\zuimao\AppData\Local\Temp\opencode\probe_url.txt')
        .readAsStringSync()
        .trim();
  } catch (_) {
    return '';
  }
}
