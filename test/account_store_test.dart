import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zemote/state/account_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('exportJson round-trips through importJson', () async {
    final store = AccountStore();
    final url =
        'https://zcode.z.ai/remote/v4?sid=abc&hash=def&t=123&name=桌面1';
    await store.addUrl(url);
    final exported = store.exportJson();
    final parsed = jsonDecode(exported) as Map<String, dynamic>;
    expect(parsed['accounts'], isA<List>());
    expect((parsed['accounts'] as List), hasLength(1));

    final store2 = AccountStore();
    final count = await store2.importJson(exported);
    expect(count, 1);
    expect(store2.accounts, hasLength(1));
    expect(store2.accounts.first.url, url);
  });

  test('importJson skips invalid URLs and duplicates', () async {
    final store = AccountStore();
    await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=abc&hash=def&t=123&name=桌面1');
    final count = await store.importJson(jsonEncode({
      'app': 'zemote',
      'accounts': [
        {'id': 'x1', 'label': 'dup', 'url': 'https://zcode.z.ai/remote/v4?sid=abc&hash=def&t=123&name=桌面1'},
        {'id': 'x2', 'label': 'bad', 'url': 'not a url'},
        {'id': 'x3', 'label': 'new', 'url': 'https://zcode.z.ai/remote/v4?sid=zzz&hash=hhh&t=999&name=桌面2'},
      ],
    }));
    expect(count, 1);
    expect(store.accounts, hasLength(2));
  });

  test('importJson rejects non-device files', () async {
    final store = AccountStore();
    await expectLater(
      store.importJson('{"foo": 1}'),
      throwsFormatException,
    );
  });
}
