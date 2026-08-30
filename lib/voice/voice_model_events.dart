class VoiceModelEvents {
  static final changed = _VoiceStoreChangeNotifier();

  static void notifyChanged() => changed.notifyListeners();
}

class _VoiceStoreChangeNotifier {
  final _listeners = <void Function()>[];

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void notifyListeners() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }
}
