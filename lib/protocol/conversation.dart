import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'channel_client.dart';
import 'id.dart';
import 'zemote_client.dart';

/// Conversation V4 protocol over the `zcode-agent` channel.
const conversationProtocolAppVersion = '3.6.5';

///
/// Flow (mirrors `sk()`/`uk()` in the web client):
/// 1. `helloConversationV4()` + `initializeConversationV4(clientHello)`
/// 2. `subscribeConversationV4(scope + sessionId)` -> ack.subscriptionId
/// 3. frames pushed via dynamic event `onDynamicConversationFrame(scope)`:
///    wire frames `{wireVersion:3, kind:'complete'|'fragment', topic,
///    subscriptionId, frame | fragment*}`; complete frames carry
///    `{topic, subscriptionId, fromSeq, toSeq, sentAt, payload}` where payload
///    is `{kind:'snapshot', snapshot}` or `{kind:'deltas', deltas}`.
/// 4. commands via `sendConversationCommandV4(scope + envelope)` with
///    envelope `{commandId, clientId, sessionId, type, payload, issuedAt}`.
class ConversationTransport {
  static const channel = Channels.zcodeAgent;

  final BridgeSession session;
  final Map<String, dynamic> scope;
  final String appVersion;
  final void Function(String line)? onLog;

  final String clientId = generateUuid();
  bool _handshaken = false;
  Future<void>? _handshakeFuture;

  /// From the server hello — required for attachment uploads.
  String? connectionId;

  ConversationTransport({
    required this.session,
    required this.scope,
    // This is the desktop Conversation protocol capability version, not the
    // Zemote release version. Sending 0.x here can disable V4 capabilities
    // such as sessions-index during server negotiation.
    this.appVersion = conversationProtocolAppVersion,
    this.onLog,
  }) {
    // A reopened bridge has no handshake state — start over (mirrors the
    // web client's `wD` cache being per service instance).
    session.recovered.addListener(_onBridgeRecovered);
  }

  void _onBridgeRecovered() {
    _handshaken = false;
    _handshakeFuture = null;
    connectionId = null;
    _prep = null;
  }

  ChannelClient get _channels => session.channels;

  void _log(String line) => onLog?.call(line);

  Future<void> handshake() {
    if (_handshaken) return Future.value();
    return _handshakeFuture ??= () async {
      final hello = await _channels.call(channel, 'helloConversationV4', []);
      _log('[v4] hello: $hello');
      if (hello is Map) {
        connectionId = hello['connectionId'] as String?;
      }
      await _channels.call(channel, 'initializeConversationV4', [
        {
          'kind': 'clientHello',
          'protocolVersion': 3,
          'clientId': clientId,
          'clientKind': 'mobileApp',
          'appVersion': appVersion,
        },
      ]);
      _handshaken = true;
    }()
        .catchError((e) {
      _handshakeFuture = null;
      throw e;
    });
  }

  Future<ConversationSubscription> subscribe(String sessionId) async {
    await handshake();
    final subscription = ConversationSubscription._(this, sessionId);
    try {
      await subscription._start();
    } catch (_) {
      await subscription.dispose();
      rethrow;
    }
    _subscriptions[sessionId] = subscription;
    return subscription;
  }

  void _untrackSubscription(String sessionId) {
    _subscriptions.remove(sessionId);
  }

  /// Commands that require `baseRevision` (CAS, mirrors `eAe` in the web
  /// client) and row-target commands that also require `baseLogEpoch`
  /// (mirrors `tAe`).
  static const _casCommands = {
    'applyFileRewind',
    'forkAssistant',
    'editUserQuery',
    'retryTurn',
    'setAssistantFeedback',
    'sendQueuedNow',
    'editQueueItem',
    'reorderQueueItem',
    'deleteQueueItem',
    'setAutoDrain',
    'switchModelConfig',
    'switchCollaborationMode',
    'setFollowupMode',
    'pauseGoal',
    'resumeGoal',
  };
  static const _rowTargetCommands = {
    'applyFileRewind',
    'forkAssistant',
    'editUserQuery',
    'retryTurn',
    'setAssistantFeedback',
  };

  /// Live subscriptions by sessionId — source of the current
  /// revision/logEpoch for CAS commands.
  final _subscriptions = <String, ConversationSubscription>{};

  /// Highest revision seen from command acks (`revisionAtDecision`) —
  /// acks land before the follow-up `state.updated` frame, and the next
  /// CAS command must not go stale.
  final _ackedRevisions = <String, int>{};

  Future<dynamic> sendCommand(
    String? sessionId,
    String type,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await handshake();
    // Gate on a healthy bridge: during a relay drop/recovery the old bridge
    // is dead and requests would otherwise hang until timeout. Once the
    // bridge recovers, the send goes through on the fresh transport.
    await session.waitHealthy(timeout: const Duration(seconds: 45));
    final sub = sessionId == null ? null : _subscriptions[sessionId];
    final baseRevision = sessionId == null
        ? null
        : [
            sub?.state.revision ?? 0,
            _ackedRevisions[sessionId] ?? 0,
          ].reduce((a, b) => a > b ? a : b);
    final envelope = {
      'commandId': generateUuid(),
      'clientId': clientId,
      'sessionId': sessionId,
      if (_casCommands.contains(type)) 'baseRevision': baseRevision,
      if (_rowTargetCommands.contains(type) && sub?.state.logEpoch != null)
        'baseLogEpoch': sub!.state.logEpoch,
      'type': type,
      'payload': payload,
      'issuedAt': DateTime.now().millisecondsSinceEpoch,
    };
    _log('[v4] command $type');
    var res = await _sendCommandWithRetry(envelope, timeout);
    // Runtime events (turn completion etc.) also bump the revision, so a
    // CAS base can go stale even with ack tracking. The stale ack tells
    // the server's current revision — retry once with it (mirrors the
    // web client's stale-revision retry).
    if (sessionId != null &&
        res is Map &&
        res['status'] == 'stale' &&
        res['revisionAtDecision'] is num) {
      final serverRevision = (res['revisionAtDecision'] as num).toInt();
      _log('[v4] command $type stale, retry at rev $serverRevision');
      if (serverRevision > (_ackedRevisions[sessionId] ?? 0)) {
        _ackedRevisions[sessionId] = serverRevision;
      }
      final retryEnvelope = {
        ...envelope,
        'commandId': generateUuid(),
        'baseRevision': serverRevision,
        'issuedAt': DateTime.now().millisecondsSinceEpoch,
      };
      res = await _sendCommandWithRetry(retryEnvelope, timeout);
    }
    if (sessionId != null && res is Map && res['revisionAtDecision'] is num) {
      final rev = (res['revisionAtDecision'] as num).toInt();
      final status = res['status'];
      // revisionAtDecision is the base at decision time; an accepted
      // command bumps the revision by one, so the next CAS base is +1.
      final floor =
          (status == 'accepted' || status == 'noop' || status == 'duplicate')
              ? rev + 1
              : rev;
      if (floor > (_ackedRevisions[sessionId] ?? 0)) {
        _ackedRevisions[sessionId] = floor;
      }
    }
    return res;
  }

