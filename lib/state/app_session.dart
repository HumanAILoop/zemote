import 'package:flutter/foundation.dart';

import '../protocol/zemote_client.dart';
import '../state/log_store.dart';
import 'account_store.dart';

/// Manages connections to multiple devices simultaneously. Each account can
/// have an independent live connection; exactly one is "active" and drives
/// the MainShell view. Switching to an already-connected device does not
/// reconnect.
class AppSession extends ChangeNotifier {
  final Map<String, ZemoteClient> _connections = {};
  final Set<String> _connecting = {};
  final Map<String, String> _errors = {};
  String? _activeId;
  Account? _activeAccount;

  /// Currently active device client (drives MainShell).
  ZemoteClient? get client => _connections[_activeId];

  /// Currently active device account.
  Account? get current => _activeAccount;

  /// Whether [accountId] currently has a live connection.
  bool isConnected(String accountId) => _connections.containsKey(accountId);

  /// Whether [accountId] is currently establishing a connection.
  bool connecting(String accountId) => _connecting.contains(accountId);

  /// Last error for [accountId], if any.
  String? errorOf(String accountId) => _errors[accountId];

  /// Client for a specific (possibly non-active) device.
  ZemoteClient? clientOf(String accountId) => _connections[accountId];

  /// True while any device is connecting (disables global add actions).
  bool get connectingAny => _connecting.isNotEmpty;

  /// Ensure [account] is connected and make it active. Reuses an existing
  /// live connection; otherwise establishes a new one.
  Future<ZemoteClient> connect(Account account) async {
    final existing = _connections[account.id];
    if (existing != null) {
      _activate(account);
      return existing;
    }
    _connecting.add(account.id);
    _errors.remove(account.id);
    notifyListeners();
    final params = account.params;
    if (params == null) {
      _connecting.remove(account.id);
      _errors[account.id] = '无法解析连接 URL（需要 sid/hash/t 参数）';
      notifyListeners();
      throw StateError(_errors[account.id]!);
    }
    final c = ZemoteClient(params, onLog: log);
    try {
      await c.connect();
      await c.waitPaired(timeout: const Duration(seconds: 90));
      _connections[account.id] = c;
      _activate(account);
      return c;
    } catch (e, st) {
      _connecting.remove(account.id);
      _errors[account.id] = '$e';
      notifyListeners();
      await c.dispose();
      Error.throwWithStackTrace(StateError('$e'), st);
    }
  }

  /// Switch the active device without reconnecting. Connects first if needed.
  Future<void> switchTo(Account account) async {
    if (_connections.containsKey(account.id)) {
      _activate(account);
      return;
    }
    await connect(account);
  }

  void _activate(Account account) {
    _activeId = account.id;
    _activeAccount = account;
    _connecting.remove(account.id);
    _errors.remove(account.id);
    notifyListeners();
  }

  /// Disconnect a single device.
  Future<void> disconnect(String accountId) async {
    final conn = _connections.remove(accountId);
    _connecting.remove(accountId);
    _errors.remove(accountId);
    if (_activeId == accountId) {
      _activeId = null;
      _activeAccount = null;
    }
    notifyListeners();
    await conn?.dispose();
  }

  /// Disconnect everything.
  Future<void> disconnectAll() async {
    final all = _connections.values.toList();
    _connections.clear();
    _connecting.clear();
    _errors.clear();
    _activeId = null;
    _activeAccount = null;
    notifyListeners();
    for (final c in all) {
      await c.dispose();
    }
  }

  @override
  Future<void> dispose() async {
    await disconnectAll();
    super.dispose();
  }
}
