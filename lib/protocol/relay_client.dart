import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connection_params.dart';
import 'device_info.dart';
import 'proof.dart';

enum RelayState {
  idle,
  connecting,
  authenticating,
  waiting,
  paired,
  reconnecting,
  error,
  kicked,
  closed,
}

class RelayFailure {
  final String reason;
  final String? message;
  const RelayFailure(this.reason, [this.message]);

  @override
  String toString() => message == null ? reason : '$reason: $message';
}

/// Close-code mapping, mirrors `VC()` / `BC` in the web client.
String? relayCloseReason(int code) {
  switch (code) {
    case 4004:
      return 'session-not-found';
    case 4009:
      return 'session-conflict';
    case 4010:
      return 'desktop-disconnected';
    case 4011:
      return 'session-expired';
    case 4012:
      return 'workspace-closed';
    case 4013:
      return 'invalid-mobile-connection';
    default:
      return null;
  }
}

/// Reimplementation of the relay terminal socket (`pen` class in the web
/// client). JSON text frames over `wss://<host>/ws`.
class RelayClient {
  final ZemoteConnectionParams params;
  final void Function(String line)? onLog;

  static const heartbeatInterval = Duration(seconds: 10);
  static const heartbeatAckTimeout = Duration(seconds: 30);
  static const waitingTimeout = Duration(seconds: 30);
  static const reconnectWaitTimeout = Duration(seconds: 20);
  static const _deadLinkThreshold = Duration(seconds: 25);

  WebSocketChannel? _socket;
  StreamSubscription? _socketSub;
  int _socketGeneration = 0;
  bool _connectInFlight = false;

  final _state = ValueNotifier<RelayState>(RelayState.idle);
  ValueListenable<RelayState> get stateListenable => _state;
  RelayState get state => _state.value;

  final _payloadController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get payloads => _payloadController.stream;

  final _failureController = StreamController<RelayFailure>.broadcast();
  Stream<RelayFailure> get failures => _failureController.stream;

  bool _wasPaired = false;
  bool _intentionallyClosed = false;
  bool _disposed = false;
  int _reconnectAttempt = 0;
  int _heartbeatTick = 0;
  bool _staleProbeSent = false;
  bool _kickRecoveryAttempted = false;
  DateTime _lastInboundAt = DateTime.now();

  /// Raw frame logging is expensive and can expose payload contents. Keep it
  /// off by default; connection diagnostics remain logged separately.
  static bool verboseFrames = false;
  DateTime _lastPairStatusAckAt = DateTime.now();

  Timer? _heartbeatTimer;
  Timer? _waitingTimer;
  Timer? _reconnectTimer;
  Timer? _rewaitTimer;

  RelayClient(this.params, {this.onLog});

  void _log(String line) => onLog?.call(line);

  void _setState(RelayState s) {
    _state.value = s;
    _log('[relay] state -> $s');
  }

  Future<void> start() async {
    _disposed = false;
    _intentionallyClosed = false;
    _reconnectAttempt = 0;
    _kickRecoveryAttempted = false;
    _setState(RelayState.connecting);
    await _connect();
  }

