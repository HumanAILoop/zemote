import 'package:flutter_test/flutter_test.dart';
import 'package:zemote/protocol/connection_params.dart';
import 'package:zemote/protocol/zemote_client.dart';

/// Read-only diagnostic probe: connect -> pair -> open bridge -> subscribe a
/// session and DUMP the row structure (kind/rowId/turnId/text length/state).
/// Used to diagnose real-world row grouping / ordering without guessing.
void main() {
  test('diagnostic probe', () async {
    final probeUrl = String.fromEnvironment('ZEMOTE_PROBE_URL',
        defaultValue: '');
    final params = probeUrl.isEmpty
        ? null
        : ZemoteConnectionParams.parse(probeUrl);
    if (params == null) {
      // ignore: avoid_print
      print('SKIP: ZEMOTE_PROBE_URL not set.');
      return;
    }

    final client = ZemoteClient(params);
    await client.connect();
    await client.waitPaired(timeout: const Duration(seconds: 60));
    // ignore: avoid_print
    print('=== paired ===');

    final bootstrap = await client.bootstrap();
    final wsList = bootstrap['workspaces'];
    if (wsList is! List || wsList.isEmpty) {
      // ignore: avoid_print
      print('no workspaces');
      await client.dispose();
      return;
    }
    final w = (wsList.first as Map).cast<String, dynamic>();
    final scope = {
      'workspacePath': w['workspacePath'],
      if (w['workspaceIdentity'] != null)
        'workspaceIdentity': w['workspaceIdentity'],
    };
    final workspaceKey =
        w['workspaceIdentity'] as String? ?? w['workspacePath'] as String;
    final bridge = await client.openBridge(workspaceKey);
    final transport = bridge.conversation(scope);
    // ignore: avoid_print
    print('=== bridge opened ===');

    // sessions-index: find the most recently active task
    final si = await transport.subscribeSessionsIndex();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (!si.state.ready && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    final sessions = si.state.list;
    // ignore: avoid_print
    print('=== sessions-index: ${sessions.length} sessions ===');
    for (final s in sessions.take(10)) {
      // ignore: avoid_print
      print('  ${s.sessionId} | ${s.title} | phase=${s.phase}');
    }
    if (sessions.isEmpty) {
      await si.dispose();
      await client.dispose();
      return;
    }

    final target = sessions.first;
    // ignore: avoid_print
    print('=== subscribing task ${target.sessionId} "${target.title}" ===');
    final conv = await transport.subscribe(target.sessionId);
    final convDeadline = DateTime.now().add(const Duration(seconds: 20));
    while (!conv.state.ready && DateTime.now().isBefore(convDeadline)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    final rows = conv.state.rows;
    // ignore: avoid_print
    print('=== conversation rows: ${rows.length} ===');
    for (final r in rows) {
      final kind = r['kind'];
      final rowId = r['rowId'];
      final turnId = r['turnId'];
      final text = (r['text'] as String? ?? r['inputText'] as String? ?? '');
      final preview = text.length > 60 ? '${text.substring(0, 60)}…' : text;
      // ignore: avoid_print
      print('  [$kind] rowId=$rowId turnId=$turnId '
          'state=${r['state']} len=${text.length} :: $preview');
    }

    await conv.dispose();
    await si.dispose();
    await client.dispose();
    // ignore: avoid_print
    print('=== done ===');
  }, timeout: const Timeout(Duration(minutes: 4)));
}
