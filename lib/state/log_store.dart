import 'dart:collection';

import 'package:flutter/foundation.dart';

/// Global in-memory protocol log.
class LogStore extends ChangeNotifier {
  static final LogStore instance = LogStore._();

  LogStore._();

  static const maxEntries = 2000;

  final ListQueue<String> _entries = ListQueue();

  List<String> get entries => List.unmodifiable(_entries);

  void add(String line) {
    final ts = DateTime.now().toString().substring(11, 23);
    _entries.addLast('$ts $line');
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}

void log(String line) => LogStore.instance.add(line);
