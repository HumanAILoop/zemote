import 'dart:convert';
import 'dart:typed_data';

/// Value codec mirroring `Sm()`/`Cm()` in the web client.
///
/// Type tags: Undefined=0, String=1, Buffer=2, VSBuffer=3, Array=4,
/// Object=5 (JSON), Int=6. Lengths/counts are 7-bit little-endian varints.
class ValueWriter {
  final BytesBuilder _builder = BytesBuilder();

  void writeByte(int v) => _builder.addByte(v & 0xFF);

  void writeVarint(int value) {
    var v = value;
    do {
      var byte = v & 0x7F;
      v >>= 7;
      if (v > 0) byte |= 0x80;
      _builder.addByte(byte);
    } while (v > 0);
  }

  void writeBytes(List<int> bytes) => _builder.add(bytes);

  Uint8List toBytes() => _builder.toBytes();
}

class ValueReader {
  final Uint8List data;
  int pos = 0;

  ValueReader(this.data);

  int get remaining => data.length - pos;

  Uint8List read(int n) {
    if (pos + n > data.length) {
      throw FormatException(
          'ValueReader: cannot read $n bytes, only ${data.length - pos} remaining');
    }
    final end = pos + n;
    final out = Uint8List.sublistView(data, pos, end);
    pos = end;
    return out;
  }

  int readVarint() {
    var value = 0;
    var shift = 0;
    while (pos < data.length) {
      final b = data[pos++];
      value |= (b & 0x7F) << shift;
      if ((b & 0x80) == 0) return value;
      shift += 7;
      if (shift >= 35) break;
    }
    throw FormatException('ValueReader: invalid varint at pos $pos');
  }
}

void encodeValue(ValueWriter w, Object? value) {
  if (value == null) {
    w.writeByte(0);
  } else if (value is String) {
    final bytes = utf8.encode(value);
    w.writeByte(1);
    w.writeVarint(bytes.length);
    w.writeBytes(bytes);
  } else if (value is Uint8List) {
    w.writeByte(3);
    w.writeVarint(value.length);
    w.writeBytes(value);
  } else if (value is List) {
    w.writeByte(4);
    w.writeVarint(value.length);
    for (final item in value) {
      encodeValue(w, item);
    }
  } else if (value is int && value >= 0 && value <= 0x7FFFFFFF) {
    w.writeByte(6);
    w.writeVarint(value);
  } else {
    final bytes = utf8.encode(jsonEncode(value));
    w.writeByte(5);
    w.writeVarint(bytes.length);
    w.writeBytes(bytes);
  }
}

Object? decodeValue(ValueReader r) {
  final tag = r.read(1)[0];
  switch (tag) {
    case 0:
      return null;
    case 1:
      return utf8.decode(r.read(r.readVarint()));
    case 2:
    case 3:
      return r.read(r.readVarint());
    case 4:
      final count = r.readVarint();
      return List<Object?>.generate(count, (_) => decodeValue(r));
    case 5:
      return jsonDecode(utf8.decode(r.read(r.readVarint())));
    case 6:
      return r.readVarint();
    default:
      throw FormatException('unknown value tag $tag');
  }
}

/// IPC frame framing (`Mne()` / `Nne` in the web client):
/// 13-byte header `[type:u8][id:u32be][ack:u32be][bodyLen:u32be]` + body.
class IpcFraming {
  static const typeRegular = 1;

  static Uint8List encode(Uint8List body) {
    final out = Uint8List(13 + body.length);
    final view = ByteData.sublistView(out);
    view.setUint8(0, typeRegular);
    view.setUint32(1, 0);
    view.setUint32(5, 0);
    view.setUint32(9, body.length);
    out.setRange(13, out.length, body);
    return out;
  }
}

/// Incremental parser for IPC frames.
class IpcFrameParser {
  final BytesBuilder _buffer = BytesBuilder();

  List<Uint8List> acceptChunk(Uint8List chunk) {
    _buffer.add(chunk);
    final out = <Uint8List>[];
    var data = _buffer.toBytes();
    var offset = 0;
    while (data.length - offset >= 13) {
      final view = ByteData.sublistView(data, offset);
      final type = view.getUint8(0);
      final bodyLen = view.getUint32(9);
      final total = 13 + bodyLen;
      if (data.length - offset < total) break;
      if (type == IpcFraming.typeRegular) {
        out.add(Uint8List.sublistView(data, offset + 13, offset + total));
      }
      offset += total;
    }
    if (offset > 0) {
      final rest = Uint8List.sublistView(data, offset);
      _buffer.clear();
      _buffer.add(rest);
    }
    return out;
  }
}
