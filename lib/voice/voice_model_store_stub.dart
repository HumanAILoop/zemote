import 'voice_models.dart';

class VoiceModelStore {
  final Map<String, double> progress = {};

  Future<bool> isDownloaded(VoiceModelInfo model) async => false;
  Future<String?> enabledModelId() async => null;
  Future<void> setEnabled(VoiceModelInfo model) async =>
      throw UnsupportedError('当前平台暂不支持离线语音模型');
  Future<void> disable(VoiceModelInfo model) async {}
  Future<void> download(VoiceModelInfo model) async =>
      throw UnsupportedError('当前平台暂不支持离线语音模型');
  Future<void> delete(VoiceModelInfo model) async {}
}
