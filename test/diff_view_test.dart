import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/diff_view.dart';

void main() {
  test('extract diff from old/new input aliases', () {
    final diff = extractDiff({
      'kind': 'toolCall',
      'toolName': 'Edit',
      'input': {
        'filePath': 'a.dart',
        'old_string': 'foo\nbar\nbaz',
        'new_string': 'foo\nqux\nbaz',
      },
    });
    expect(diff, isNotNull);
    expect(diff!.filePath, 'a.dart');
    final types = diff.lines.map((l) => l.type).toList();
    expect(types, contains(DiffLineType.removed));
    expect(types, contains(DiffLineType.added));
    // unchanged shared lines kept as context
    expect(diff.lines.first.text, ' foo');
  });

  test('extract diff from structuredPatch', () {
    final diff = extractDiff({
      'kind': 'toolCall',
      'structuredPatch': [
        {
          'oldStart': 1,
          'lines': [' ctx', '-old', '+new'],
        },
      ],
    });
    expect(diff, isNotNull);
    expect(diff!.lines[1].type, DiffLineType.removed);
    expect(diff.lines[2].type, DiffLineType.added);
  });

  test('no diff for non-edit tool calls', () {
    expect(
      extractDiff({
        'kind': 'toolCall',
        'toolName': 'Bash',
        'input': {'command': 'ls'},
      }),
      isNull,
    );
  });

  test('extract diff from tool call output', () {
    final diff = extractDiff({
      'kind': 'toolCall',
      'toolName': 'Write',
      'output': {
        'filePath': 'b.dart',
        'oldText': 'hello',
        'newText': 'world',
      },
    });
    expect(diff, isNotNull);
    expect(diff!.filePath, 'b.dart');
    expect(diff.lines, isNotEmpty);
  });

  test('extract diff from display.kind file_diff', () {
    final diff = extractDiff({
      'kind': 'toolCall',
      'display': {
        'kind': 'file_diff',
        'filePath': 'c.dart',
        'oldText': 'aaa\nbbb',
        'newText': 'aaa\nccc',
      },
    });
    expect(diff, isNotNull);
    expect(diff!.filePath, 'c.dart');
  });

  test('extract diff from rawOutput', () {
    final diff = extractDiff({
      'kind': 'toolCall',
      'raw': {
        'rawOutput': {
          'path': 'd.txt',
          'old_content': 'x\ny',
          'new_content': 'x\nz',
        },
      },
    });
    expect(diff, isNotNull);
    expect(diff!.filePath, 'd.txt');
  });

  test('extract diff from newString/content alias', () {
    final diff = extractDiff({
      'kind': 'toolCall',
      'input': {
        'file': 'e.txt',
        'oldText': 'old',
        'content': 'new',
      },
    });
    expect(diff, isNotNull);
    expect(diff!.filePath, 'e.txt');
  });

  test('structuredPatch with map-style lines', () {
    final diff = extractDiff({
      'kind': 'toolCall',
      'structuredPatch': [
        {
          'filePath': 'f.dart',
          'lines': [
            {'type': 'context', 'text': 'context'},
            {'type': 'added', 'content': 'new line'},
            {'type': 'removed', 'content': 'old line'},
          ],
        },
      ],
    });
    expect(diff, isNotNull);
    expect(diff!.filePath, 'f.dart');
    expect(diff.lines[0].type, DiffLineType.context);
    expect(diff.lines[1].type, DiffLineType.added);
    expect(diff.lines[2].type, DiffLineType.removed);
  });

  test('identical old/new returns only context lines', () {
    final diff = extractDiff({
      'kind': 'toolCall',
      'input': {
        'oldText': 'same\ncontent',
        'newText': 'same\ncontent',
      },
    });
    expect(diff, isNotNull);
    for (final line in diff!.lines) {
      expect(line.type, DiffLineType.context);
    }
  });

  test('single line add (empty old)', () {
    final diff = extractDiff({
      'kind': 'toolCall',
      'input': {
        'oldText': '',
        'newText': 'new only',
      },
    });
    expect(diff, isNotNull);
    expect(diff!.lines.any((l) => l.type == DiffLineType.added), isTrue);
  });

  test('single line delete (empty new)', () {
    final diff = extractDiff({
      'kind': 'toolCall',
      'input': {
        'oldText': 'old only',
        'newText': '',
      },
    });
    expect(diff, isNotNull);
    expect(diff!.lines.any((l) => l.type == DiffLineType.removed), isTrue);
  });

  test('null output for empty candidates', () {
    expect(
      extractDiff({'kind': 'toolCall'}),
      isNull,
    );
  });
}