  /// Sends one command envelope; on timeout (likely a relay drop mid-flight)
  /// waits for bridge recovery and retries once with a fresh commandId.
  Future<dynamic> _sendCommandWithRetry(
      Map<String, dynamic> envelope, Duration timeout) async {
    try {
      return await _channels.call(
          channel,
          'sendConversationCommandV4',
          [
            {...scope, 'envelope': envelope},
          ],
          timeout: timeout);
    } on TimeoutException {
      // Retry only when the relay dropped mid-flight (bridge degraded): the
      // command then never reached the server. If the bridge is still
      // healthy, rethrow — a retry would double-deliver (e.g. sendText).
      if (session.degraded.value == null) rethrow;
      _log('[v4] command timed out during drop, waiting for recovery and '
          'retrying');
      await session.waitHealthy(timeout: const Duration(seconds: 45));
      final fresh = {
        ...envelope,
        'commandId': generateUuid(),
        'issuedAt': DateTime.now().millisecondsSinceEpoch,
      };
      return _channels.call(
          channel,
          'sendConversationCommandV4',
          [
            {...scope, 'envelope': fresh},
          ],
          timeout: timeout);
    }
  }

  /// Creates a new session (mirrors the composer's first-send path):
  /// command `createSession` with `{workspaceId, firstInput:{text}}` and a
  /// null envelope sessionId. Returns the new sessionId on `accepted`.
  Future<String> createSession(
    String workspaceId, {
    String? firstText,
    List<Map<String, dynamic>>? attachments,
    Map<String, dynamic>? config,
    String? runtimeModel,
    List<String>? mcpServers,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final res = await sendCommand(
      null,
      'createSession',
      {
        'workspaceId': workspaceId,
        if (firstText != null)
          'firstInput': {
            'text': firstText,
            if (attachments != null && attachments.isNotEmpty)
              'attachments': attachments,
          },
        if (config != null) 'config': config,
        if (runtimeModel != null) 'runtimeModel': runtimeModel,
        if (mcpServers != null && mcpServers.isNotEmpty)
          'mcpServers': mcpServers,
      },
      timeout: timeout,
    );
    final map = res is Map ? res.cast<String, dynamic>() : null;
    final status = map?['status'];
    if (status != 'accepted') {
      throw StateError(
          'createSession rejected: ${map?['reasonCode'] ?? status} ${map?['message'] ?? ''}');
    }
    final result = map?['result'];
    final sessionId = result is Map ? result['sessionId'] : null;
    if (sessionId is! String || sessionId.isEmpty) {
      throw StateError('createSession: missing sessionId in result');
    }
    return sessionId;
  }

  /// Creates a selection-side (auxiliary) chat attached to [parentSessionId]
  /// (command `createSelectionSideSession` with an empty payload, mirrors
  /// the web client's "ask in side chat" flow). Returns the new sessionId.
  Future<String> createSelectionSideSession(
    String parentSessionId, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final res = await sendCommand(
      parentSessionId,
      'createSelectionSideSession',
      {},
      timeout: timeout,
    );
    final map = res is Map ? res.cast<String, dynamic>() : null;
    final status = map?['status'];
    if (status != 'accepted' && status != 'duplicate') {
      throw StateError(
          'createSelectionSideSession rejected: ${map?['reasonCode'] ?? status} ${map?['message'] ?? ''}');
    }
    final result = map?['result'];
    final sessionId = result is Map ? result['sessionId'] : null;
    if (sessionId is! String || sessionId.isEmpty) {
      throw StateError(
          'createSelectionSideSession: missing sessionId in result');
    }
    return sessionId;
  }

  Future<dynamic> sendText(
    String sessionId,
    String text, {
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
    String? automationId,
    String? offPeakTaskId,
    String? offPeakRunType,
    String? botDeliveryTarget,
    List<String>? toolDisallowlist,
  }) =>
      sendCommand(sessionId, 'sendText', {
        'text': text,
        if (attachments != null && attachments.isNotEmpty)
          'attachments': attachments,
        if (heldQueueDisposition != null)
          'heldQueueDisposition': heldQueueDisposition,
        if (expectedHeldQueueItemIds != null &&
            expectedHeldQueueItemIds.isNotEmpty)
          'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
        if (automationId != null) 'automationId': automationId,
        if (offPeakTaskId != null) 'offPeakTaskId': offPeakTaskId,
        if (offPeakRunType != null) 'offPeakRunType': offPeakRunType,
        if (botDeliveryTarget != null) 'botDeliveryTarget': botDeliveryTarget,
        if (toolDisallowlist != null && toolDisallowlist.isNotEmpty)
          'toolDisallowlist': toolDisallowlist,
      });

  Future<dynamic> sendGoalCommand(
    String sessionId,
    String text, {
    String? displayText,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
  }) =>
      sendCommand(sessionId, 'sendGoalCommand', {
        'text': text,
        if (displayText != null) 'displayText': displayText,
        if (heldQueueDisposition != null)
          'heldQueueDisposition': heldQueueDisposition,
        if (expectedHeldQueueItemIds != null &&
            expectedHeldQueueItemIds.isNotEmpty)
          'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
      });

  Future<dynamic> pauseGoal(String sessionId) =>
      sendCommand(sessionId, 'pauseGoal', {});

  Future<dynamic> resumeGoal(String sessionId) =>
      sendCommand(sessionId, 'resumeGoal', {});

  Future<dynamic> stop(String sessionId) => sendCommand(sessionId, 'stop', {});

  Future<dynamic> compact(String sessionId) =>
      sendCommand(sessionId, 'compact', {});

  /// Switch model config. All of provider/model/thought are required by the
  /// protocol schema — pass current values for the ones not changing.
  /// Thought levels differ per model family (GLM-5.2: max/high/nothink;
  /// Turbo: enabled/off), so on `Unsupported reasoning effort` we retry
  /// with the other family's default.
  Future<dynamic> switchModelConfig(
    String sessionId, {
    required String provider,
    required String model,
    required String thought,
  }) async {
    var res = await sendCommand(sessionId, 'switchModelConfig', {
      'provider': provider,
      'model': model,
      'thought': thought,
    });
    final message = res is Map ? '${res['message'] ?? ''}' : '';
    if (message.contains('Unsupported reasoning effort')) {
      final fallback =
          (thought == 'enabled' || thought == 'off') ? 'max' : 'enabled';
      _log('[v4] switchModelConfig retry with thought=$fallback');
      res = await sendCommand(sessionId, 'switchModelConfig', {
        'provider': provider,
        'model': model,
        'thought': fallback,
      });
    }
    return res;
  }

  /// build / edit / plan / yolo. Mirrors `switchCollaborationMode`.
  Future<dynamic> switchCollaborationMode(String sessionId, String mode) =>
      sendCommand(sessionId, 'switchCollaborationMode', {'mode': mode});

  /// queue / guide followup. Mirrors `setFollowupMode`.
  Future<dynamic> setFollowupMode(String sessionId, String mode) =>
      sendCommand(sessionId, 'setFollowupMode', {'mode': mode});

  /// like / dislike / null on an assistant row. Target is
  /// `{rowId, entityId}` (entityId optional for some row kinds).
  Future<dynamic> setAssistantFeedback(
    String sessionId,
    Map<String, dynamic> target,
    String? feedback,
  ) =>
      sendCommand(sessionId, 'setAssistantFeedback', {
        'target': target,
        'feedback': feedback,
      });

  Future<dynamic> retryTurn(String sessionId, Map<String, dynamic> target) =>
      sendCommand(sessionId, 'retryTurn', {'target': target});

  Future<dynamic> sendQueuedNow(String sessionId, String queueItemId) =>
      sendCommand(sessionId, 'sendQueuedNow', {'queueItemId': queueItemId});

  Future<dynamic> editQueueItem(
          String sessionId, String queueItemId, String newText) =>
      sendCommand(sessionId, 'editQueueItem',
          {'queueItemId': queueItemId, 'newText': newText});

  Future<dynamic> deleteQueueItem(String sessionId, String queueItemId) =>
      sendCommand(sessionId, 'deleteQueueItem', {'queueItemId': queueItemId});

  Future<dynamic> setAutoDrain(String sessionId, bool autoDrain) =>
      sendCommand(sessionId, 'setAutoDrain', {'autoDrain': autoDrain});

  Future<dynamic> forkAssistant(
          String sessionId, Map<String, dynamic> target) =>
      sendCommand(sessionId, 'forkAssistant', {'target': target});

  Future<dynamic> editUserQuery(
    String sessionId,
    Map<String, dynamic> target,
    String newText,
  ) =>
      sendCommand(
          sessionId, 'editUserQuery', {'target': target, 'newText': newText});

  Future<dynamic> applyFileRewind(
          String sessionId, Map<String, dynamic> target) =>
      sendCommand(sessionId, 'applyFileRewind', {'target': target});

  Future<dynamic> plans(String sessionId) async {
    await handshake();
    return _channels.call(channel, 'conversationPlansV4', [
      {...scope, 'sessionId': sessionId},
    ]);
  }

  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
    int? baseRevision,
    String? baseLogEpoch,
  }) async {
    await handshake();
    return _channels.call(channel, 'conversationFileChangesV4', [
      {
        ...scope,
        'sessionId': sessionId,
        'target': target,
        if (baseRevision != null) 'baseRevision': baseRevision,
        if (baseLogEpoch != null) 'baseLogEpoch': baseLogEpoch,
      },
    ]);
  }

  Future<dynamic> fileRewindPreview(
    String sessionId, {
    required Map<String, dynamic> target,
    int? baseRevision,
    String? baseLogEpoch,
  }) async {
    await handshake();
    return _channels.call(channel, 'conversationFileRewindPreviewV4', [
      {
        ...scope,
        'sessionId': sessionId,
        'target': target,
        if (baseRevision != null) 'baseRevision': baseRevision,
        if (baseLogEpoch != null) 'baseLogEpoch': baseLogEpoch,
      },
    ]);
  }

  // ------------------------------------------------------------ attachments

  static const _attachmentChunkBytes = 384 * 1024;

  /// Uploads an attachment (begin/chunk/commit, mirrors `rNe()`).
  /// Returns the attachment descriptor `{ref, fileName, mime, bytes}` to be
  /// passed to sendText/createSession.
  Future<Map<String, dynamic>> attachmentPut(
    String sessionId, {
    required String fileName,
    required String mime,
    required Uint8List bytes,
    void Function(double progress)? onProgress,
  }) async {
    await handshake();
    final connId = connectionId;
    if (connId == null) {
      throw StateError('attachmentPut: missing connectionId');
    }
    final uploadId = 'upload-${generateUuid()}';
    final base = {
      'connectionId': connId,
      'uploadId': uploadId,
      'sessionId': sessionId,
    };
    final totalChunks =
        (bytes.length + _attachmentChunkBytes - 1) ~/ _attachmentChunkBytes;
    final checksum = 'sha256:${sha256.convert(bytes).toString()}';

    final beginRes = await _channels.call(channel, 'attachmentBeginV4', [
      {
        ...scope,
        ...base,
        'fileName': fileName,
        'mime': mime,
        'totalBytes': bytes.length,
        'totalChunks': totalChunks,
        'checksum': checksum,
      },
    ]);
    if (beginRes is Map && beginRes['state'] == 'committed') {
      onProgress?.call(1);
      return {
        'ref': beginRes['ref'],
        'fileName': fileName,
        'mime': mime,
        'bytes': bytes.length,
      };
    }
    var nextChunk = beginRes is Map
        ? (beginRes['nextChunkIndex'] as num?)?.toInt() ?? 0
        : 0;
    for (var n = nextChunk; n < totalChunks; n++) {
      final start = n * _attachmentChunkBytes;
      final end = start + _attachmentChunkBytes > bytes.length
          ? bytes.length
          : start + _attachmentChunkBytes;
      final chunkRes = await _channels.call(channel, 'attachmentChunkV4', [
        {
          ...scope,
          ...base,
          'chunkIndex': n,
          'dataBase64': base64.encode(Uint8List.sublistView(bytes, start, end)),
        },
      ]);
      nextChunk = chunkRes is Map
          ? (chunkRes['nextChunkIndex'] as num?)?.toInt() ?? n + 1
          : n + 1;
      if (nextChunk != n + 1) {
        throw StateError('fault.attachment.invalidServerProgress');
      }
      onProgress?.call(nextChunk / totalChunks);
    }
    onProgress?.call(1);
    final commitRes = await _channels.call(channel, 'attachmentCommitV4', [
      {...scope, ...base},
    ]);
    final ref = commitRes is Map ? commitRes['ref'] : null;
    return {
      'ref': ref,
      'fileName': fileName,
      'mime': mime,
      'bytes': bytes.length,
    };
  }

  /// Reads an attachment (for previews). Returns `{bytes, mediaType}`.
  Future<({Uint8List bytes, String? mediaType})> attachmentRead(
    String sessionId, {
    required String ref,
  }) async {
    await handshake();
    final chunks = <int>[];
    var offset = 0;
    String? mediaType;
    for (var round = 0; round < 1024; round++) {
      final res = await _channels.call(channel, 'attachmentReadV4', [
        {
          ...scope,
          'sessionId': sessionId,
          'ref': ref,
          'offset': offset,
          'limit': _attachmentChunkBytes,
        },
      ]);
      if (res is! Map) break;
      mediaType ??= res['mediaType'] as String?;
      final data = res['dataBase64'] as String?;
      if (data != null && data.isNotEmpty) {
        chunks.addAll(base64.decode(data));
      }
      final next = (res['nextOffset'] as num?)?.toInt();
      final total = (res['totalBytes'] as num?)?.toInt();
      if (next == null || next <= offset) break;
      offset = next;
      if (total != null && offset >= total) break;
    }
    return (bytes: Uint8List.fromList(chunks), mediaType: mediaType);
  }

  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) =>
      sendCommand(sessionId, 'resolveInteraction', {
        'interactionId': interactionId,
        'answer': {
          if (optionId != null) 'optionId': optionId,
          if (freeText != null) 'freeText': freeText,
          if (action != null) 'action': action,
          if (content != null) 'content': content,
        },
      });

  Future<dynamic> rowsRange(
    String sessionId, {
    int? beforeRowId,
    int limit = 60,
  }) async {
    await handshake();
    return _channels.call(channel, 'conversationRowsRangeV4', [
      {
        ...scope,
        'sessionId': sessionId,
        if (beforeRowId != null) 'beforeRowId': beforeRowId,
        'limit': limit,
      },
    ]);
  }

  // ------------------------------------------------------ sessions-index

  /// Subscribes the sessions-index of this workspace
  /// (`subscribeSessionsIndexV4` + `onDynamicSessionsIndexFrame`).
  /// Provides the live session list with title/phase/lastAssistantPreview.
  Future<SessionsIndexSubscription> subscribeSessionsIndex() async {
    await handshake();
    final subscription = SessionsIndexSubscription._(this);
    try {
      await subscription._start();
    } catch (_) {
      await subscription.dispose();
      rethrow;
    }
    return subscription;
  }

  // ---------------------------------------------------- workspace config

  WorkspacePrep? _prep;

  /// `zcode-task.prepareWorkspace` — returns configOptions (model/mode/
  /// thought selects) and slashCommands (builtin + custom skills/MCP).
  Future<WorkspacePrep> prepareWorkspace({bool refresh = false}) async {
    final cached = _prep;
    if (cached != null && !refresh) return cached;
    final res = await _channels.call(
      Channels.zcodeTask,
      'prepareWorkspace',
      [scope],
    );
    final prep = WorkspacePrep._(res is Map ? res : const {});
    _prep = prep;
    return prep;
  }

  /// `skills.list` — enabled skills of this workspace (mirrors the web
  /// client's `skillsService.list`). Skills are invoked in the composer as
  /// `$name`. Returns an empty list when the channel rejects or returns no
  /// skill data.
  Future<List<SkillEntry>> skills() async {
    final res = await _channels.call(
      Channels.skills,
      'list',
      [
        {
          'workspacePath': scope['workspacePath'],
          if (scope['workspaceIdentity'] != null)
            'workspaceIdentity': scope['workspaceIdentity'],
          'provider': 'glm',
        },
      ],
      timeout: const Duration(seconds: 20),
    );
    final raw = res is List ? res : (res is Map ? res['skills'] : null);
    if (raw is! List) return const [];
    return [
      for (final item in raw.whereType<Map>())
        SkillEntry._(item.cast<String, dynamic>()),
    ].where((s) => s.name.isNotEmpty).toList();
  }
}

