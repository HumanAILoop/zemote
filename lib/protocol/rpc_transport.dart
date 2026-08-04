import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'crc32.dart';

/// Reimplementation of the rpc-frame fragmentation transport
/// (`Xf`/`Zf` schemas, `sp()`/`lp()` in the web client).
///
/// Logical messages are split into frames so the JSON envelope stays below
/// [maxPhysicalFrameBytes]; each message carries a crc32 checksum; the
/// receiver acknowledges assembled messages with `rpc-frame-ack`.
class RpcFrameTransport {
  static const maxPhysicalFrameBytes = 1024 * 1024;
  static const maxMessageBytes = 16 * 1024 * 1024;
  static const maxFragments = 64;

  /// Raw bytes per fragment; base64 expands by 4/3, keep envelope < 1 MiB.
  static const _fragmentPayloadBytes = 512 * 1024;

  final String bridgeSessionId;
  final int? bridgeGeneration;
  final String? recoveryId;
  final void Function(Map<String, dynamic> payload) sendPayload;
  final void Function(String line)? onLog;

  int _seq = 0;
  int _messageSeq = 0;

  final _messageController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get messages => _messageController.stream;

  final _assemblies = <int, _Assembly>{};
  Timer? _assemblyCleanupTimer;

  RpcFrameTransport({
    required this.bridgeSessionId,
    required this.sendPayload,
    this.bridgeGeneration,
    this.recoveryId,
    this.onLog,
  }) {
    _assemblyCleanupTimer =
        Timer.periodic(const Duration(seconds: 30), (_) => _purgeStale());
  }

  void _purgeStale() {
    final stale = <int>[];
    final now = DateTime.now();
    _assemblies.forEach((seq, a) {
      if (now.difference(a.createdAt).inSeconds > 60) stale.add(seq);
    });
    for (final seq in stale) {
      _assemblies.remove(seq);
      onLog?.call('[rpc] purged stale assembly $seq');
    }
  }

  Map<String, dynamic> get _identity => {
        'bridgeSessionId': bridgeSessionId,
        if (bridgeGeneration != null) 'bridgeGeneration': bridgeGeneration,
        if (recoveryId != null) 'recoveryId': recoveryId,
      };

  /// Fragment and send one logical message.
  void sendMessage(Uint8List bytes) {
    if (bytes.isEmpty) throw StateError('remote.rpcFrame.emptyMessage');
    if (bytes.length > maxMessageBytes) {
      throw StateError('remote.rpcFrame.messageTooLarge');
    }
    final messageSeq = ++_messageSeq;
    final checksum = Crc32.hexOf(bytes);
    final fragmentCount =
        (bytes.length + _fragmentPayloadBytes - 1) ~/ _fragmentPayloadBytes;
    if (fragmentCount > maxFragments) {
      throw StateError('remote.rpcFrame.fragmentLimitExceeded');
    }
    for (var i = 0; i < fragmentCount; i++) {
      final start = i * _fragmentPayloadBytes;
      final end =
          start + _fragmentPayloadBytes > bytes.length ? bytes.length : start + _fragmentPayloadBytes;
      final chunk = Uint8List.sublistView(bytes, start, end);
      _seq += 1;
      sendPayload({
        'zcode_type': 'rpc-frame',
        ..._identity,
        'seq': _seq,
        'messageSeq': messageSeq,
        'fragmentIndex': i,
        'fragmentCount': fragmentCount,
        'messageBytes': bytes.length,
        'checksum': {'algorithm': 'crc32', 'value': checksum},
        'dataBase64': base64.encode(chunk),
      });
    }
  }

  /// Feed a relay payload. Returns true if it was an rpc-frame(-ack).
  bool acceptPayload(Map<String, dynamic> payload) {
    final type = payload['zcode_type'];
    if (type == 'rpc-frame-ack') return true;
    if (type != 'rpc-frame') return false;
    if (payload['bridgeSessionId'] != bridgeSessionId) return false;

    final messageSeq = (payload['messageSeq'] as num?)?.toInt();
    final fragmentIndex = (payload['fragmentIndex'] as num?)?.toInt();
    final fragmentCount = (payload['fragmentCount'] as num?)?.toInt();
    final messageBytes = (payload['messageBytes'] as num?)?.toInt();
    final dataBase64 = payload['dataBase64'] as String?;
    final checksum = (payload['checksum'] as Map?)?['value'] as String?;
    if (messageSeq == null ||
        fragmentIndex == null ||
        fragmentCount == null ||
        messageBytes == null ||
        dataBase64 == null) {
      return true;
    }

    final assembly = _assemblies.putIfAbsent(
      messageSeq,
      () => _Assembly(fragmentCount, messageBytes, checksum),
    );
    Uint8List? chunk;
    try {
      chunk = base64.decode(dataBase64);
    } catch (_) {
      return true;
    }
    assembly.add(fragmentIndex, chunk);
    if (assembly.isComplete) {
      _assemblies.remove(messageSeq);
      final message = assembly.assemble();
      if (assembly.checksum == null ||
          Crc32.hexOf(message) == assembly.checksum) {
        onLog?.call(
            '[rpc] message $messageSeq assembled (${message.length} bytes)');
        _messageController.add(message);
        sendPayload({
          'zcode_type': 'rpc-frame-ack',
          'bridgeSessionId': bridgeSessionId,
          'ackMessageSeq': messageSeq,
        });
      } else {
        onLog?.call('[rpc] message $messageSeq checksum mismatch');
      }
    }
    return true;
  }

  Future<void> dispose() async {
    _assemblyCleanupTimer?.cancel();
    _assemblies.clear();
    await _messageController.close();
  }
}

class _Assembly {
  final int fragmentCount;
  final int messageBytes;
  final String? checksum;
  final List<Uint8List?> fragments;
  final DateTime createdAt = DateTime.now();
  int received = 0;

  _Assembly(this.fragmentCount, this.messageBytes, this.checksum)
      : fragments = List<Uint8List?>.filled(fragmentCount, null);

  void add(int index, Uint8List data) {
    if (index < 0 || index >= fragmentCount) return;
    if (fragments[index] == null) received += 1;
    fragments[index] = data;
  }

  bool get isComplete => received == fragmentCount;

  Uint8List assemble() {
    final builder = BytesBuilder();
    for (final f in fragments) {
      if (f != null) builder.add(f);
    }
    return builder.toBytes();
  }
}
