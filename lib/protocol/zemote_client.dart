import 'dart:async';

import 'package:flutter/foundation.dart';

import 'channel_client.dart';
import 'connection_params.dart';
import 'conversation.dart';
import 'device_info.dart';
import 'id.dart';
import 'relay_client.dart';
import 'rpc_transport.dart';

String _reqId(String prefix) => generateRequestId(prefix);

/// High-level facade replicating the web client's `otn()` flow:
/// relay connect -> pair -> bootstrap -> workspace bridge -> channel RPC.
class ZemoteClient {
  final ZemoteConnectionParams params;
  final void Function(String line)? onLog;

  late final RelayClient relay;
  final _pendingMatchers =
      <String, bool Function(Map<String, dynamic>)>{};
  final _pendingCompleters =
      <String, Completer<Map<String, dynamic>>>{};

  StreamSubscription? _payloadSub;

  final _workspaceListUpdatedController =
      StreamController<dynamic>.broadcast();
  Stream<dynamic> get workspaceListUpdated =>
      _workspaceListUpdatedController.stream;

  ZemoteClient(this.params, {this.onLog}) {
    relay = RelayClient(params, onLog: onLog);
    _payloadSub = relay.payloads.listen(_dispatchPayload);
    relay.stateListenable.addListener(_onRelayState);
  }

  void _log(String line) => onLog?.call(line);

  Future<void> connect() => relay.start();

  bool _needsBridgeRecovery = false;

  /// Relay reconnects happen silently (heartbeat timeout, network switch,
  /// laptop sleep). After re-pairing, every active bridge must be
  /// recovered — mirrors the web client's connection recovery.
  void _onRelayState() {
    final state = relay.state;
    if (state == RelayState.reconnecting || state == RelayState.error) {
      if (_activeBridges.isNotEmpty) {
        _needsBridgeRecovery = true;
        // Mark bridges degraded immediately so in-flight commands gate on
        // recovery instead of timing out on the now-dead socket/bridge.
        for (final s in _activeBridges) {
          if (s.degraded.value == null) s.degraded.value = 'reconnecting';
        }
      }
      return;
    }
    if (state == RelayState.paired && _needsBridgeRecovery) {
      _needsBridgeRecovery = false;
      _recoverActiveBridges();
    }
  }

  Future<void> _recoverActiveBridges() async {
    _log('[bridge] recovering ${_activeBridges.length} bridge(s)');
    for (final session in List<BridgeSession>.from(_activeBridges)) {
      if (_recoveringBridges.contains(session)) continue;
      _recoveringBridges.add(session);
      unawaited(_recoverBridgeWithRetry(session));
    }
  }

  final Set<BridgeSession> _recoveringBridges = {};

  /// Retries bridge recovery until it succeeds, so a degraded bridge never
  /// strands commands ("can't send after reconnect"). A relay re-drop during
  /// the retries just prolongs the loop.
  Future<void> _recoverBridgeWithRetry(BridgeSession session) async {
    try {
      for (var attempt = 1; attempt <= 15; attempt++) {
        if (session._disposed) return;
        if (await _recoverBridgeOnce(session)) return;
        if (session._disposed) return;
        _log('[bridge] recovery attempt $attempt failed, retrying');
        await Future.delayed(const Duration(seconds: 3));
      }
    } finally {
      _recoveringBridges.remove(session);
    }
  }

  /// Returns true when the bridge is healthy again.
  Future<bool> _recoverBridgeOnce(BridgeSession session) async {
    final workspaceKey = session.bridge['workspaceKey'] as String?;
    if (workspaceKey == null) return true;
    session.degraded.value = 'recovering';
    // 1) cheap path: workspace-reconnect-request
    try {
      final res = await reconnectWorkspace(workspaceKey)
          .timeout(const Duration(seconds: 15));
      if (res['success'] == true) {
        _log('[bridge] reconnected $workspaceKey');
        session.degraded.value = null;
        session.recovered.value += 1;
        return true;
      }
    } catch (e) {
      _log('[bridge] reconnect-request failed: $e');
    }
    // 2) full reopen: new workspace-bridge-open, swap the transport stack
    // into the SAME BridgeSession so open pages keep working.
    try {
      await _reopenBridge(session, workspaceKey);
      session.degraded.value = null;
      session.recovered.value += 1;
      return true;
    } catch (e) {
      _log('[bridge] reopen failed: $e');
      session.degraded.value = 'reopen-failed: $e';
      return false;
    }
  }