/// Shared base for Conversation/SessionsIndex subscriptions.
/// Extracts the common wire-frame staging, fragment reassembly, bridge
/// recovery, and resubscribe retry logic.
abstract class _SubscriptionBase<T extends ChangeNotifier> {
  final ConversationTransport _transport;
  final String _logTag;

  final T state;

  String? _subscriptionId;
  String? get subscriptionId => _subscriptionId;
  void Function()? _cancelFrameListener;
  bool _disposed = false;
  bool _resyncing = false;
  Timer? _resubscribeTimer;

  final _stagedFrames = <Map<String, dynamic>>[];
  final _fragments = <String, _LogicalFrameAssembly>{};
  Timer? _fragmentCleanup;

  _SubscriptionBase(this._transport, this.state, this._logTag) {
    _transport.session.recovered.addListener(_onBridgeRecovered);
    _fragmentCleanup =
        Timer.periodic(const Duration(seconds: 30), (_) => _purgeFragments());
  }

  // --- abstract: subclasses define channel/protocol specifics

  /// Frame event name (e.g. `onDynamicConversationFrame`).
  String get _frameEventName;

  /// Subscribe method name (e.g. `subscribeConversationV4`).
  String get _subscribeMethod;

  /// Unsubscribe method name (e.g. `unsubscribeConversationV4`).
  String get _unsubscribeMethod;

