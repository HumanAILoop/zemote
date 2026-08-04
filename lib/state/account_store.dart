import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../protocol/connection_params.dart';
import '../protocol/id.dart';

class Account {
  final String id;
  String label;
  final String url;
  final int addedAt;
  int? lastUsedAt;

  Account({
    required this.id,
    required this.label,
    required this.url,
    required this.addedAt,
    this.lastUsedAt,
  });

  factory Account.fromUrl(String url) {
    final params = ZemoteConnectionParams.parse(url);
    final label = params?.deviceName ??
        (params != null ? params.source.host : '未命名设备');
    return Account(
      id: generateUuid(),
      label: label,
      url: url,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
  }

  ZemoteConnectionParams? get params => ZemoteConnectionParams.parse(url);

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'url': url,
        'addedAt': addedAt,
        if (lastUsedAt != null) 'lastUsedAt': lastUsedAt,
      };

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: json['id'] as String? ?? generateUuid(),
        label: json['label'] as String? ?? '未命名设备',
        url: json['url'] as String? ?? '',
        addedAt: (json['addedAt'] as num?)?.toInt() ?? 0,
        lastUsedAt: (json['lastUsedAt'] as num?)?.toInt(),
      );
}

/// Multi-account store persisted in SharedPreferences.
class AccountStore extends ChangeNotifier {
  static const _prefsKey = 'zemote_accounts_v1';

  final List<Account> _accounts = [];
  List<Account> get accounts => List.unmodifiable(_accounts);

  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    _accounts.clear();
    if (raw != null) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final item in list) {
            if (item is Map) {
              final account =
                  Account.fromJson(item.cast<String, dynamic>());
              if (account.url.isNotEmpty) _accounts.add(account);
            }
          }
        }
      } catch (_) {}
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_accounts.map((a) => a.toJson()).toList()),
    );
  }

  Future<Account> addUrl(String url, {String? label}) async {
    final account = Account.fromUrl(url);
    if (label != null && label.trim().isNotEmpty) {
      account.label = label.trim();
    }
    _accounts.add(account);
    await _save();
    notifyListeners();
    return account;
  }

  Future<void> remove(String id) async {
    _accounts.removeWhere((a) => a.id == id);
    await _save();
    notifyListeners();
  }

  Future<void> rename(String id, String label) async {
    final account = _accounts.where((a) => a.id == id).firstOrNull;
    if (account == null) return;
    account.label = label.trim().isEmpty ? account.label : label.trim();
    await _save();
    notifyListeners();
  }

  Future<void> touch(String id) async {
    final account = _accounts.where((a) => a.id == id).firstOrNull;
    if (account == null) return;
    account.lastUsedAt = DateTime.now().millisecondsSinceEpoch;
    await _save();
    notifyListeners();
  }
}
