import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/protocol/conversation.dart';
import 'package:zemote/ui/task_home_page.dart';

void main() {
  test('sessions-index adds new workspace sessions and refreshes stale fields',
      () {
    final result = mergeWorkspaceSessionTasks(
      channelTasks: [
        {
          'taskId': 'old',
          'title': 'stale title',
          'updatedAt': 1,
          'pinned': true,
        },
      ],
      sessions: [
        SessionEntry({
          'sessionId': 'old',
          'title': 'fresh title',
          'phase': 'running',
          'lastActivityAt': 20,
          'createdAt': 1,
        }),
        SessionEntry({
          'sessionId': 'new',
          'title': 'new session',
          'phase': 'draft',
          'lastActivityAt': 30,
          'createdAt': 2,
        }),
      ],
      archivedIds: const {},
      workspace: const {'workspacePath': 'C:/work'},
    );

    expect(result.map((task) => task['taskId']), ['new', 'old']);
    expect(result.last['title'], 'fresh title');
    expect(result.last['displayStatus'], 'running');
    expect(result.last['pinned'], isTrue);
  });

  test('archived sessions stay out of active list', () {
    final result = mergeWorkspaceSessionTasks(
      channelTasks: const [],
      sessions: [
        SessionEntry({
          'sessionId': 'archived',
          'title': 'hidden',
          'phase': 'completedSuccess',
        }),
      ],
      archivedIds: const {'archived'},
      workspace: const {'workspacePath': 'C:/work'},
    );

    expect(result, isEmpty);
  });

  test('empty sessions snapshot never clears channel task data', () {
    final result = mergeWorkspaceSessionTasks(
      channelTasks: const [
        {
          'taskId': 'channel-only',
          'title': 'visible task',
          'updatedAt': 10,
        },
      ],
      sessions: const [],
      archivedIds: const {},
      workspace: const {'workspacePath': 'C:/work'},
    );

    expect(result, hasLength(1));
    expect(result.single['taskId'], 'channel-only');
  });

  test('channel refresh never clears sessions-index-only tasks', () {
    final result = mergeWorkspaceSessionTasks(
      channelTasks: const [],
      sessions: [
        SessionEntry({
          'sessionId': 'session-only',
          'title': 'live session',
          'phase': 'running',
          'lastActivityAt': 20,
        }),
      ],
      archivedIds: const {},
      workspace: const {'workspacePath': 'C:/work'},
    );

    expect(result, hasLength(1));
    expect(result.single['taskId'], 'session-only');
  });
}
