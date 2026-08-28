import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zemote/state/session_list_cache.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('workspace cache keys are isolated and do not expose paths', () {
    const cache = SessionListCache();
    final a = cache.keyFor(const {'workspacePath': 'C:/secret/a'});
    final b = cache.keyFor(const {'workspacePath': 'C:/secret/b'});

    expect(a, isNot(b));
    expect(a, isNot(contains('secret')));
    expect(a, startsWith('zemote_session_list_v1_'));
  });

  test('cache roundtrip keeps UI fields and drops credentials', () async {
    const cache = SessionListCache();
    const workspace = {
      'workspacePath': 'C:/work',
      'workspaceIdentity': 'work-id',
    };
    await cache.write(workspace, const [
      {
        'taskId': 'task-1',
        'title': 'Cached task',
        'displayStatus': 'running',
        'lastAssistantPreview': 'preview',
        'updatedAt': 20,
        'pinned': true,
        'url': 'https://example.invalid/?hash=secret',
      },
    ]);

    final restored = await cache.read(workspace);
    expect(restored, hasLength(1));
    expect(restored.single['title'], 'Cached task');
    expect(restored.single['pinned'], isTrue);
    expect(restored.single.containsKey('url'), isFalse);
  });
}
