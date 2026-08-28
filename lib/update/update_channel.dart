import 'package:shared_preferences/shared_preferences.dart';

class UpdateChannelSettings {
  static const _betaKey = 'zemote_receive_beta_updates';

  bool receiveBetaUpdates = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    receiveBetaUpdates = prefs.getBool(_betaKey) ?? false;
  }

  Future<void> setReceiveBetaUpdates(bool value) async {
    receiveBetaUpdates = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_betaKey, value);
  }
}

final updateChannelSettings = UpdateChannelSettings();