  /// Resync method name (e.g. `resyncConversationV4`).
  String get _resyncMethod;

  /// Extra subscribe request args (merged with scope).
  Map<String, dynamic> get _subscribeArgs;

  /// Extra unsubscribe request args.
  Map<String, dynamic> get _unsubscribeArgs;

  /// Extra resync request args.
  Map<String, dynamic> get _resyncArgs;

  /// Topic for wire-frame routing.
  String get topic;

  /// Process a logical frame against [state].
  void _acceptLogicalFrame(Map<String, dynamic> frame);

  /// Called with the subscribe ack map — hook for state-specific processing.
  void _onSubscribeAck(Map<String, dynamic> ack) {}

  /// Called after a successful _start() — hook for post-start logic.
  void _onStarted() {}

  /// Called during resubscribe cleanup before re-connect.
  void _onResubscribeCleanup() {}

  /// Called during dispose — extra cleanup.
  Future<void> _onDispose() async {}

  int get _resyncSeq => 0;
  String? get _resyncEpoch => null;

  void _purgeFragments() {
    if (_disposed) return;
    final stale = <String>[];
    final now = DateTime.now();
    _fragments.forEach((id, a) {
      if (now.difference(a.createdAt).inSeconds > 60) stale.add(id);
    });
    for (final id in stale) {
      _fragments.remove(id);
      _transport._log('[$_logTag] purged stale fragment $id');
    }
  }

