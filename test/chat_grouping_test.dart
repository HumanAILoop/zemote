import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/chat_page.dart';

void main() {
  group('assistantTurnParts', () {
    test('preserves order and merges consecutive text only', () {
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
        {'kind': 'assistantText', 'text': ' Final words.', 'rowId': 3},
        {'kind': 'subagent', 'text': '…'},
        {'kind': 'turnHeader', 'status': 'completed'},
      ]);
      // reasoning/tool/subagent keep their original order in tiles
      expect(parts.tiles.map((t) => t['kind']),
          ['reasoning', 'toolCall', 'subagent']);
      // consecutive assistantText after the tool merge into ONE segment
      expect(parts.segments, hasLength(2));
      expect(parts.segments[0]['text'], 'Let me check.');
      expect(parts.segments[1]['text'], 'Done.\n\n Final words.');
      expect(parts.header?['status'], 'completed');
      expect(parts.streaming, isFalse);
    });

    test('streaming flag propagates', () {
      final parts = assistantTurnParts([
        {'kind': 'assistantText', 'text': '正在输出…', 'state': 'streaming'},
      ]);
      expect(parts.segments, hasLength(1));
      expect(parts.segments[0]['text'], '正在输出…');
      expect(parts.streaming, isTrue);
      expect(parts.tiles, isEmpty);
    });

    test('empty text rows are dropped', () {
      final parts = assistantTurnParts([
        {'kind': 'assistantText', 'text': '   '},
        {'kind': 'assistantText', 'text': 'real answer'},
      ]);
      expect(parts.segments, hasLength(1));
      expect(parts.segments[0]['text'], 'real answer');
    });

    test('no assistant text returns empty segments but keeps tiles', () {
      final parts = assistantTurnParts([
        {'kind': 'toolCall', 'toolName': 'bash'},
      ]);
      expect(parts.segments, isEmpty);
      expect(parts.tiles, hasLength(1));
    });
  });
}
