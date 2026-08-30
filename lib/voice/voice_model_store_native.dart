import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_models.dart';
import 'voice_model_events.dart';

class VoiceModelStore {
  static const _enabledKey = 'voice_enabled_model';
  final Map<String, double> progress = {};

  Future<Directory> _root() async {
    final dir = await getApplicationSupportDirectory();
    final root = Directory(p.join(dir.path, 'voice-models'));
    await root.create(recursive: true);
    return root;
  }

  Future<Directory> directory(VoiceModelInfo model) async =>
      Directory(p.join((await _root()).path, model.id));

  Future<bool> isDownloaded(VoiceModelInfo model) async {
    final dir = await directory(model);
    for (final file in model.files) {
      if (!await File(p.join(dir.path, file)).exists()) return false;
    }
    return true;
  }

  Future<String?> enabledModelId() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_enabledKey);
    if (id == null || !voiceModels.any((model) => model.id == id)) return null;
    return await isDownloaded(voiceModelById(id)) ? id : null;
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
      final request = http.Request('GET', Uri.parse(model.archiveUrl));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw StateError('模型下载失败: HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        if (response.contentLength != null && response.contentLength! > 0) {
          progress[model.id] = bytes.length / response.contentLength!;
        }
      }
      final tarBytes = BZip2Decoder().decodeBytes(bytes);
      final archive = TarDecoder().decodeBytes(tarBytes);
      final dir = await directory(model);
      await dir.create(recursive: true);
      for (final file in archive.where((entry) => entry.isFile)) {
        final relative = file.name.replaceFirst('${model.directory}/', '');
        if (!model.files.contains(relative)) continue;
        final output = File(p.join(dir.path, relative));
        await output.parent.create(recursive: true);
        await output.writeAsBytes(file.content as List<int>);
      }
      if (!await isDownloaded(model)) {
        await delete(model);
        throw StateError('模型文件不完整');
      }
      progress[model.id] = 1;
      VoiceModelEvents.notifyChanged();
    } finally {
      client.close();
    }
  }

  Future<void> delete(VoiceModelInfo model) async {
    await disable(model);
    final dir = await directory(model);
    if (await dir.exists()) await dir.delete(recursive: true);
    VoiceModelEvents.notifyChanged();
  }
}