  Future<void> _start() async {
    try {
      await _transport.handshake();
      _cancelFrameListener = _transport._channels.addEventListener(
        ConversationTransport.channel,
        _frameEventName,
        _handleWireFrame,
        arg: _transport.scope,
      );
      final res = await _transport._channels.call(
        ConversationTransport.channel,
        _subscribeMethod,
        [
          {..._transport.scope, ..._subscribeArgs}
        ],
        // The desktop may need to warm the session runtime before answering —
        // give the subscribe call generous room instead of timing out at the
        // 30s channel default.
        timeout: const Duration(seconds: 60),
      );
      final ack = (res as Map?)?['ack'] as Map?;
      _subscriptionId = ack?['subscriptionId'] as String?;
      _transport._log('[$_logTag] subscribed $topic id=$_subscriptionId');
      if (_subscriptionId == null) {
        throw StateError('$_subscribeMethod: missing ack.subscriptionId');
      }
      _onSubscribeAck(ack?.cast<String, dynamic>() ?? const {});
      final staged = List<Map<String, dynamic>>.from(_stagedFrames);
      _stagedFrames.clear();
      for (final frame in staged) {
        _acceptLogicalFrame(frame);
      }
      _onStarted();
    } catch (_) {
      _cancelFrameListener?.call();
      _cancelFrameListener = null;
      _subscriptionId = null;
      _stagedFrames.clear();
      _fragments.clear();
      rethrow;
    }
  }

  void _onBridgeRecovered() {
    if (_disposed) return;
    _transport._log('[$_logTag] bridge recovered, resubscribing $topic');
    _resubscribe();
  }

  Future<void> _resubscribe() async {
    await _transport.handshake();
    _onResubscribeCleanup();
    _cancelFrameListener?.call();
    _cancelFrameListener = null;
    final oldId = _subscriptionId;
    _subscriptionId = null;
    _stagedFrames.clear();
    _fragments.clear();
    if (oldId != null) {
      try {
        await _transport._channels.call(
          ConversationTransport.channel,
          _unsubscribeMethod,
          [
            {..._transport.scope, 'subscriptionId': oldId, ..._unsubscribeArgs}
          ],
        );
      } catch (_) {}
    }
    try {
      await _start();
    } catch (e) {
      _transport._log('[$_logTag] resubscribe failed: $e');
      _resubscribeTimer?.cancel();
      _resubscribeTimer = Timer(const Duration(seconds: 3), () {
        if (!_disposed && _subscriptionId == null) _resubscribe();
      });
    }
  }

  void _handleWireFrame(dynamic data) {
    if (_disposed || data is! Map) return;
    final frame = data.cast<String, dynamic>();
    if (frame['topic'] != topic) return;
    switch (frame['kind']) {
      case 'complete':
        final inner = frame['frame'];
        if (inner is Map) {
          _acceptOrStage(inner.cast<String, dynamic>());
        }
        break;
      case 'fragment':
        _acceptFragment(frame);
        break;
    }
  }

  void _acceptOrStage(Map<String, dynamic> frame) {
    if (_subscriptionId == null) {
      _stagedFrames.add(frame);
      return;
    }
    _acceptLogicalFrame(frame);
  }

  void _acceptFragment(Map<String, dynamic> frame) {
    final id = frame['logicalFrameId'] as String?;
    final index = (frame['fragmentIndex'] as num?)?.toInt();
    final count = (frame['fragmentCount'] as num?)?.toInt();
    final dataBase64 = frame['dataBase64'] as String?;
    if (id == null || index == null || count == null || dataBase64 == null) {
      return;
    }
    if (count < 1 || count > 64 || index < 0 || index >= count) return;
    final assembly =
        _fragments.putIfAbsent(id, () => _LogicalFrameAssembly(count));
    if (assembly.count != count) {
      _fragments.remove(id);
      return;
    }
    try {
      assembly.add(index, base64.decode(dataBase64));
    } catch (e) {
      _fragments.remove(id);
      _transport._log('[$_logTag] bad fragment: $e');
      return;
    }
    if (assembly.isComplete) {
      _fragments.remove(id);
      try {
        final decoded = jsonDecode(utf8.decode(assembly.assemble()));
        if (decoded is Map) {
          _acceptOrStage(decoded.cast<String, dynamic>());
        }
      } catch (e) {
        _transport._log('[$_logTag] bad logical frame: $e');
      }
    }
  }

  Future<void> _resync() async {
    final id = _subscriptionId;
    if (id == null || _disposed || _resyncing) return;
    _resyncing = true;
    _transport._log(
        '[$_logTag] resync (gap detected) seq=$_resyncSeq logEpoch=$_resyncEpoch');
    try {
      await _transport._channels.call(
        ConversationTransport.channel,
        _resyncMethod,
        [
          {
            ..._transport.scope,
            'subscriptionId': id,
            ..._resyncArgs,
            if (_resyncEpoch != null)
              'base': {'logEpoch': _resyncEpoch, 'seq': _resyncSeq},
          },
        ],
      );
    } catch (e) {
      _transport._log('[$_logTag] resync failed: $e');
    } finally {
      _resyncing = false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _resubscribeTimer?.cancel();
    _fragmentCleanup?.cancel();
    await _onDispose();
    _transport.session.recovered.removeListener(_onBridgeRecovered);
    _cancelFrameListener?.call();
    final id = _subscriptionId;
    if (id != null) {
      try {
        await _transport._channels.call(
          ConversationTransport.channel,
          _unsubscribeMethod,
          [
            {..._transport.scope, 'subscriptionId': id, ..._unsubscribeArgs},
          ],
        );
      } catch (_) {}
    }
    _fragments.clear();
  }
}

class ConversationSubscription extends _SubscriptionBase<ConversationState> {
  final String sessionId;

  DateTime _lastFrameAt = DateTime.now();
  Timer? _watchdog;

  ConversationSubscription._(ConversationTransport transport, this.sessionId)
      : super(transport, ConversationState(), 'v4');

