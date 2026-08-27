import 'dart:async';
import 'dart:typed_data';

import 'ipc_codec.dart';

/// Channel RPC client mirroring `Pne` (ChannelClient) in the web client.
///
/// Request header array: [reqType, reqId, channelName, name] followed by the
/// argument value (an args list for calls, free-form for event listens).
/// Response: [respType, reqId] + data value.
class ChannelClient {
  static const reqPromise = 100;
  static const reqPromiseCancel = 101;
  static const reqEventListen = 102;
  static const reqEventDispose = 103;

  static const resInitialize = 200;
  static const resPromiseSuccess = 201;
  static const resPromiseError = 202;
  static const resPromiseErrorObj = 203;
  static const resEventFire = 204;

  final void Function(Uint8List ipcBody) sendBody;
  final void Function(String line)? onLog;

  int _lastRequestId = 0;
  final _initialized = Completer<void>();
  final _handlers = <int, void Function(int type, Object? data)>{};

  ChannelClient({required this.sendBody, this.onLog});

  Future<void> get ready => _initialized.future;

  void handleMessage(Uint8List body) {
    try {
      final reader = ValueReader(body);
      final header = decodeValue(reader);
      if (header is! List || header.isEmpty || header[0] is! num) return;
      final type = (header[0] as num).toInt();
      if (type == resInitialize) {
        onLog?.call('[ipc] initialized');
        if (!_initialized.isCompleted) _initialized.complete();
        return;
      }
      if (header.length < 2 || header[1] is! num) return;
      final id = (header[1] as num).toInt();
      final data = decodeValue(reader);
      _handlers[id]?.call(type, data);
    } on Object catch (e) {
      onLog?.call('[ipc] invalid frame: $e');
    }
  }

  void _sendRequest(
      int reqType, int id, String channel, String name, Object? arg) {
    final writer = ValueWriter();
    encodeValue(writer, [reqType, id, channel, name]);
    encodeValue(writer, arg);
    sendBody(writer.toBytes());
  }

  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    return Future.wait([
      ready.timeout(const Duration(seconds: 30), onTimeout: () {
        throw TimeoutException(
            'channel init timeout (no Initialize frame from desktop)');
      }),
    ]).then((_) {
      final id = _lastRequestId++;
      final completer = Completer<dynamic>();
      _handlers[id] = (type, data) {
        switch (type) {
          case resPromiseSuccess:
            _handlers.remove(id);
            completer.complete(data);
            break;
          case resPromiseError:
            _handlers.remove(id);
            final message =
                data is Map ? (data['message'] ?? data).toString() : '$data';
            completer.completeError(ChannelRpcError(message, data));
            break;
          case resPromiseErrorObj:
            _handlers.remove(id);
            completer.completeError(ChannelRpcError('$data', data));
            break;
        }
      };
      onLog?.call('[ipc] call $channel.$method id=$id');
      _sendRequest(reqPromise, id, channel, method, args);
      return completer.future.timeout(timeout, onTimeout: () {
        _handlers.remove(id);
        throw TimeoutException('$channel.$method timed out', timeout);
      });
    });
  }

  /// Subscribe to a channel event. Returns a cancel function which sends
  /// EventDispose. Mirrors `requestEvent` / `sendCancelOrDispose`.
  void Function() addEventListener(
    String channel,
    String event,
    void Function(dynamic event) onEvent, {
    Object? arg,
  }) {
    final id = _lastRequestId++;
    var sent = false;
    var cancelled = false;
    _handlers[id] = (type, data) {
      if (type == resEventFire) onEvent(data);
    };
    ready.then((_) {
      if (cancelled) return;
      sent = true;
      onLog?.call('[ipc] listen $channel.$event id=$id');
      _sendRequest(reqEventListen, id, channel, event, arg);
    });
    return () {
      cancelled = true;
      _handlers.remove(id);
      if (sent) _sendRequest(reqEventDispose, id, channel, event, null);
    };
  }

  void dispose() => _handlers.clear();
}

class ChannelRpcError implements Exception {
  final String message;
  final Object? data;
  ChannelRpcError(this.message, this.data);

  @override
  String toString() => 'ChannelRpcError: $message';
}

/// Well-known channel names (`Wb` enum in the web client).
class Channels {
  static const file = 'file';
  static const system = 'system';
  static const terminal = 'terminal';
  static const git = 'git';
  static const gitCheckpoint = 'git-checkpoint';
  static const setting = 'setting';
  static const credential = 'credential';
  static const broadcast = 'broadcast';
  static const zcodeTask = 'zcode-task';
  static const zcodeAgent = 'zcode-agent';
  static const zcodeSession = 'zcode-session';
  static const fileWatcher = 'file-watcher';
  static const oauth = 'oauth';
  static const modelProvider = 'model-provider';
  static const usageStats = 'usage-stats';
  static const codingPlanSubscription = 'coding-plan-subscription';
  static const skills = 'skills';
  static const skillSync = 'skill-sync';
  static const mcpSync = 'mcp-sync';
  static const pluginSync = 'plugin-sync';
  static const plugins = 'plugins';
  static const pluginManagement = 'plugin-management';
  static const subagents = 'subagents';
  static const commands = 'commands';
  static const hooks = 'hooks';
  static const memory = 'memory';
  static const outputStyle = 'output-style';
  static const settingsSync = 'settings-sync';
  static const bots = 'bots';
  static const feedback = 'feedback';
  static const repoWiki = 'repo-wiki';
  static const promptAttachmentTransfer = 'prompt-attachment-transfer';
  static const offPeakTask = 'off-peak-task';
}
