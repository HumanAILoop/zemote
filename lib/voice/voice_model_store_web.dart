import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_models.dart';
import 'voice_model_events.dart';

class VoiceModelStore {
  static const _enabledKey = 'voice_enabled_model';
  static final _models = <String, Map<String, Uint8List>>{};
  final Map<String, double> progress = {};

  Future<bool> isDownloaded(VoiceModelInfo model) async =>
      _models[model.id]?.keys.toSet().containsAll(model.files) ?? false;

  Future<String?> enabledModelId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_enabledKey);
    if (id == null) return null;
    final model = voiceModels.where((model) => model.id == id).firstOrNull;
    return model != null && await isDownloaded(model) ? id : null;
  }

  Future<void> setEnabled(VoiceModelInfo model) async {
    if (!await isDownloaded(model)) throw StateError('模型尚未下载');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_enabledKey, model.id);
    VoiceModelEvents.notifyChanged();
  }

  Future<void> disable(VoiceModelInfo model) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_enabledKey) == model.id) {
      await prefs.remove(_enabledKey);
      VoiceModelEvents.notifyChanged();
    }
  }

  Future<void> download(VoiceModelInfo model) async {
    if (await isDownloaded(model)) return;
    progress[model.id] = 0;
    final client = http.Client();
    try {
      final response = await client.get(Uri.parse(model.archiveUrl));
      if (response.statusCode != 200) {
        throw StateError('模型下载失败: HTTP ${response.statusCode}');
      }
      final archive = TarDecoder()
          .decodeBytes(BZip2Decoder().decodeBytes(response.bodyBytes));
      final files = <String, Uint8List>{};
      for (final entry in archive.where((entry) => entry.isFile)) {
        final relative = entry.name.replaceFirst('${model.directory}/', '');
        if (model.files.contains(relative)) {
          files[relative] = Uint8List.fromList(entry.content as List<int>);
        }
      }
      _models[model.id] = files;
      progress[model.id] = 1;
      if (!await isDownloaded(model)) {
        _models.remove(model.id);
        throw StateError('模型文件不完整');
      }
      VoiceModelEvents.notifyChanged();
    } finally {
      client.close();
    }
  }

  Future<void> delete(VoiceModelInfo model) async {
    await disable(model);
    _models.remove(model.id);
    VoiceModelEvents.notifyChanged();
  }

  Map<String, Uint8List>? filesFor(String id) => _models[id];
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