  @override
  String get _frameEventName => 'onDynamicConversationFrame';
  @override
  String get _subscribeMethod => 'subscribeConversationV4';
  @override
  String get _unsubscribeMethod => 'unsubscribeConversationV4';
  @override
  String get _resyncMethod => 'resyncConversationV4';
  @override
  Map<String, dynamic> get _subscribeArgs => {'sessionId': sessionId};
  @override
  Map<String, dynamic> get _unsubscribeArgs => const {};
  @override
  Map<String, dynamic> get _resyncArgs => const {'forceSnapshot': true};
  @override
  String get topic => 'conversation/$sessionId';
  @override
  int get _resyncSeq => state.seq;
  @override
  String? get _resyncEpoch => state.logEpoch;

  @override
  void _onSubscribeAck(Map<String, dynamic> ack) {
    if (ack['logEpoch'] is String) {
      state.logEpoch = ack['logEpoch'] as String;
    }
  }

  @override
  void _onStarted() {
    _startWatchdog();
  }

  @override
  void _onResubscribeCleanup() {
    _watchdog?.cancel();
  }

  @override
  Future<void> _onDispose() async {
    _watchdog?.cancel();
    _transport._untrackSubscription(sessionId);
    state.dispose();
  }

  @override
  void _acceptLogicalFrame(Map<String, dynamic> frame) {
    final subId = subscriptionId;
    if (subId == null || frame['subscriptionId'] != subId) return;
    _lastFrameAt = DateTime.now();
    state.applyFrame(frame, onGap: _resync);
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 10), (_) {
      if (_disposed) return;
      final quietSeconds = DateTime.now().difference(_lastFrameAt).inSeconds;
      if (quietSeconds < 20) return;
      final streaming = state.rows.any((r) => r['state'] == 'streaming');
      if (state.isRunning || streaming) {
        _transport._log(
            '[v4] watchdog: no frames for ${quietSeconds}s while active, resync');
        _resync();
      }
    });
  }
}

class WorkspacePrep {
  final List<ConfigOption> configOptions;
  final List<SlashCommand> slashCommands;
  final Map raw;

  WorkspacePrep._(this.raw)
      : configOptions = [
          if (raw['configOptions'] is List)
            for (final o in raw['configOptions'] as List)
              if (o is Map) ConfigOption._(o),
        ],
        slashCommands = [
          if (raw['slashCommands'] is List)
            for (final c in raw['slashCommands'] as List)
              if (c is Map) SlashCommand._(c),
        ];

  ConfigOption? option(String id) {
    for (final o in configOptions) {
      if (o.id == id) return o;
    }
    return null;
  }
}

/// A desktop skill (`skills.list`), triggered in the composer as `$name`.
class SkillEntry {
  final String id;
  final String name;
  final String path;
  final String scope;
  final String? description;
  final String? argumentHint;
  final bool enabled;

  SkillEntry._(Map raw)
      : id = '${raw['id'] ?? ''}',
        name = '${raw['name'] ?? ''}',
        path = '${raw['path'] ?? ''}',
        scope = '${raw['scope'] ?? 'workspace'}',
        description = raw['description'] as String?,
        argumentHint = raw['argumentHint'] as String?,
        enabled = raw['enabled'] != false;
}

class ConfigOption {
  final String id;
  final String name;
  final String category;
  final String type;
  final Object? currentValue;
  final List<ConfigOptionValue> options;

  ConfigOption._(Map raw)
      : id = '${raw['id'] ?? ''}',
        name = '${raw['name'] ?? ''}',
        category = '${raw['category'] ?? ''}',
        type = '${raw['type'] ?? ''}',
        currentValue = raw['currentValue'],
        options = [
          if (raw['options'] is List)
            for (final v in raw['options'] as List)
              if (v is Map) ConfigOptionValue._(v),
        ];
}

class ConfigOptionValue {
  final String value;
  final String name;
  final String? description;
  final String? modelProviderName;

  ConfigOptionValue._(Map raw)
      : value = '${raw['value'] ?? ''}',
        name = '${raw['name'] ?? raw['value'] ?? ''}',
        description = raw['description'] as String?,
        modelProviderName = raw['modelProviderName'] as String?;
}

class SlashCommand {
  final String name;
  final String description;
  final String? inputHint;
  final String source;

  SlashCommand._(Map raw)
      : name = '${raw['name'] ?? ''}',
        description = '${raw['description'] ?? ''}',
        inputHint = raw['inputHint'] as String?,
        source = '${raw['source'] ?? ''}';
}

class _LogicalFrameAssembly {
  final int count;
  final List<Uint8List?> parts;
  final DateTime createdAt = DateTime.now();
  int received = 0;

  _LogicalFrameAssembly(this.count) : parts = List.filled(count, null);

  void add(int index, Uint8List data) {
    if (index < 0 || index >= count) return;
    if (parts[index] == null) received += 1;
    parts[index] = data;
  }

  bool get isComplete => received == count;

  Uint8List assemble() {
    final builder = BytesBuilder();
    for (final p in parts) {
      if (p != null) builder.add(p);
    }
    return builder.toBytes();
  }
}

/// Live sessions-index state (task list of a workspace), mirrors the
/// sessions-index subscription in the web client (`QAe` delta application).
class SessionEntry {
  final String sessionId;
  final String? parentSessionId;
  final String title;
  final String phase;
  final String? lastAssistantPreview;
  final int lastActivityAt;
  final int createdAt;
  final bool hasBackgroundWork;
  final Map<String, dynamic>? pendingInteraction;
  final Map<String, dynamic> raw;

  SessionEntry(this.raw)
      : sessionId = '${raw['sessionId'] ?? ''}',
        parentSessionId = raw['parentSessionId'] as String?,
        title = '${raw['title'] ?? ''}',
        phase = '${raw['phase'] ?? ''}',
        lastAssistantPreview = raw['lastAssistantPreview'] as String?,
        lastActivityAt = (raw['lastActivityAt'] as num?)?.toInt() ?? 0,
        createdAt = (raw['createdAt'] as num?)?.toInt() ?? 0,
        hasBackgroundWork = raw['hasBackgroundWork'] == true,
        pendingInteraction =
            (raw['pendingInteraction'] as Map?)?.cast<String, dynamic>();
}

class SessionsIndexState extends ChangeNotifier {
  String? workspaceId;
  String? logEpoch;
  int seq = 0;
  final Map<String, SessionEntry> sessions = {};
  bool ready = false;

  List<SessionEntry> get list {
    final values = sessions.values.toList()
      ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    return values;
  }

