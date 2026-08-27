import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/chat_page.dart';

void main() {
  test('duplicate text confirmations retire echoes one at a time', () {
    final List<Map<String, dynamic>> echoes = [
      {'text': 'same', 'status': 'sent'},
      {'text': 'same', 'status': 'sent'},
      {'text': 'failed', 'status': 'failed'},
    ];
    final List<Map<String, dynamic>> rows = [
      {'kind': 'userInput', 'text': 'same'},
    ];
    final remaining = removeEchoedTexts(echoes, rows);
    expect(remaining, hasLength(2));
    expect(remaining[0]['text'], 'same');
    expect(remaining[1]['text'], 'failed');
  });

  group('assistantTurnParts', () {
    test('preserves original order: reasoning → text → tool → text', () {
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
        {'kind': 'assistantText', 'text': 'Done.', 'rowId': 2},
        {'kind': 'assistantText', 'text': ' Final words.', 'rowId': 3},
        {'kind': 'subagent', 'text': '…'},
        {'kind': 'turnHeader', 'status': 'completed'},
      ]);
      // Ordered parts: reasoning(tile) → text → tool(tile) → merged text → subagent(tile)
      expect(parts.parts.map((p) => p.kind),
          ['row', 'text', 'row', 'text', 'row']);
      expect(parts.parts[0].row?['kind'], 'reasoning');
      expect(parts.parts[1].text, 'Let me check.');
      expect(parts.parts[2].row?['kind'], 'toolCall');
      expect(parts.parts[3].text, 'Done.\n\n Final words.');
      expect(parts.parts[4].row?['kind'], 'subagent');
      expect(parts.header?['status'], 'completed');
      expect(parts.streaming, isFalse);
    });

    test('streaming flag propagates', () {
      final parts = assistantTurnParts([
        {'kind': 'assistantText', 'text': '正在输出…', 'state': 'streaming'},
      ]);
      expect(parts.parts, hasLength(1));
      expect(parts.parts[0].kind, 'text');
      expect(parts.parts[0].text, '正在输出…');
      expect(parts.parts[0].streaming, isTrue);
      expect(parts.streaming, isTrue);
    });

    test('empty text rows are dropped', () {
      final parts = assistantTurnParts([
        {'kind': 'assistantText', 'text': '   '},
        {'kind': 'assistantText', 'text': 'real answer'},
      ]);
      expect(parts.parts, hasLength(1));
      expect(parts.parts[0].text, 'real answer');
    });

    test('no assistant text keeps tiles only', () {
      final parts = assistantTurnParts([
        {'kind': 'toolCall', 'toolName': 'bash'},
      ]);
      expect(parts.parts, hasLength(1));
      expect(parts.parts[0].kind, 'row');
    });
  });
}
