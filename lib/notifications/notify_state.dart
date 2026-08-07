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

  const NotifyUpdate({required this.running, required this.completed});

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
}) {
  final running = <RunningTask>[];
  final completed = <CompletionEvent>[];
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

  return NotifyUpdate(running: running, completed: completed);
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
