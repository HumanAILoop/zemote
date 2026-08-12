import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/chat_page.dart';

void main() {
  group('assistantTurnParts', () {
    test('merges interleaved text + tool rows into ONE assistant block', () {
      final parts = assistantTurnParts([
        {'kind': 'reasoning', 'text': '思考…'},
        {
          'kind': 'assistantText',
          'text': 'Let me check.',
          'rowId': 1,
          'entityId': 'e1',
          'feedback': 'like',
        },
        {'kind': 'toolCall', 'toolName': 'bash'},
        {
          'kind': 'assistantText',
          'text': 'Done.',
          'rowId': 2,
          'entityId': 'e2',
        },
        {'kind': 'subagent', 'text': '…'},
        {'kind': 'turnHeader', 'status': 'completed'},
      ]);
      expect(parts.text, 'Let me check.\n\nDone.');
      expect(parts.tiles.map((t) => t['kind']),
          ['reasoning', 'toolCall', 'subagent']);
      expect(parts.header?['status'], 'completed');
      expect(parts.streaming, isFalse);
    });

    test('streaming flag propagates', () {
      final parts = assistantTurnParts([
        {
          'kind': 'assistantText',
          'text': '正在输出…',
          'state': 'streaming',
        },
      ]);
      expect(parts.text, '正在输出…');
      expect(parts.streaming, isTrue);
      expect(parts.tiles, isEmpty);
    });

    test('empty text rows are dropped', () {
      final parts = assistantTurnParts([
        {'kind': 'assistantText', 'text': '   '},
        {'kind': 'assistantText', 'text': 'real answer'},
      ]);
      expect(parts.text, 'real answer');
    });

    test('no assistant text returns empty text but keeps tiles', () {
      final parts = assistantTurnParts([
        {'kind': 'toolCall', 'toolName': 'bash'},
      ]);
      expect(parts.text, '');
      expect(parts.tiles, hasLength(1));
    });
  });
}
