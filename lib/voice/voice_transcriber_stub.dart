class VoiceTranscriber {
  const VoiceTranscriber({Object? store});

  Future<bool> hasPermission() async => false;
  Future<void> start({void Function(String text)? onPartial}) async =>
      throw UnsupportedError('当前平台的离线语音识别尚未初始化模型运行时');
  Future<String> stop() async => '';
  Future<void> cancel() async {}
  void dispose() {}
}
