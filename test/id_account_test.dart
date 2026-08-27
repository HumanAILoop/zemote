import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zemote/protocol/id.dart';
import 'package:zemote/state/account_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('generateUuid', () {
    test('produces a non-empty string', () {
      final uuid = generateUuid();
      expect(uuid, isNotEmpty);
    });

    test('contains hyphens at expected positions', () {
      final uuid = generateUuid();
      expect(uuid[8], '-');
      expect(uuid[13], '-');
      expect(uuid[18], '-');
      expect(uuid[23], '-');
    });

    test('is 36 characters (8-4-4-4-12)', () {
      final uuid = generateUuid();
      expect(uuid.length, 36);
    });

    test('version nibble is 4', () {
      final uuid = generateUuid();
      expect(uuid[14], '4');
    });

    test('variant is one of 8/9/a/b', () {
      final uuid = generateUuid();
      expect('89ab'.contains(uuid[19]), isTrue);
    });

    test('produces unique values', () {
      final ids = <String>{};
      for (var i = 0; i < 100; i++) {
        ids.add(generateUuid());
      }
      expect(ids, hasLength(100));
    });

    test('generateRequestId uses prefix', () {
      final id = generateRequestId('test');
      expect(id, startsWith('test-'));
      expect(id.length, greaterThan('test-'.length + 20));
    });
  });

  group('Account model', () {
    test('fromUrl constructs account from valid URL', () {
      final account = Account.fromUrl(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&name=Test',
      );
      expect(account.label, 'Test');
      expect(account.params, isNotNull);
    });

    test('fromUrl uses host as label when no name set', () {
      final account = Account.fromUrl(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1',
      );
      expect(account.label, 'zcode.z.ai');
    });

    test('fromUrl defaults label for rejected insecure URL', () {
      final account = Account.fromUrl(
        'http:///remote/v4?sid=s&hash=h&t=1',
      );
      expect(account.label, '未命名设备');
      expect(account.params, isNull);
    });

    test('fromUrl returns Account with null params for invalid URL', () {
      final account = Account.fromUrl('not-a-url');
      expect(account.params, isNull);
    });

    test('unique id per creation', () {
      final a1 = Account.fromUrl(
          'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&name=A');
      final a2 = Account.fromUrl(
          'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&name=B');
      expect(a1.id, isNot(equals(a2.id)));
    });
  });

  group('AccountStore', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('initial state is empty', () {
      final store = AccountStore();
      expect(store.accounts, isEmpty);
      expect(store.loaded, isFalse);
    });

    test('addUrl returns Account', () async {
      final store = AccountStore();
      final account = await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&name=MyDevice',
      );
      expect(account.label, 'MyDevice');
      expect(store.accounts, hasLength(1));
    });

    test('rename updates label', () async {
      final store = AccountStore();
      final account = await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&name=Old',
      );
      await store.rename(account.id, 'NewName');
      expect(store.accounts.first.label, 'NewName');
    });

    test('remove deletes account', () async {
      final store = AccountStore();
      final account = await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1&name=Device',
      );
      expect(store.accounts, hasLength(1));
      await store.remove(account.id);
      expect(store.accounts, isEmpty);
    });

    test('touch updates lastUsedAt', () async {
      final store = AccountStore();
      final account = await store.addUrl(
        'https://zcode.z.ai/remote/v4?sid=s&hash=h&t=1',
      );
      final before = account.lastUsedAt;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await store.touch(account.id);
      final after = store.accounts.first.lastUsedAt;
      // touch updates the timestamp, so the store's version should be newer
      expect(after != null, isTrue);
      if (before != null) {
        expect(after! >= before, isTrue);
      }
    });
  });
}
