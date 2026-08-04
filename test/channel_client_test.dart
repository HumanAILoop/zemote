import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/protocol/channel_client.dart';
import 'package:zemote/protocol/ipc_codec.dart';

void main() {
  late List<Uint8List> sent;

  /// Builds a minimal Initialize frame header: [resInitialize, 0]
  List<int> initHeader() {
    final w = ValueWriter();
    encodeValue(w, [ChannelClient.resInitialize, 0]);
    return w.toBytes();
  }

  /// Builds a promise-success frame: [resPromiseSuccess, id] + data value
  List<int> responseHeader(int id) {
    final w = ValueWriter();
    encodeValue(w, [ChannelClient.resPromiseSuccess, id]);
    return w.toBytes();
  }

  /// Encodes a value and wraps in promise-success frame
  Uint8List successFrame(int id, Object? data) {
    final header = responseHeader(id);
    final bodyW = ValueWriter();
    encodeValue(bodyW, data);
    final body = bodyW.toBytes();
    return Uint8List.fromList([...header, ...body]);
  }

  setUp(() {
    sent = [];
  });

  test('initialize frame completes ready', () async {
    final client = ChannelClient(sendBody: (b) => sent.add(b));
    client.handleMessage(Uint8List.fromList(initHeader()));

    await expectLater(client.ready, completes);
    client.dispose();
  });

  test('call returns response data', () async {
    final client = ChannelClient(sendBody: (b) => sent.add(b));
    client.handleMessage(Uint8List.fromList(initHeader()));

    final future = client.call('zcode-task', 'listTasks', []);

    // The request should have been sent after ready resolves
    await client.ready;
    // Allow the microtask to fire the send
    await Future.microtask(() {});
    final callSent = sent.where((b) => b.isNotEmpty).toList();
    expect(callSent, isNotEmpty);

    // Extract requestId from sent body
    final reader =
        ValueReader(callSent.isEmpty ? Uint8List(0) : callSent.last);
    final header = decodeValue(reader) as List;
    final id = header[1] as int;

    // Feed response
    client.handleMessage(successFrame(id, {'result': 'ok'}));

    final result = await future;
    expect(result, {'result': 'ok'});
    client.dispose();
  });

  test('call error returns ChannelRpcError', () async {
    final client = ChannelClient(sendBody: (b) => sent.add(b));
    client.handleMessage(Uint8List.fromList(initHeader()));

    final future = client.call('gold', 'validate', []);
    await client.ready;
    await Future.microtask(() {});

    final callSent = sent.where((b) => b.isNotEmpty).toList();
    final reader = ValueReader(callSent.last);
    final header = decodeValue(reader) as List;
    final id = header[1] as int;

    // Feed resPromiseError
    final errW = ValueWriter();
    encodeValue(errW, [ChannelClient.resPromiseError, id]);
    encodeValue(errW, {'message': 'bad request'});
    final errBody = errW.toBytes();
    client.handleMessage(errBody);

    expect(future, throwsA(isA<ChannelRpcError>()));
    client.dispose();
  });

  test('addEventListener fires on event', () async {
    final events = <dynamic>[];
    final client = ChannelClient(sendBody: (b) => sent.add(b));
    client.handleMessage(Uint8List.fromList(initHeader()));

    client.addEventListener('zcode-agent', 'onDynamicConversationFrame',
        (e) => events.add(e));

    await client.ready;
    await Future.microtask(() {});

    final listenSent = sent.where((b) => b.isNotEmpty).toList();
    final reader = ValueReader(listenSent.last);
    final header = decodeValue(reader) as List;
    final id = header[1] as int;

    // Feed resEventFire
    final fireW = ValueWriter();
    encodeValue(fireW, [ChannelClient.resEventFire, id]);
    encodeValue(fireW, {'frame': 'hello'});
    client.handleMessage(fireW.toBytes());

    expect(events, hasLength(1));
    expect(events[0], {'frame': 'hello'});
    client.dispose();
  });
}
