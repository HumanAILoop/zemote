import 'dart:async';

import '../protocol/conversation.dart';
import '../protocol/zemote_client.dart';
import 'notifications.dart';
import 'notify_state.dart';

/// Monitors the active workspace's sessions-index while a bridge is open.
/// While tasks are running it drives the Android foreground-service
/// notification with real-time preview updates, and fires silent completion
/// notifications. Tapping a notification routes to the task's chat via
/// [onOpenTask].
class TaskNotifier {
  final BridgeSession bridge;
  final Map<String, dynamic> scope;
  final Notifications notifications;
  final Future<void> Function(String taskId, String title) onOpenTask;

  SessionsIndexSubscription? _sub;
  Map<String, String> _prevPhases = {};
  final Set<String> _notifiedInteractions = {};
  bool _active = false;
  bool _disposed = false;
  bool _permissionChecked = false;
  DateTime _lastForegroundUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _trailingTimer;

  TaskNotifier({
    required this.bridge,
    required this.scope,
    required this.notifications,
    required this.onOpenTask,
  }) {
    notifications.setTapHandler(_handleTap);
  }

  bool get isActive => _active;

  Future<void> start() async {
    if (_active || _disposed) return;
    _active = true;
    _prevPhases = {};
    try {
      final transport = bridge.conversation(scope);
      final sub = await transport.subscribeSessionsIndex();
      if (_disposed || !_active) {
        await sub.dispose();
        return;
      }
      _sub = sub;
      sub.state.addListener(_onState);
      _onState();
    } catch (_) {
      _active = false;
    }
  }

  void _onState() {
    if (!_active || _disposed) return;
    final sub = _sub;
    if (sub == null) return;
    final update = computeNotifyUpdate(
      sessions: sub.state.list,
      previousPhases: _prevPhases,
      notifiedInteractionIds: _notifiedInteractions,
    );
    _prevPhases = {for (final e in sub.state.list) e.sessionId: e.phase};

    for (final c in update.completed) {
      _safe(notifications.notifyTaskCompleted(
        title: '任务完成',
        text: c.preview.trim().isEmpty ? c.title : '${c.title}\n${c.preview}',
        payload: {'taskId': c.taskId, 'title': c.title},
      ));
    }

    for (final a in update.needsAttention) {
      _notifiedInteractions.add(a.interactionId);
      _safe(notifications.notifyTaskCompleted(
        title: '需要你的处理',
        text: a.title,
        payload: {'taskId': a.taskId, 'title': a.title},
      ));
    }

    if (update.hasRunning) {
      _ensurePermission();
      _scheduleForeground(update.running);
    } else {
      _trailingTimer?.cancel();
      _safe(notifications.stopForeground());
    }
  }

  void _ensurePermission() {
    if (_permissionChecked) return;
    _permissionChecked = true;
    _safe(() async {
      final ok = await notifications.hasPermission();
      if (!ok) await notifications.requestPermission();
    }());
  }

  void _scheduleForeground(List<RunningTask> running) {
    const throttle = Duration(milliseconds: 900);
    final now = DateTime.now();
    if (now.difference(_lastForegroundUpdate) >= throttle) {
      _publish(running);
      return;
    }
    _trailingTimer?.cancel();
    _trailingTimer = Timer(throttle, () {
      if (_active && !_disposed) _publish(running);
    });
  }

  void _publish(List<RunningTask> running) {
    _lastForegroundUpdate = DateTime.now();
    final title = '${running.length} 个任务运行中';
    var text = formatRunningText(running);
    if (text.length > 600) text = '${text.substring(0, 597)}…';
    _safe(notifications.updateForeground(title, text));
  }

  Future<void> _handleTap(Map<String, dynamic> payload) async {
    final taskId = payload['taskId'] as String?;
    if (taskId == null || _disposed) return;
    await onOpenTask(taskId, (payload['title'] as String?) ?? taskId);
  }

  Future<void> dispose() async {
    _disposed = true;
    _active = false;
    _trailingTimer?.cancel();
    final sub = _sub;
    _sub = null;
    if (sub != null) {
      sub.state.removeListener(_onState);
      await sub.dispose();
    }
    _safe(notifications.stopForeground());
    notifications.setTapHandler(null);
  }

  void _safe(Future<void> future) {
    future.catchError((_) {});
  }
}
