import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/protocol/ipc_codec.dart';

void main() {
  group('ValueReader truncation', () {
    test('read beyond length throws FormatException', () {
      final reader = ValueReader(Uint8List.fromList([1, 2, 3]));
      expect(() => reader.read(5), throwsFormatException);
    });

    test('read exactly at boundary succeeds', () {
      final reader = ValueReader(Uint8List.fromList([1, 2, 3]));
      final result = reader.read(3);
      expect(result, [1, 2, 3]);
      expect(reader.remaining, 0);
    });
  });

  group('ValueReader readVarint', () {
    test('simple varint', () {
      final writer = ValueWriter();
      writer.writeVarint(300);
      final reader = ValueReader(writer.toBytes());
      expect(reader.readVarint(), 300);
    });

    test('zero', () {
      final writer = ValueWriter();
      writer.writeVarint(0);
      final reader = ValueReader(writer.toBytes());
      expect(reader.readVarint(), 0);
    });

    test('max 32-bit value', () {
      final writer = ValueWriter();
      writer.writeVarint(0x7FFFFFFF);
      final reader = ValueReader(writer.toBytes());
      expect(reader.readVarint(), 0x7FFFFFFF);
    });

    test('truncated varint throws FormatException', () {
      final bytes = Uint8List.fromList([0x80, 0x80, 0x80, 0x80, 0x80]);
      final reader = ValueReader(bytes);
      expect(() => reader.readVarint(), throwsFormatException);
    });

    test('empty data throws FormatException', () {
      final reader = ValueReader(Uint8List(0));
      expect(() => reader.readVarint(), throwsFormatException);
    });
  });

  group('encodeValue tag coverage', () {
    test('null → tag 0', () {
      final w = ValueWriter();
      encodeValue(w, null);
      final bytes = w.toBytes();
      expect(bytes, [0]);
    });

    test('String → tag 1', () {
      final w = ValueWriter();
      encodeValue(w, 'hello');
      final r = ValueReader(w.toBytes());
      expect(r.read(1)[0], 1);
      final len = r.readVarint();
      final decoded = utf8.decode(r.read(len));
      expect(decoded, 'hello');
    });

    test('Uint8List → tag 3', () {
      final w = ValueWriter();
      encodeValue(w, Uint8List.fromList([10, 20, 30]));
      final r = ValueReader(w.toBytes());
      final decoded = decodeValue(r);
      expect(decoded, [10, 20, 30]);
    });

    test('List → tag 4', () {
      final w = ValueWriter();
      encodeValue(w, [1, 'a', true]);
      final r = ValueReader(w.toBytes());
      final decoded = decodeValue(r) as List;
      expect(decoded[0], 1);
      expect(decoded[1], 'a');
      expect(decoded[2], true);
    });

    test('Map (JSON) → tag 5', () {
      final w = ValueWriter();
      encodeValue(w, {'key': 'value', 'num': 42});
      final r = ValueReader(w.toBytes());
      final decoded = decodeValue(r) as Map;
      expect(decoded['key'], 'value');
      expect(decoded['num'], 42);
    });

    test('int (positive) → tag 6', () {
      final w = ValueWriter();
      encodeValue(w, 123456);
      final r = ValueReader(w.toBytes());
      expect(decodeValue(r), 123456);
    });

    test('nested structures', () {
      final w = ValueWriter();
      encodeValue(w, {
        'ints': [1, 2, 3],
        'texts': ['a', 'b'],
        'nested': {'x': null},
      });
      final r = ValueReader(w.toBytes());
      final decoded = decodeValue(r) as Map;
      final ints = decoded['ints'] as List;
      expect(ints, [1, 2, 3]);
      final texts = decoded['texts'] as List;
      expect(texts, ['a', 'b']);
      final nested = decoded['nested'] as Map;
      expect(nested['x'], isNull);
    });

    test('large negative int treated as Map (tag 5)', () {
      final w = ValueWriter();
      encodeValue(w, -1);
      final r = ValueReader(w.toBytes());
      final tag = r.read(1)[0];
      expect(tag, 5); // negative ints fall through to JSON encode
    });
  });

  group('IpcFraming roundtrip', () {
    test('single chunk parse', () {
      final body = ValueWriter();
      body.writeVarint(42);
      final frame = IpcFraming.encode(body.toBytes());
      final parser = IpcFrameParser();
      final results = parser.acceptChunk(frame);
      expect(results, hasLength(1));
      final reader = ValueReader(results[0]);
      expect(reader.readVarint(), 42);
    });

    test('split into multiple chunks', () {
      final body = ValueWriter();
      body.writeVarint(999);
      final frame = IpcFraming.encode(body.toBytes());

      final parser = IpcFrameParser();
      final parts = <Uint8List>[];
      for (var i = 0; i < frame.length; i++) {
        final results = parser.acceptChunk(Uint8List.sublistView(frame, i, i + 1));
        parts.addAll(results);
      }
      expect(parts, hasLength(1));
      final reader = ValueReader(parts[0]);
      expect(reader.readVarint(), 999);
    });

    test('two frames in one chunk', () {
      final body1 = ValueWriter()..writeVarint(10);
      final body2 = ValueWriter()..writeVarint(20);
      final f1 = IpcFraming.encode(body1.toBytes());
      final f2 = IpcFraming.encode(body2.toBytes());

      final combined = Uint8List.fromList([...f1, ...f2]);
      final parser = IpcFrameParser();
      final results = parser.acceptChunk(combined);
      expect(results, hasLength(2));
      expect(ValueReader(results[0]).readVarint(), 10);
      expect(ValueReader(results[1]).readVarint(), 20);
    });

    test('partial header across chunks', () {
      final body = ValueWriter()..writeVarint(555);
      final frame = IpcFraming.encode(body.toBytes());

      final parser = IpcFrameParser();
      // First chunk: only 5 bytes (partial header)
      final r1 = parser.acceptChunk(Uint8List.sublistView(frame, 0, 5));
      expect(r1, isEmpty);
      // Remaining bytes complete the frame
      final r2 = parser.acceptChunk(Uint8List.sublistView(frame, 5));
      expect(r2, hasLength(1));
      expect(ValueReader(r2[0]).readVarint(), 555);
    });
  });
}