  void applyFrame(Map<String, dynamic> frame,
      {required void Function() onGap}) {
    final payload = frame['payload'];
    if (payload is! Map) return;
    final toSeq = (frame['toSeq'] as num?)?.toInt() ?? seq;

    if (payload['kind'] == 'snapshot') {
      final snap = (payload['snapshot'] as Map).cast<String, dynamic>();
      workspaceId = snap['workspaceId'] as String?;
      logEpoch = snap['logEpoch'] as String?;
      sessions.clear();
      final list = snap['sessions'];
      if (list is List) {
        for (final s in list) {
          if (s is Map) {
            final entry = SessionEntry(s.cast<String, dynamic>());
            sessions[entry.sessionId] = entry;
          }
        }
      }
      seq = toSeq;
    } else if (payload['kind'] == 'deltas') {
      final fromSeq = (frame['fromSeq'] as num?)?.toInt() ?? seq;
      if (fromSeq != seq) {
        onGap();
        return;
      }
      final deltas = payload['deltas'];
      if (deltas is List) {
        for (final d in deltas) {
          if (d is! Map) continue;
          if (d['op'] == 'session.upserted' && d['session'] is Map) {
            final entry =
                SessionEntry((d['session'] as Map).cast<String, dynamic>());
            sessions[entry.sessionId] = entry;
          } else if (d['op'] == 'session.removed') {
            sessions.remove('${d['sessionId']}');
          }
        }
      }
      seq = toSeq;
    }
    ready = true;
    notifyListeners();
  }
}

class SessionsIndexSubscription extends _SubscriptionBase<SessionsIndexState> {
  SessionsIndexSubscription._(ConversationTransport transport)
      : super(transport, SessionsIndexState(), 'v4-si');

  @override
  String get _frameEventName => 'onDynamicSessionsIndexFrame';
  @override
  String get _subscribeMethod => 'subscribeSessionsIndexV4';
  @override
  String get _unsubscribeMethod => 'unsubscribeSessionsIndexV4';
  @override
  String get _resyncMethod => 'resyncSessionsIndexV4';
  @override
  Map<String, dynamic> get _subscribeArgs =>
      const {'runtimePolicy': 'existing-only'};
  @override
  Map<String, dynamic> get _unsubscribeArgs =>
      const {'runtimePolicy': 'existing-only'};
  @override
  Map<String, dynamic> get _resyncArgs =>
      const {'runtimePolicy': 'existing-only'};
  @override
  String get topic =>
      'sessions-index/${_transport.scope['workspaceIdentity'] ?? _transport.scope['workspacePath']}';
  @override
  int get _resyncSeq => state.seq;
  @override
  String? get _resyncEpoch => state.logEpoch;

  @override
  Future<void> _onDispose() async {
    state.dispose();
  }

  @override
  void _acceptLogicalFrame(Map<String, dynamic> frame) {
    final subId = subscriptionId;
    if (subId == null || frame['subscriptionId'] != subId) return;
    state.applyFrame(frame, onGap: _resync);
  }
}

/// Conversation snapshot + row state, mirrors `fke()`/`pke()` delta
/// application in the web client.
class ConversationState extends ChangeNotifier {
  Map<String, dynamic>? snapshot;
  List<Map<String, dynamic>> rows = [];
  int seq = 0;
  String? logEpoch;
  int? firstRowId;
  int totalCount = 0;
  bool ready = false;
  bool historyExhausted = false;

  void applyFrame(
    Map<String, dynamic> frame, {
    required void Function() onGap,
  }) {
    final payload = frame['payload'];
    if (payload is! Map) return;
    final toSeq = (frame['toSeq'] as num?)?.toInt() ?? seq;

    if (payload['kind'] == 'snapshot') {
      final snap = (payload['snapshot'] as Map).cast<String, dynamic>();
      _applySnapshot(snap, toSeq);
    } else if (payload['kind'] == 'deltas') {
      final fromSeq = (frame['fromSeq'] as num?)?.toInt() ?? seq;
      if (fromSeq != seq) {
        onGap();
        return;
      }
      final deltas = payload['deltas'];
      if (deltas is List) {
        for (final d in deltas) {
          if (d is Map) _applyDelta(d.cast<String, dynamic>());
        }
      }
      seq = toSeq;
    }
    ready = true;
    notifyListeners();
  }

  void _applySnapshot(Map<String, dynamic> snap, int toSeq) {
    snapshot = snap;
    if (_pendingPatch != null) {
      snapshot = {...snap, ..._pendingPatch!};
      _pendingPatch = null;
    }
    seq = toSeq;
    logEpoch = snap['logEpoch'] as String?;
    final rowsObj = snap['rows'];
    if (rowsObj is Map) {
      final window = rowsObj['window'];
      if (window is List) {
        final windowRows = window
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        final head = windowRows.isEmpty
            ? null
            : (windowRows.first['rowId'] as num?)?.toInt();
        final older = head == null
            ? <Map<String, dynamic>>[]
            : rows.where((r) {
                final id = (r['rowId'] as num?)?.toInt();
                return id != null && id < head;
              }).toList();
        rows = [...older, ...windowRows];
      } else {
        rows = [];
      }
      totalCount = (rowsObj['totalCount'] as num?)?.toInt() ?? rows.length;
      firstRowId = (rowsObj['firstRowId'] as num?)?.toInt();
    } else {
      rows = [];
      totalCount = 0;
      firstRowId = null;
    }
  }

  void _applyDelta(Map<String, dynamic> delta) {
    switch (delta['op']) {
      case 'row.appended':
        final row = (delta['row'] as Map).cast<String, dynamic>();
        rows.add(row);
        totalCount += 1;
        firstRowId ??= (row['rowId'] as num?)?.toInt();
        break;
      case 'row.upserted':
        final row = (delta['row'] as Map).cast<String, dynamic>();
        final id = (row['rowId'] as num?)?.toInt();
        final index =
            rows.indexWhere((r) => (r['rowId'] as num?)?.toInt() == id);
        if (index != -1) rows[index] = row;
        break;
      case 'row.removed':
        // Mirrors `fke()` in the web client: KEEP rows with
        // rowId < fromRowId (i.e. remove rows >= fromRowId).
        final fromRowId = (delta['fromRowId'] as num?)?.toInt() ?? 0;
        final kept = rows
            .where((r) => ((r['rowId'] as num?)?.toInt() ?? 0) < fromRowId)
            .toList();
        final removed = rows.length - kept.length;
        rows = kept;
        if (firstRowId != null && fromRowId <= firstRowId!) {
          totalCount = 0;
          firstRowId = null;
        } else {
          totalCount = (totalCount - removed).clamp(0, 1 << 31);
        }
        break;
      case 'row.delta':
        final rowId = (delta['rowId'] as num?)?.toInt();
        final path = delta['path'] as String?;
        final append = delta['append'] as String? ?? '';
        final index =
            rows.indexWhere((r) => (r['rowId'] as num?)?.toInt() == rowId);
        if (index != -1) {
          rows[index] = _appendToRow(rows[index], path, append);
        }
        break;
      case 'state.updated':
        final patch = delta['patch'];
        if (patch is Map) {
          if (snapshot != null) {
            snapshot = {...snapshot!, ...patch.cast<String, dynamic>()};
          } else {
            // Patch arrived before the initial snapshot — buffer and
            // merge when the snapshot lands (otherwise config/queue/
            // control updates are silently lost).
            _pendingPatch = {
              ...?_pendingPatch,
              ...patch.cast<String, dynamic>(),
            };
          }
        }
        break;
    }
  }

