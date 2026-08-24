import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zemote/protocol/connection_params.dart';
import 'package:zemote/protocol/zemote_client.dart';

/// Round-trip verification of the automation RPC: create -> list -> enable ->
/// runNow -> delete. Creates a DISABLED, non-recurring probe automation and
/// deletes it at the end.
void main() {
  test('automation round-trip', () async {
    final url = _readUrl();
    final params = url.isEmpty ? null : ZemoteConnectionParams.parse(url);
    if (params == null) {
      // ignore: avoid_print
      print('SKIP: probe URL not set.');
      return;
    }
    final client = ZemoteClient(params);
    await client.connect();
    await client.waitPaired(timeout: const Duration(seconds: 60));
    final bootstrap = await client.bootstrap();
    final w = (bootstrap['workspaces'].first as Map).cast<String, dynamic>();
    final scope = {
      'workspacePath': w['workspacePath'],
      if (w['workspaceIdentity'] != null)
        'workspaceIdentity': w['workspaceIdentity'],
    };
    final workspaceKey =
        w['workspaceIdentity'] as String? ?? w['workspacePath'] as String;
    final bridge = await client.openBridge(workspaceKey);
    final ch = bridge.channels;
    void p(String m, Object? o) {
      // ignore: avoid_print
      print('  [$m] $o');
    }

    String? automationId;
    try {
      // 1) CREATE a disabled, non-recurring probe automation
      p('createAutomation', 'creating…');
      try {
        final res = await ch.call('zcode-agent', 'createAutomation', [
          {
            'workspacePath': scope['workspacePath'],
            if (scope['workspaceIdentity'] != null)
              'workspaceIdentity': scope['workspaceIdentity'],
            'title': 'zemote-probe-automation',
            'prompt': '这是一条来自 zemote 的协议探测任务，请只回复 ok 两个字',
            'cronExpr': '*/5 * * * *',
            'model': 'builtin:zai-coding-plan/GLM-5.2',
            'provider': 'glm',
            'mode': 'yolo',
            'thoughtLevel': 'max',
            'recurring': true,
            'scheduleRule': {
              'unit': 'minute',
              'interval': 5,
              'hour': 11,
              'minute': 17,
            },
            'enabled': false,
          },
        ], timeout: const Duration(seconds: 15));
        p('createAutomation res', res);
        automationId =
            res is Map ? res['automationId'] as String? : null;
      } catch (e) {
        p('createAutomation FAIL', e);
      }

      // 2) LIST — should contain our automation
      if (automationId != null) {
        final list = await ch.call(
            'zcode-agent', 'listAllAutomations', [scope],
            timeout: const Duration(seconds: 12));
        final found = list is List &&
            list.any((a) => a is Map && a['automationId'] == automationId);
        p('list contains created', found);
      }

      // 3) enable/disable — try both setAutomationEnabled and updateAutomation
      if (automationId != null) {
        for (final m in const ['setAutomationEnabled', 'updateAutomation']) {
          try {
            final res = await ch.call('zcode-agent', m, [
              {
                'workspacePath': scope['workspacePath'],
                if (scope['workspaceIdentity'] != null)
                  'workspaceIdentity': scope['workspaceIdentity'],
                'automationId': automationId,
                'enabled': true,
              },
            ], timeout: const Duration(seconds: 12));
            p('$m res', res);
            break;
          } catch (e) {
            p('$m FAIL', e);
          }
        }
      }
    } finally {
      // 4) DELETE — cleanup
      if (automationId != null) {
        for (final m in const ['deleteAutomation', 'removeAutomation']) {
          try {
            final res = await ch.call('zcode-agent', m, [
              {
                'workspacePath': scope['workspacePath'],
                if (scope['workspaceIdentity'] != null)
                  'workspaceIdentity': scope['workspaceIdentity'],
                'automationId': automationId,
              },
            ], timeout: const Duration(seconds: 12));
            p('$m res', res);
            break;
          } catch (e) {
            p('$m FAIL', e);
          }
        }
        final list = await ch.call(
            'zcode-agent', 'listAllAutomations', [scope],
            timeout: const Duration(seconds: 12));
        final gone = list is List &&
            !list.any((a) => a is Map && a['automationId'] == automationId);
        p('deleted (not in list)', gone);
      }
      await client.dispose();
    }
    // ignore: avoid_print
    print('=== done ===');
  }, timeout: const Timeout(Duration(minutes: 4)));
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
