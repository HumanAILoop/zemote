import '../protocol/conversation.dart';

/// Pure derivation of notification state from a sessions-index snapshot.
/// Kept dependency-free so it can be unit tested.
///
/// [previousPhases] is the sessionId→phase map from the last tick; it doubles
/// as the de-dupe for completion events (a running→terminal transition fires
/// exactly once, and re-running a task fires again on its next completion).
class NotifyUpdate {
  final List<RunningTask> running;
  final List<CompletionEvent> completed;
  final List<AttentionEvent> needsAttention;

  const NotifyUpdate({
    required this.running,
    required this.completed,
    this.needsAttention = const [],
  });

  bool get hasRunning => running.isNotEmpty;
}

class RunningTask {
  final String taskId;
  final String title;
  final String preview;

  const RunningTask({
    required this.taskId,
    required this.title,
    required this.preview,
  });
}

class CompletionEvent {
  final String taskId;
  final String title;
  final String preview;

  const CompletionEvent({
    required this.taskId,
    required this.title,
    required this.preview,
  });
}

/// A task that has a pending interaction (permission / input request) and
/// needs the user's attention.
class AttentionEvent {
  final String taskId;
  final String title;
  final String interactionId;

  const AttentionEvent({
    required this.taskId,
    required this.title,
    required this.interactionId,
  });
}

const _runningPhases = {'running', 'prewarming'};
const _terminalPhases = {
  'completed',
  'completedSuccess',
  'completedInterrupted',
  'cancelled',
  'failed',
  'error',
};

NotifyUpdate computeNotifyUpdate({
  required List<SessionEntry> sessions,
  required Map<String, String> previousPhases,
  Set<String>? notifiedInteractionIds,
}) {
  final running = <RunningTask>[];
  final completed = <CompletionEvent>[];
  final needsAttention = <AttentionEvent>[];
  final nowPhases = <String, String>{};
  final nowEntries = <String, SessionEntry>{};

  for (final e in sessions) {
    nowPhases[e.sessionId] = e.phase;
    nowEntries[e.sessionId] = e;
    if (_runningPhases.contains(e.phase)) {
      running.add(RunningTask(
        taskId: e.sessionId,
        title: e.title.isEmpty ? e.sessionId : e.title,
        preview: e.lastAssistantPreview ?? '',
      ));
    }
    // Pending interaction (permission / input) — notify once per
    // interactionId.
    final interaction = e.pendingInteraction;
    if (interaction != null) {
      final interactionId = '${interaction['interactionId'] ?? ''}';
      if (interactionId.isNotEmpty &&
          !(notifiedInteractionIds?.contains(interactionId) ?? false)) {
        needsAttention.add(AttentionEvent(
          taskId: e.sessionId,
          title: e.title.isEmpty ? e.sessionId : e.title,
          interactionId: interactionId,
        ));
      }
    }
  }

  previousPhases.forEach((sessionId, wasPhase) {
    if (!_runningPhases.contains(wasPhase)) return;
    final now = nowPhases[sessionId];
    if (now == null || !_terminalPhases.contains(now)) return;
    final entry = nowEntries[sessionId];
    completed.add(CompletionEvent(
      taskId: sessionId,
      title: entry?.title.isNotEmpty == true ? entry!.title : sessionId,
      preview: entry?.lastAssistantPreview ?? '',
    ));
  });

  return NotifyUpdate(
    running: running,
    completed: completed,
    needsAttention: needsAttention,
  );
}

/// Formats the running-tasks list into the persistent notification text.
String formatRunningText(List<RunningTask> running) {
  if (running.isEmpty) return '';
  final lines = <String>[];
  for (final t in running) {
    final preview = t.preview.trim();
    lines.add(preview.isEmpty ? '• ${t.title}' : '• ${t.title}\n  $preview');
  }
  return lines.join('\n\n');
}
