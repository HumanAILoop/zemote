import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/protocol/channel_client.dart';
import 'package:zemote/protocol/connection_params.dart';
import 'package:zemote/protocol/zemote_client.dart';
import 'package:zemote/ui/task_home_page.dart';

void main() {
  test('read-only real session list probe', () async {
    const encodedUrl = String.fromEnvironment('ZEMOTE_PROBE_URL_B64');
    if (encodedUrl.isEmpty) return;
    final url = utf8.decode(base64.decode(encodedUrl));
    final params = ZemoteConnectionParams.parse(url);
    expect(params, isNotNull);

    final client = ZemoteClient(params!);
    await client.connect();
    await client.waitPaired(timeout: const Duration(seconds: 60));
    final bootstrap = await client.bootstrap();
    final workspaces = bootstrap['workspaces'];
    expect(workspaces, isA<List>());
    expect(workspaces as List, isNotEmpty);

    final workspace = (workspaces.first as Map).cast<String, dynamic>();
    final scope = <String, dynamic>{
      'workspacePath': workspace['workspacePath'],
      if (workspace['workspaceIdentity'] != null)
        'workspaceIdentity': workspace['workspaceIdentity'],
    };
    final workspaceKey =
        '${workspace['workspaceIdentity'] ?? workspace['workspacePath']}';
    final bridge = await client.openBridge(workspaceKey);
    final transport = bridge.conversation(scope);

    final channelTasks = await bridge.channels.call(
      Channels.zcodeTask,
      'listTasks',
      [scope],
      timeout: const Duration(seconds: 30),
    );
    final sessions = await transport.subscribeSessionsIndex();
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!sessions.state.ready && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    final merged = mergeWorkspaceSessionTasks(
      channelTasks: channelTasks is List ? channelTasks : const [],
      sessions: sessions.state.list,
      archivedIds: const {},
      workspace: workspace,
    );

    // ignore: avoid_print
    print(
        'REAL SESSION LIST: channel=${channelTasks is List ? channelTasks.length : 0} '
        'sessions=${sessions.state.list.length} merged=${merged.length}');
    for (final task in merged.take(10)) {
      // ignore: avoid_print
      print(
          '  ${task['taskId']} | ${task['title']} | ${task['displayStatus']}');
    }

    expect(sessions.state.ready, isTrue);
    expect(merged, isNotEmpty);
    await sessions.dispose();
    bridge.dispose();
    await client.dispose();
  }, timeout: const Timeout(Duration(minutes: 3)));
}
