import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/protocol/channel_client.dart';
import 'package:zemote/protocol/ipc_codec.dart';

void main() {
  late List<Uint8List> sent;

  List<int> initHeader() {
    final writer = ValueWriter();
    encodeValue(writer, [ChannelClient.resInitialize, 0]);
    return writer.toBytes();
  }

  List<int> responseHeader(int id) {
    final writer = ValueWriter();
    encodeValue(writer, [ChannelClient.resPromiseSuccess, id]);
    return writer.toBytes();
  }

  Uint8List successFrame(int id, Object? data) {
    final header = responseHeader(id);
    final bodyWriter = ValueWriter();
    encodeValue(bodyWriter, data);
    return Uint8List.fromList([...header, ...bodyWriter.toBytes()]);
  }

  setUp(() => sent = []);

  test('initialize frame completes ready', () async {
    final client = ChannelClient(sendBody: sent.add);
    client.handleMessage(Uint8List.fromList(initHeader()));

    await expectLater(client.ready, completes);
    client.dispose();
  });

  test('single-element initialize frame completes ready', () async {
    final client = ChannelClient(sendBody: sent.add);
    final writer = ValueWriter();
    encodeValue(writer, [ChannelClient.resInitialize]);

    client.handleMessage(writer.toBytes());

    await expectLater(client.ready, completes);
    client.dispose();
  });

  test('call returns response data', () async {
    final client = ChannelClient(sendBody: sent.add);
    client.handleMessage(Uint8List.fromList(initHeader()));

    final future = client.call('zcode-task', 'listTasks', []);
    await client.ready;
    await Future<void>.delayed(Duration.zero);

    final reader = ValueReader(sent.last);
    final header = decodeValue(reader) as List;
    final id = header[1] as int;
    client.handleMessage(successFrame(id, {'result': 'ok'}));

    expect(await future, {'result': 'ok'});
    client.dispose();
  });

  test('call error returns ChannelRpcError', () async {
    final client = ChannelClient(sendBody: sent.add);
    client.handleMessage(Uint8List.fromList(initHeader()));

    final future = client.call('gold', 'validate', []);
    await client.ready;
    await Future<void>.delayed(Duration.zero);

    final reader = ValueReader(sent.last);
    final header = decodeValue(reader) as List;
    final id = header[1] as int;
    final writer = ValueWriter();
    encodeValue(writer, [ChannelClient.resPromiseError, id]);
    encodeValue(writer, {'message': 'bad request'});
    client.handleMessage(writer.toBytes());

    expect(future, throwsA(isA<ChannelRpcError>()));
    client.dispose();
  });

  test('addEventListener fires on event', () async {
    final events = <dynamic>[];
    final client = ChannelClient(sendBody: sent.add);
    client.handleMessage(Uint8List.fromList(initHeader()));

    client.addEventListener(
      'zcode-agent',
      'onDynamicConversationFrame',
      events.add,
    );
    await client.ready;
    await Future<void>.delayed(Duration.zero);

    final reader = ValueReader(sent.last);
    final header = decodeValue(reader) as List;
    final id = header[1] as int;
    final writer = ValueWriter();
    encodeValue(writer, [ChannelClient.resEventFire, id]);
    encodeValue(writer, {'frame': 'hello'});
    client.handleMessage(writer.toBytes());

    expect(events, [
      {'frame': 'hello'},
    ]);
    client.dispose();
  });

  test('malformed header is ignored without throwing', () {
    final client = ChannelClient(sendBody: sent.add);
    final writer = ValueWriter();
    encodeValue(writer, [ChannelClient.resPromiseSuccess]);

    expect(() => client.handleMessage(writer.toBytes()), returnsNormally);
    client.dispose();
  });
}