  Map<String, dynamic>? _pendingPatch;

  /// Optimistic local update (command already accepted; the confirming
  /// `state.updated` frame may lag). Merges into snapshot immediately.
  void optimisticPatch(Map<String, dynamic> patch) {
    if (snapshot == null) return;
    snapshot = {...snapshot!, ...patch};
    notifyListeners();
  }

  /// Optimistic row edit (e.g. feedback) — mutates the row in place and
  /// notifies; the server row.upserted will confirm.
  void optimisticRowUpdate(num? rowId, Map<String, dynamic> patch) {
    final index =
        rows.indexWhere((r) => (r['rowId'] as num?)?.toInt() == rowId?.toInt());
    if (index == -1) return;
    rows[index] = {...rows[index], ...patch};
    notifyListeners();
  }

  /// Optimistic queue removal (sendQueuedNow / deleteQueueItem accepted).
  void optimisticRemoveQueueItem(String queueItemId) {
    final q = queue;
    if (q == null) return;
    final items = (q['items'] as List?)
        ?.where((i) => i is Map && '${i['queueItemId']}' != queueItemId)
        .toList();
    snapshot = {
      ...snapshot!,
      'queue': {...q, 'items': items ?? []},
    };
    notifyListeners();
  }

  /// Mirrors `dke()`: append streamed text to a row field.
  Map<String, dynamic> _appendToRow(
      Map<String, dynamic> row, String? path, String append) {
    switch (path) {
      case 'text':
        if (row['kind'] == 'assistantText' || row['kind'] == 'reasoning') {
          return {...row, 'text': '${row['text'] ?? ''}$append'};
        }
        return row;
      case 'inputText':
        if (row['kind'] == 'toolCall') {
          return {...row, 'inputText': '${row['inputText'] ?? ''}$append'};
        }
        return row;
      case 'output.text':
        if (row['kind'] == 'toolCall' && row['output'] is Map) {
          final output = (row['output'] as Map).cast<String, dynamic>();
          return {
            ...row,
            'output': {...output, 'text': '${output['text'] ?? ''}$append'},
          };
        }
        return row;
      case 'summaryText':
        if (row['kind'] == 'subagent') {
          return {
            ...row,
            'summaryText': '${row['summaryText'] ?? ''}$append',
          };
        }
        return row;
      default:
        return row;
    }
  }

  Map<String, dynamic>? get control =>
      (snapshot?['control'] as Map?)?.cast<String, dynamic>();

  /// Current conversation revision (CAS commands base this on).
  int get revision => (snapshot?['revision'] as num?)?.toInt() ?? 0;

  String get phase => control?['phase'] as String? ?? '';

  bool get canStop => control?['canStop'] == true;

  bool get isRunning => phase == 'running' || phase == 'prewarming';

  /// Session config: {provider, model, thought, thoughtLevels, followupMode,
  /// mode}.
  Map<String, dynamic>? get config =>
      (snapshot?['config'] as Map?)?.cast<String, dynamic>();

  String get currentModel => config?['model'] as String? ?? '';
  String get currentThought => config?['thought'] as String? ?? '';
  String get currentMode => config?['mode'] as String? ?? 'build';
  List<String> get thoughtLevels => config?['thoughtLevels'] is List
      ? (config!['thoughtLevels'] as List).map((e) => '$e').toList()
      : const [];

  /// Held queue: {items: [...], autoDrain}.
  Map<String, dynamic>? get queue =>
      (snapshot?['queue'] as Map?)?.cast<String, dynamic>();

  List<Map<String, dynamic>> get queueItems {
    final items = queue?['items'];
    if (items is! List) return const [];
    return items
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }

  bool get autoDrain => queue?['autoDrain'] != false;

  /// Token usage: {contextWindow: {usedTokens, maxTokens, ...}?, cumulative}.
  Map<String, dynamic>? get usage =>
      (snapshot?['usage'] as Map?)?.cast<String, dynamic>();

  /// Older history exists beyond the current window.
  bool get canLoadOlder =>
      !historyExhausted && firstRowId != null && totalCount > rows.length;

  /// The cursor for `rowsRange` is the oldest row currently held, not the
  /// snapshot projection head (`firstRowId`).
  int? get oldestRowId =>
      rows.isEmpty ? firstRowId : (rows.first['rowId'] as num?)?.toInt();

  /// Prepends older rows loaded via rowsRange (deduped by rowId).
  void prependOlderRows(List<Map<String, dynamic>> older, int? newFirstRowId) {
    final existing = rows.map((r) => (r['rowId'] as num?)?.toInt()).toSet();
    final fresh = older
        .where((r) => !existing.contains((r['rowId'] as num?)?.toInt()))
        .toList();
    if (fresh.isNotEmpty) {
      rows = [...fresh, ...rows];
      final firstFresh = (fresh.first['rowId'] as num?)?.toInt();
      firstRowId = newFirstRowId ?? firstFresh ?? firstRowId;
      notifyListeners();
    } else if (newFirstRowId != null && newFirstRowId != firstRowId) {
      firstRowId = newFirstRowId;
      notifyListeners();
    }
  }

  List<Map<String, dynamic>> get backgroundWorks {
    final list = snapshot?['backgroundWorks'];
    if (list is! List) return const [];
    return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  Map<String, dynamic>? get goal =>
      (snapshot?['goal'] as Map?)?.cast<String, dynamic>();

  Map<String, dynamic>? get plan =>
      (snapshot?['plan'] as Map?)?.cast<String, dynamic>();

  /// inputRouting: {mode: startNow|enqueue|guide|reject|choice, reasonCode?}
  String get inputRoutingMode =>
      (snapshot?['inputRouting'] as Map?)?['mode'] as String? ?? 'startNow';

  List<Map<String, dynamic>> get pendingInteractions {
    final list = snapshot?['pendingInteractions'];
    if (list is! List) return const [];
    return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }
}