  Future<void> _connect() async {
    if (_connectInFlight || _disposed) return;
    _connectInFlight = true;
    final generation = ++_socketGeneration;
    await _socketSub?.cancel();
    _socketSub = null;
    _socket?.sink.close();
    _socket = null;
    _lastPairStatusAckAt = DateTime.now();
    _lastInboundAt = DateTime.now();
    final uri = params.relayWsUri;
    _log('[relay] connecting ${_safeUriForLog(uri)}');
    WebSocketChannel socket;
    try {
      socket = WebSocketChannel.connect(uri);
      await socket.ready;
    } catch (e) {
      _connectInFlight = false;
      _log('[relay] connect failed: $e');
      if (generation == _socketGeneration) {
        _handleSocketClosed(1006, e.toString(), generation: generation);
      }
      return;
    }
    if (_disposed) {
      socket.sink.close();
      _connectInFlight = false;
      return;
    }
    if (generation != _socketGeneration) {
      socket.sink.close();
      _connectInFlight = false;
      return;
    }
    _socket = socket;
    _socketSub = socket.stream.listen(
      (data) => _handleRawMessage(data, generation: generation),
      onError: (e) => _log('[relay] socket error: $e'),
      onDone: () => _handleSocketClosed(
          socket.closeCode ?? 1006, socket.closeReason,
          generation: generation),
    );
    _connectInFlight = false;
    _setState(RelayState.authenticating);
    _send({
      'type': 'auth_init',
      'role': 'terminal',
      'device_sid': params.deviceSid,
      'meta': {
        'platform': zemotePlatformName(),
        'version': params.appVersion ?? 'web',
        'name': zemoteAppName,
      },
      'client_ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _send(Map<String, dynamic> frame) {
    final socket = _socket;
    if (socket == null) return;
    if (verboseFrames) _log('[relay] >> ${jsonEncode(frame)}');
    socket.sink.add(jsonEncode(frame));
  }

  Uri _safeUriForLog(Uri uri) {
    return uri.replace(
      queryParameters: {
        for (final entry in uri.queryParameters.entries)
          entry.key: '<redacted>',
      },
    );
  }

  /// Outbound data payloads are queued while unpaired (reconnecting /
  /// waiting) and flushed once the relay reports `matched` — otherwise
  /// requests sent during a reconnect vanish into a dead socket and the
  /// caller hangs until timeout.
  final _outboundQueue = <Map<String, dynamic>>[];

  void sendPayload(Map<String, dynamic> payload) {
    if (state != RelayState.paired || _socket == null) {
      if (_outboundQueue.length < 100) {
        _log('[relay] queued (state=$state): ${payload['zcode_type']}');
        _outboundQueue.add(payload);
      }
      return;
    }
    _send({
      'type': 'data',
      'payload': payload,
      'client_ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _flushOutboundQueue() {
    if (_outboundQueue.isEmpty) return;
    _log('[relay] flushing ${_outboundQueue.length} queued payload(s)');
    final queued = List<Map<String, dynamic>>.from(_outboundQueue);
    _outboundQueue.clear();
    for (final payload in queued) {
      _send({
        'type': 'data',
        'payload': payload,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  void _handleRawMessage(dynamic data, {required int generation}) {
    if (generation != _socketGeneration || _disposed) return;
    _lastInboundAt = DateTime.now();
    Map<String, dynamic>? frame;
    try {
      final text = data is String ? data : utf8.decode(data as List<int>);
      if (verboseFrames) _log('[relay] << $text');
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic> && decoded.containsKey('type')) {
        frame = decoded;
      }
    } catch (e) {
      _log('[relay] bad frame: $e');
      return;
    }
    if (frame == null) return;
    switch (frame['type']) {
      case 'auth_challenge':
        _send({
          'type': 'auth_response',
          'device_sid': params.deviceSid,
          'proof': calculateProof(
            passHash: params.passHash,
            nonce: frame['nonce'] as String? ?? '',
            role: 'terminal',
            deviceSid: params.deviceSid,
          ),
          'client_ts': DateTime.now().millisecondsSinceEpoch,
        });
        break;
      case 'auth_ack':
      case 'pair_status_ack':
        _applyPairStatus(frame['pair_status'] as String?);
        break;
      case 'data':
        final payload = frame['payload'];
        if (payload is Map<String, dynamic>) {
          _payloadController.add(payload);
        }
        break;
      case 'error':
        _handleRelayError(
            frame['code'] as String?, frame['message'] as String?);
        break;
    }
  }

  void _applyPairStatus(String? status) {
    _lastPairStatusAckAt = DateTime.now();
    _staleProbeSent = false;
    if (status == 'waiting') {
      if (_wasPaired) {
        _clearWaitingTimer();
        _setState(RelayState.waiting);
        _startHeartbeat();
        // A reconnecting mobile that was already paired should be matched
        // immediately; if the server keeps saying "waiting", force another
        // reconnect instead of hanging forever.
        _rewaitTimer?.cancel();
        _rewaitTimer = Timer(reconnectWaitTimeout, () {
          if (_wasPaired && state == RelayState.waiting && !_disposed) {
            _log('[relay] re-pair stuck in waiting, reconnecting');
            _reconnect();
          }
        });
      } else {
        _setState(RelayState.waiting);
        _startWaitingTimer();
      }
      return;
    }
    if (status == 'matched') {
      _rewaitTimer?.cancel();
      _reconnectAttempt = 0;
      _kickRecoveryAttempted = false;
      _clearWaitingTimer();
      _setState(RelayState.paired);
      _wasPaired = true;
      _startHeartbeat();
      _flushOutboundQueue();
    }
  }

  void _handleRelayError(String? code, String? message) {
    _log('[relay] error frame: $code $message');
    if (code == 'KICKED') {
      final detail = (message ?? '').toLowerCase();
      final transient = detail.contains('conflict') ||
          detail.contains('duplicate') ||
          detail.contains('already connected') ||
          detail.contains('another connection');
      if (!_kickRecoveryAttempted &&
          (state == RelayState.authenticating || transient)) {
        _kickRecoveryAttempted = true;
        _failureController.add(RelayFailure('session-conflict', message));
        _reconnect();
        return;
      }
      _setState(RelayState.kicked);
      _intentionallyClosed = true;
      _failureController.add(RelayFailure('kicked', message));
      _socket?.sink.close();
    }
  }

  void _handleSocketClosed(int code, String? reason, {int? generation}) {
    if (_disposed) return;
    if (generation != null && generation != _socketGeneration) return;
    _stopHeartbeat();
    _clearWaitingTimer();
    final mapped = relayCloseReason(code);
    _log('[relay] closed code=$code reason=$reason mapped=$mapped');
    if (_intentionallyClosed) return;
    if (_wasPaired || mapped == 'desktop-disconnected') {
      _scheduleReconnect();
      return;
    }
    _setState(RelayState.error);
    _failureController.add(RelayFailure(
      mapped ?? 'relay-unavailable',
      reason ?? 'connection closed ($code)',
    ));
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (state != RelayState.paired && state != RelayState.waiting) return;
      _heartbeatTick++;
      if (state == RelayState.waiting && _heartbeatTick.isOdd) return;
      if (DateTime.now().difference(_lastPairStatusAckAt) >
          heartbeatAckTimeout) {
        if (!_staleProbeSent) {
          _staleProbeSent = true;
          _log('[relay] heartbeat stale, probing before reconnect');
        } else {
          _staleProbeSent = false;
          _log('[relay] heartbeat ack timeout, reconnecting');
          _reconnect();
          return;
        }
      } else {
        _staleProbeSent = false;
      }
      _send({
        'type': 'pair_status_query',
        'device_sid': params.deviceSid,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  /// Probe immediately when the app returns from background. If no inbound
  /// relay frame arrived for a while, skip backoff and rebuild the socket.
  void poke() {
    if (_disposed || _intentionallyClosed) return;
    if (state == RelayState.paired) {
      if (DateTime.now().difference(_lastInboundAt) > _deadLinkThreshold) {
        _log('[relay] poke: stale inbound link, reconnecting');
        _reconnect();
        return;
      }
      _send({
        'type': 'pair_status_query',
        'device_sid': params.deviceSid,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    } else if (state != RelayState.idle &&
        state != RelayState.closed &&
        state != RelayState.kicked) {
      _log('[relay] poke: state=$state, forcing reconnect');
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _connect();
    }
  }

  void _stopHeartbeat() => _heartbeatTimer?.cancel();

  void _startWaitingTimer() {
    _clearWaitingTimer();
    _waitingTimer = Timer(waitingTimeout, () {
      if (state == RelayState.waiting && !_wasPaired) {
        _setState(RelayState.error);
        _failureController.add(const RelayFailure(
          'invalid-mobile-connection',
          'Desktop did not match this mobile connection before the waiting timeout.',
        ));
      }
    });
  }

  void _clearWaitingTimer() {
    _waitingTimer?.cancel();
    _rewaitTimer?.cancel();
  }

  void _scheduleReconnect() {
    if (_disposed || _intentionallyClosed) return;
    _setState(RelayState.reconnecting);
    final delayMs =
        (1000 * (1 << _reconnectAttempt.clamp(0, 4))).clamp(1000, 15000);
    _reconnectAttempt += 1;
    _log('[relay] reconnect in ${delayMs}ms (attempt $_reconnectAttempt)');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_disposed) _connect();
    });
  }

  Future<void> _reconnect() async {
    if (_disposed || _intentionallyClosed || _connectInFlight) return;
    _reconnectTimer?.cancel();
    // Go through `reconnecting` so listeners (bridge recovery) know the
    // connection dropped — the heartbeat-timeout path used to skip this and
    // bridges were never recovered after re-pairing.
    _setState(RelayState.reconnecting);
    await _connect();
  }

  /// Diagnostics: forcefully drops the socket to exercise the
  /// reconnect/bridge-recovery path (used by integration probes).
  Future<void> debugDropSocket() async {
    _intentionallyClosed = false;
    await _socketSub?.cancel();
    _socketSub = null;
    final socket = _socket;
    _socket = null;
    try {
      await socket?.sink.close(3000, 'debug-drop');
    } catch (_) {}
    _handleSocketClosed(1006, 'debug-drop', generation: _socketGeneration);
  }

  Future<void> dispose() async {
    _disposed = true;
    _intentionallyClosed = true;
    _stopHeartbeat();
    _clearWaitingTimer();
    _reconnectTimer?.cancel();
    _rewaitTimer?.cancel();
    await _socketSub?.cancel();
    _socket?.sink.close();
    _setState(RelayState.closed);
    await _payloadController.close();
    await _failureController.close();
  }
}
