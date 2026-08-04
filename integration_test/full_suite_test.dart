import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zemote/protocol/connection_params.dart';
import 'package:zemote/protocol/zemote_client.dart';

/// Full feature suite against the real desktop. Every check logs
/// [PASS]/[FAIL]; non-critical protocol rejections are recorded as [INFO].
///
/// Requires a real ZCode remote-control URL via the `ZEMOTE_PROBE_URL`
/// environment variable (e.g. `ZEMOTE_PROBE_URL=https://zcode.z.ai/remote/v4?sid=...`
/// `flutter test integration_test`). Without it the suite is skipped.
void main() {
  test('full feature suite', () async {
    final probeUrl = String.fromEnvironment('ZEMOTE_PROBE_URL',
        defaultValue: '');
    final params = probeUrl.isEmpty
        ? null
        : ZemoteConnectionParams.parse(probeUrl);
    if (params == null) {
      // ignore: avoid_print
      print('SKIP: ZEMOTE_PROBE_URL not set or invalid — integration '
          'suite requires a live desktop + real device URL.');
      return;
    }
    final results = <String>[];
    void check(String name, bool ok, [String? detail]) {
      final line =
          '[${ok ? 'PASS' : 'FAIL'}] $name${detail != null ? ' — $detail' : ''}';
      results.add(line);
      // ignore: avoid_print
      print(line);
      if (!ok) fail(line);
    }

    void info(String line) {
      results.add('[INFO] $line');
      // ignore: avoid_print
      print('[INFO] $line');
    }

    void log(String line) {
      // ignore: avoid_print
      print(line);
    }

    bool ackOk(dynamic res) =>
        res is Map &&
        (res['status'] == 'accepted' ||
            res['status'] == 'noop' ||
            res['status'] == 'duplicate');

    final client = ZemoteClient(params, onLog: log);

    // 1. relay connect + pair
    await client.connect();
    await client.waitPaired(timeout: const Duration(seconds: 60));
    check('relay 配对', true);

    // 2. bootstrap
    final bootstrap = await client.bootstrap();
    final wsList = bootstrap['workspaces'];
    check('bootstrap 返回工作区', wsList is List && wsList.isNotEmpty);
    final w = (wsList.first as Map).cast<String, dynamic>();
    final scope = {
      'workspacePath': w['workspacePath'],
      if (w['workspaceIdentity'] != null)
        'workspaceIdentity': w['workspaceIdentity'],
    };

    // 3. workspace-list
    final listRes = await client.listWorkspaces();
    check('workspace-list', listRes is Map);

    // 4. open bridge
    final bridge = await client.openBridge(
        w['workspaceIdentity'] as String? ?? w['workspacePath'] as String);
    check('workspace-bridge-open', bridge.bridge.isNotEmpty);

    // 5. IPC init + listTasks
    final transport = bridge.conversation(scope, onLog: log);
    final tasks = await bridge.channels.call(
      'zcode-task',
      'listTasks',
      [scope],
      timeout: const Duration(seconds: 30),
    );
    check('IPC init + listTasks', tasks is List, 'count=${tasks is List ? tasks.length : '?'}');

    // 6. pinned/archived lists
    final pinned = await bridge.channels
        .call('zcode-task', 'listPinnedTasks', [scope])
        .catchError((Object e) => 'ERR:$e');
    check('listPinnedTasks', pinned is List);
    final archived = await bridge.channels
        .call('zcode-task', 'listArchivedTasks', [scope])
        .catchError((Object e) => 'ERR:$e');
    check('listArchivedTasks', archived is List);

    // 7. prepareWorkspace
    final prep = await transport.prepareWorkspace();
    check('prepareWorkspace', prep.configOptions.isNotEmpty,
        'slashCommands=${prep.slashCommands.length}');

    // 8. createSession with config
    final modelOpt = prep.option('model');
    final sessionId = await transport.createSession(
      w['workspaceIdentity'] as String? ?? w['workspacePath'] as String,
      config: modelOpt != null && modelOpt.options.isNotEmpty
          ? {
              'provider':
                  modelOpt.options.first.value.split('/').first.contains(':')
                      ? modelOpt.options.first.value
                          .substring(0, modelOpt.options.first.value.lastIndexOf('/'))
                      : null,
              'model': modelOpt.options.first.value
                  .substring(modelOpt.options.first.value.lastIndexOf('/') + 1),
            }
          : null,
    );
    check('createSession(config)', sessionId.isNotEmpty, sessionId);

    // 9. subscribe
    final sub = await transport.subscribe(sessionId);
    final readyDeadline = DateTime.now().add(const Duration(seconds: 15));
    while (!sub.state.ready && DateTime.now().isBefore(readyDeadline)) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    check('订阅会话快照', sub.state.ready, 'rows=${sub.state.rows.length}');

    // 10. sendText + streaming
    final sendRes = await transport.sendText(sessionId, '只回复ok两个字');
    check('sendText accepted', ackOk(sendRes), '$sendRes');
    final streamDeadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(streamDeadline)) {
      final assistant = sub.state.rows
          .where((r) => r['kind'] == 'assistantText')
          .toList();
      if (assistant.isNotEmpty &&
          assistant.last['state'] == 'complete') {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    final assistantRows =
        sub.state.rows.where((r) => r['kind'] == 'assistantText').toList();
    check('流式回复完成', assistantRows.isNotEmpty,
        'rows=${sub.state.rows.length}');

    // 11. switchModelConfig (CAS) — thought level must be valid for the
    // target model; look it up from model-provider's reasoning metadata
    if (modelOpt != null && modelOpt.options.isNotEmpty) {
      final v = modelOpt.options.last.value;
      final idx = v.lastIndexOf('/');
      final providerId = v.substring(0, idx);
      final modelId = v.substring(idx + 1);
      var thought = sub.state.currentThought.isNotEmpty
          ? sub.state.currentThought
          : 'enabled';
      try {
        final providers =
            await bridge.channels.call('model-provider', 'getAll', []);
        if (providers is List) {
          for (final p in providers.whereType<Map>()) {
            if (p['id'] != providerId) continue;
            for (final m in (p['models'] as List? ?? []).whereType<Map>()) {
              if (m['id'] == modelId && m['reasoning'] is Map) {
                final reasoning = m['reasoning'] as Map;
                final levels = reasoning['levels'];
                final valid = levels is Map
                    ? levels.keys.map((e) => '$e').toList()
                    : <String>[];
                if (valid.isNotEmpty && !valid.contains(thought)) {
                  thought = '${reasoning['defaultLevel'] ?? valid.first}';
                }
              }
            }
          }
        }
      } catch (_) {}
      final res = await transport.switchModelConfig(
        sessionId,
        provider: providerId,
        model: modelId,
        thought: thought,
      );
      check('switchModelConfig (CAS)', ackOk(res), '$res');
    }

    // 12. switchCollaborationMode (CAS)
    final modeRes =
        await transport.switchCollaborationMode(sessionId, 'plan');
    check('switchCollaborationMode (CAS)', ackOk(modeRes), '$modeRes');
    await transport.switchCollaborationMode(sessionId, 'build');

    // 13. setFollowupMode (CAS)
    final fmRes = await transport.setFollowupMode(sessionId, 'guide');
    check('setFollowupMode (CAS)', ackOk(fmRes), '$fmRes');
    await transport.setFollowupMode(sessionId, 'queue');

    // 14. setAssistantFeedback (CAS + baseLogEpoch)
    final targetRow = sub.state.rows
        .where((r) => r['kind'] == 'assistantText')
        .lastOrNull;
    if (targetRow != null) {
      final fbRes = await transport.setAssistantFeedback(
        sessionId,
        {
          'rowId': targetRow['rowId'],
          if (targetRow['entityId'] != null)
            'entityId': targetRow['entityId'],
        },
        'like',
      );
      check('setAssistantFeedback (CAS+epoch)', ackOk(fbRes), '$fbRes');
    }

    // 15. queue ops (CAS): disable autoDrain, queue while running, then act
    final adRes = await transport.setAutoDrain(sessionId, false);
    check('setAutoDrain (CAS)', ackOk(adRes), '$adRes');
    await transport.sendText(sessionId, '倒计时从10数到1，每个数字单独一行');
    await Future.delayed(const Duration(milliseconds: 800));
    final q1 = await transport.sendText(sessionId, '排队消息测试');
    info('queue sendText: $q1');
    await Future.delayed(const Duration(seconds: 2));
    var queueItems = sub.state.queueItems;
    if (queueItems.isEmpty) {
      await Future.delayed(const Duration(seconds: 3));
      queueItems = sub.state.queueItems;
    }
    info('queue items: ${queueItems.length}');
    if (queueItems.isNotEmpty) {
      final item = queueItems.first;
      final editRes = await transport.editQueueItem(
          sessionId, '${item['queueItemId']}', '排队消息测试(已编辑)');
      check('editQueueItem (CAS)', ackOk(editRes), '$editRes');
      final nowRes = await transport.sendQueuedNow(
          sessionId, '${item['queueItemId']}');
      check('sendQueuedNow (CAS)', ackOk(nowRes), '$nowRes');
    } else {
      info('未产生排队项（autoDrain 或时机原因），跳过队列操作断言');
    }
    await transport.setAutoDrain(sessionId, true);

    // 16. stop
    if (sub.state.isRunning) {
      final stopRes = await transport.stop(sessionId);
      check('stop', ackOk(stopRes), '$stopRes');
    } else {
      info('当前未运行，跳过 stop');
    }

    // 17. goal commands (CAS)
    final goalRes =
        await transport.sendGoalCommand(sessionId, '测试目标：回复简短');
    info('sendGoalCommand: $goalRes');
    final pauseRes = await transport.pauseGoal(sessionId);
    check('pauseGoal (CAS)', ackOk(pauseRes), '$pauseRes');
    final resumeRes = await transport.resumeGoal(sessionId);
    check('resumeGoal (CAS)', ackOk(resumeRes), '$resumeRes');

    // 18. compact（可能因运行中/空闲被拒，记录）
    final compactRes = await transport
        .compact(sessionId)
        .catchError((Object e) => 'ERR:$e');
    info('compact: $compactRes');

    // 19. attachment upload + send
    try {
      final attachment = await transport.attachmentPut(
        sessionId,
        fileName: 'probe-note.txt',
        mime: 'text/plain',
        bytes: Uint8List.fromList('hello from probe'.codeUnits),
      );
      check('attachmentPut', attachment['ref'] != null);
      final attSend = await transport
          .sendText(sessionId, '忽略这个附件', attachments: [attachment]);
      check('sendText(attachments)', ackOk(attSend), '$attSend');
    } catch (e) {
      check('attachmentPut', false, '$e');
    }

    // 20. rowsRange
    final older = await transport
        .rowsRange(sessionId, limit: 10)
        .catchError((Object e) => 'ERR:$e');
    check('rowsRange', older is! String || !older.startsWith('ERR'));

    // 21. sessions-index
    final six = await transport.subscribeSessionsIndex();
    await Future.delayed(const Duration(seconds: 3));
    check('sessions-index 订阅', six.state.list.isNotEmpty,
        'count=${six.state.list.length}');
    await six.dispose();

    // 22. getTaskTokenUsage
    final usage = await bridge.channels.call(
      'zcode-task',
      'getTaskTokenUsage',
      [
        {...scope, 'taskId': sessionId},
      ],
    );
    check('getTaskTokenUsage', usage is Map);

    // 23. entitlement snapshot
    final ent = await bridge.channels.call(
      'usage-stats',
      'getEntitlementSnapshot',
      [
        {'includeSubscription': true},
      ],
    );
    check('getEntitlementSnapshot', ent is Map);

    // 24. model providers
    final providers =
        await bridge.channels.call('model-provider', 'getAll', []);
    check('model-provider.getAll', providers is List,
        'count=${providers is List ? providers.length : '?'}');

    // 25. renameTask
    final renameRes = await bridge.channels.call(
      'zcode-task',
      'renameTask',
      [
        {...scope, 'taskId': sessionId, 'title': '套件测试任务'},
      ],
    );
    check('renameTask', renameRes is Map);

    // 26. pin / unpin
    await bridge.channels.call(
      'zcode-task',
      'setTaskPinned',
      [
        {...scope, 'taskId': sessionId, 'pinned': true},
      ],
    );
    check('setTaskPinned(true)', true);
    await bridge.channels.call(
      'zcode-task',
      'setTaskPinned',
      [
        {...scope, 'taskId': sessionId, 'pinned': false},
      ],
    );
    check('setTaskPinned(false)', true);

    // 27. archive / unarchive
    await bridge.channels.call(
      'zcode-task',
      'archiveTask',
      [
        {...scope, 'taskId': sessionId},
      ],
    );
    check('archiveTask', true);
    await bridge.channels.call(
      'zcode-task',
      'unarchiveTask',
      [
        {...scope, 'taskId': sessionId},
      ],
    );
    check('unarchiveTask', true);

    // 28. setTaskUnread
    await bridge.channels.call(
      'zcode-task',
      'setTaskUnread',
      [
        {...scope, 'taskId': sessionId, 'unread': false},
      ],
    );
    check('setTaskUnread', true);

    // 29. bridge recovery
    final recoveredBefore = bridge.recovered.value;
    await client.relay.debugDropSocket();
    await client.waitPaired(timeout: const Duration(seconds: 60));
    final recoverDeadline = DateTime.now().add(const Duration(seconds: 30));
    while (bridge.recovered.value == recoveredBefore &&
        DateTime.now().isBefore(recoverDeadline)) {
      await Future.delayed(const Duration(milliseconds: 300));
    }
    check('断线桥自动恢复', bridge.recovered.value > recoveredBefore,
        'degraded=${bridge.degraded.value}');
    final afterRecovery = await transport
        .sendText(sessionId, '恢复测试：只回复ok')
        .timeout(const Duration(seconds: 30));
    check('恢复后 sendText', ackOk(afterRecovery), '$afterRecovery');

    // 30. cleanup
    await sub.dispose();
    try {
      await bridge.channels.call(
        'zcode-task',
        'deleteTask',
        [
          {...scope, 'taskId': sessionId},
        ],
      );
      check('deleteTask 清理', true);
    } catch (e) {
      info('deleteTask: $e');
    }

    await client.dispose();
    // ignore: avoid_print
    print('SUITE DONE: ${results.where((r) => r.startsWith('[PASS]')).length} passed, '
        '${results.where((r) => r.startsWith('[FAIL]')).length} failed, '
        '${results.where((r) => r.startsWith('[INFO]')).length} info');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