  /// Waits until the relay reports `matched` (paired with the desktop).
  Future<void> waitPaired({Duration timeout = const Duration(seconds: 60)}) {
    if (relay.state == RelayState.paired) return Future.value();
    final completer = Completer<void>();
    Timer? timer;
    void listener() {
      if (relay.state == RelayState.paired && !completer.isCompleted) {
        timer?.cancel();
        completer.complete();
      }
    }

    relay.stateListenable.addListener(listener);
    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        completer.completeError(TimeoutException('pairing timeout'));
      }
    });
    return completer.future.whenComplete(() {
      timer?.cancel();
      relay.stateListenable.removeListener(listener);
    });
  }

  void _dispatchPayload(Map<String, dynamic> payload) {
    final type = payload['zcode_type'];
    if (type == 'workspace-list-updated') {
      _workspaceListUpdatedController.add(payload['result']);
      return;
    }
    if (type == 'bridge-degraded') {
      _handleBridgeDegraded(payload);
      return;
    }
    if (type == 'rpc-frame' || type == 'rpc-frame-ack') {
      // Race: the desktop may push frames (e.g. IPC Initialize) before
      // openBridge's await continuation attaches the transport. Buffer
      // unknown-bridge frames and flush on registration.
      final id = payload['bridgeSessionId'] as String?;
      final router = id == null ? null : _frameRouters[id];
      if (router != null) {
        router(payload);
      } else if (id != null) {
        (_pendingBridgePayloads[id] ??= []).add(payload);
      }
      return;
    }
    // Mirrors the web client's `k()` helper: every pending matcher is
    // tested against every payload; responses are NOT guaranteed to echo
    // our requestId.
    final done = <String>[];
    _pendingMatchers.forEach((requestId, matcher) {
      final completer = _pendingCompleters[requestId];
      if (completer != null &&
          !completer.isCompleted &&
          matcher(payload)) {
        done.add(requestId);
        completer.complete(payload);
      }
    });
    for (final id in done) {
      _pendingMatchers.remove(id);
      _pendingCompleters.remove(id);
    }
  }

  /// Request/response over relay payloads (mirrors the `k()` helper).
  Future<Map<String, dynamic>> request(
    Map<String, dynamic> payload,
    bool Function(Map<String, dynamic>) match, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final requestId = payload['requestId'] as String;
    final completer = Completer<Map<String, dynamic>>();
    _pendingMatchers[requestId] = match;
    _pendingCompleters[requestId] = completer;
    relay.sendPayload(payload);
    return completer.future.timeout(timeout, onTimeout: () {
      _pendingMatchers.remove(requestId);
      _pendingCompleters.remove(requestId);
      throw TimeoutException('request $requestId timed out');
    });
  }

  /// bootstrap-request -> bootstrap-response (workspaces overview).
  Future<Map<String, dynamic>> bootstrap() async {
    final id = _reqId('bootstrap');
    final res = await request(
      {'zcode_type': 'bootstrap-request', 'requestId': id},
      (p) =>
          p['zcode_type'] == 'bootstrap-response' && p['requestId'] == id,
    );
    return (res['result'] as Map?)?.cast<String, dynamic>() ?? res;
  }

  /// workspace-list-request -> workspace-list-response.
  Future<dynamic> listWorkspaces() async {
    final id = _reqId('workspace-list');
    final res = await request(
      {'zcode_type': 'workspace-list-request', 'requestId': id},
      (p) =>
          p['zcode_type'] == 'workspace-list-response' &&
          p['requestId'] == id,
    );
    return res['result'];
  }

  int _bridgeGeneration = 0;
  final _activeBridges = <BridgeSession>[];
  final _frameRouters =
      <String, void Function(Map<String, dynamic>)>{};
  final _pendingBridgePayloads =
      <String, List<Map<String, dynamic>>>{};

  /// bridge-degraded (e.g. `rpc-transport-fault`): the desktop stopped the
  /// bridge transport. Recover via `workspace-reconnect-request`
  /// (mirrors the web client's recovery path), then notify listeners so
  /// subscriptions can resync.
  Future<void> _handleBridgeDegraded(Map<String, dynamic> payload) async {
    final bridgeSessionId = payload['bridgeSessionId'] as String?;
    final reason = payload['reason'] as String?;
    _log('[bridge] degraded: $bridgeSessionId reason=$reason');
    for (final session in _activeBridges) {
      if (session.bridge['bridgeSessionId'] == bridgeSessionId) {
        session.degraded.value = reason ?? 'unknown';
      }
    }
    final workspaceKey = _activeBridges
        .where((s) => s.bridge['bridgeSessionId'] == bridgeSessionId)
        .map((s) => s.bridge['workspaceKey'] as String?)
        .firstOrNull;
    if (workspaceKey == null) return;
    try {
      final res = await reconnectWorkspace(workspaceKey);
      final success = res['success'] == true;
      _log('[bridge] reconnect $workspaceKey success=$success');
      for (final session in _activeBridges) {
        if (session.bridge['bridgeSessionId'] == bridgeSessionId) {
          if (success) {
            session.degraded.value = null;
            session.recovered.value += 1;
          } else {
            session.degraded.value =
                '${res['error'] ?? 'reconnect-failed'}';
          }
        }
      }
    } catch (e) {
      _log('[bridge] reconnect failed: $e');
    }
  }

  /// workspace-bridge-open -> workspace-bridge-ready, then builds the
  /// rpc-frame transport + IPC channel client for the workspace.
  Future<BridgeSession> openBridge(
    String workspaceKey, {
    String? taskId,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final bridgeSessionId = _reqId('bridge');
    final generation = ++_bridgeGeneration;
    final requestId = _reqId('workspace-bridge');
    final res = await request(
      {
        'zcode_type': 'workspace-bridge-open',
        'requestId': requestId,
        'bridgeSessionId': bridgeSessionId,
        'bridgeGeneration': generation,
        'workspaceKey': workspaceKey,
        if (taskId != null) 'taskId': taskId,
      },
      (p) =>
          (p['zcode_type'] == 'workspace-bridge-ready' ||
              p['zcode_type'] == 'workspace-bridge-error') &&
          p['bridgeSessionId'] == bridgeSessionId,
      timeout: timeout,
    );
    if (res['zcode_type'] == 'workspace-bridge-error') {
      throw StateError('workspace-bridge-error: ${res['error'] ?? res}');
    }
    final bridge =
        (res['bridge'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    _log('[bridge] ready: $bridge');

    final session = BridgeSession._(
      bridge: bridge,
      onDispose: (s) {
        _activeBridges.remove(s);
        _frameRouters.remove(s.bridge['bridgeSessionId']);
      },
    );
    _attachStack(session, bridgeSessionId, bridge);
    _activeBridges.add(session);

    await sendMobileViewState(
      workspaceKey: (bridge['workspaceKey'] as String?) ?? workspaceKey,
      taskId: (bridge['initialTaskId'] as String?) ?? taskId,
    );
    return session;
  }

  /// Builds the rpc-frame transport + IPC channel stack for a bridge and
  /// attaches it to [session] (fresh or swapped-in after a reopen).
  void _attachStack(
    BridgeSession session,
    String requestedBridgeSessionId,
    Map<String, dynamic> bridge,
  ) {
    session._transport.dispose();
    final transport = RpcFrameTransport(
      bridgeSessionId:
          (bridge['bridgeSessionId'] as String?) ?? requestedBridgeSessionId,
      bridgeGeneration: (bridge['bridgeGeneration'] as num?)?.toInt(),
      recoveryId: bridge['recoveryId'] as String?,
      sendPayload: relay.sendPayload,
      onLog: onLog,
    );
    // Over the workspace bridge each rpc-frame message IS one ChannelClient
    // body (value-stream) — no 13-byte IPC framing on this path.
    final channels = ChannelClient(
      sendBody: transport.sendMessage,
      onLog: onLog,
    );
    transport.messages.listen(channels.handleMessage);
    session._swap(bridge, transport, channels);

    // Register at the single dispatch point and flush any frames that
    // arrived before the transport existed (Initialize race).
    final id = transport.bridgeSessionId;
    final oldId = session._bridge['bridgeSessionId'];
    if (oldId != id) _frameRouters.remove(oldId);
    _frameRouters[id] = transport.acceptPayload;
    final pending = _pendingBridgePayloads.remove(id);
    if (pending != null) {
      for (final payload in pending) {
        transport.acceptPayload(payload);
      }
    }
  }

  /// Reopens a degraded/dead bridge: new `workspace-bridge-open` (fresh
  /// bridgeSessionId, bumped generation, carries recoveryId), then swaps
  /// the stack into the existing [BridgeSession].
  Future<void> _reopenBridge(
      BridgeSession session, String workspaceKey) async {
    final oldBridge = session.bridge;
    final bridgeSessionId = _reqId('bridge');
    final generation = ++_bridgeGeneration;
    final requestId = _reqId('workspace-bridge');
    _log('[bridge] reopen $workspaceKey (gen $generation)');
    final res = await request(
      {
        'zcode_type': 'workspace-bridge-open',
        'requestId': requestId,
        'bridgeSessionId': bridgeSessionId,
        'bridgeGeneration': generation,
        if (oldBridge['recoveryId'] != null)
          'recoveryId': oldBridge['recoveryId'],
        'workspaceKey': workspaceKey,
      },
      (p) =>
          (p['zcode_type'] == 'workspace-bridge-ready' ||
              p['zcode_type'] == 'workspace-bridge-error') &&
          p['bridgeSessionId'] == bridgeSessionId,
    );
    if (res['zcode_type'] == 'workspace-bridge-error') {
      throw StateError('workspace-bridge-error: ${res['error'] ?? res}');
    }
    final bridge =
        (res['bridge'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
    _attachStack(session, bridgeSessionId, bridge);
    _log('[bridge] reopened: $bridge');
  }

  /// mobile-view-state-update (mirrors `N()` in the web client).
  Future<void> sendMobileViewState({
    required String workspaceKey,
    String? taskId,
  }) async {
    relay.sendPayload({
      'zcode_type': 'mobile-view-state-update',
      'viewState': {
        'activeWorkspaceKey': workspaceKey,
        if (taskId != null) 'activeTaskId': taskId,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      'deviceInfo': {
        'platform': zemotePlatformName(),
        'version': params.appVersion ?? 'web',
        'name': zemoteAppName,
      },
    });
  }

  /// workspace-reconnect-request.
  Future<Map<String, dynamic>> reconnectWorkspace(String workspaceKey) async {
    final id = _reqId('workspace-reconnect');
    return request(
      {
        'zcode_type': 'workspace-reconnect-request',
        'requestId': id,
        'workspaceKey': workspaceKey,
      },
      (p) =>
          p['zcode_type'] == 'workspace-reconnect-response' &&
          p['requestId'] == id &&
          p['workspaceKey'] == workspaceKey,
    );
  }

  Future<void> dispose() async {
    relay.stateListenable.removeListener(_onRelayState);
    await _payloadSub?.cancel();
    await relay.dispose();
    await _workspaceListUpdatedController.close();
  }
}

class BridgeSession {
  Map<String, dynamic> _bridge;
  RpcFrameTransport _transport;
  ChannelClient _channels;
  final void Function(BridgeSession) _onDispose;
  bool _disposed = false;

  /// Non-null while the bridge is degraded (rpc-transport-fault etc.).
  final ValueNotifier<String?> degraded = ValueNotifier(null);

  /// Bumped when the bridge recovers/reopens — subscriptions must
  /// resubscribe (server-side subscription state died with the old bridge).
  final ValueNotifier<int> recovered = ValueNotifier(0);

  /// Resolves once the bridge is healthy again (degraded cleared), or throws
  /// [TimeoutException]. Commands gate on this so a send during a
  /// reconnect/recovery window doesn't hang on a dead bridge.
  Future<void> waitHealthy({Duration timeout = const Duration(seconds: 45)}) {
    if (_disposed || degraded.value == null) return Future.value();
    final completer = Completer<void>();
    void check() {
      if (degraded.value == null && !completer.isCompleted) {
        completer.complete();
      }
    }

    degraded.addListener(check);
    check();
    return completer.future.timeout(timeout, onTimeout: () {
      degraded.removeListener(check);
      throw TimeoutException('bridge 恢复超时: ${degraded.value}');
    }).whenComplete(() => degraded.removeListener(check));
  }

  BridgeSession._({
    required Map<String, dynamic> bridge,
    required void Function(BridgeSession) onDispose,
  })  : _bridge = bridge,
        _transport = _placeholderTransport(bridge),
        _channels = ChannelClient(sendBody: (_) {}),
        _onDispose = onDispose;

  static RpcFrameTransport _placeholderTransport(
          Map<String, dynamic> bridge) =>
      RpcFrameTransport(
        bridgeSessionId: '${bridge['bridgeSessionId'] ?? ''}',
        sendPayload: (_) {},
      );

  Map<String, dynamic> get bridge => _bridge;
  RpcFrameTransport get transport => _transport;
  ChannelClient get channels => _channels;

  void _swap(
    Map<String, dynamic> bridge,
    RpcFrameTransport transport,
    ChannelClient channels,
  ) {
    _bridge = bridge;
    _transport = transport;
    _channels = channels;
  }

  String? get workspaceKey => _bridge['workspaceKey'] as String?;
  String? get initialTaskId => _bridge['initialTaskId'] as String?;

  /// The web client performs the conversation handshake ONCE per service
  /// (cached via `wD`). The transport is keyed by scope and cleared on
  /// stack swap so the new bridge handshakes again.
  final Map<String, ConversationTransport> _conversations = {};

  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) {
    final key = '${scope['workspaceIdentity'] ?? scope['workspacePath']}';
    return _conversations.putIfAbsent(
      key,
      () => ConversationTransport(
        session: this,
        scope: scope,
        onLog: onLog,
      ),
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    degraded.dispose();
    recovered.dispose();
    _transport.dispose();
    _onDispose(this);
  }
}
