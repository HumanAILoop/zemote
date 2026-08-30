import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'voice_model_store_native.dart';
import 'voice_models.dart';

class VoiceTranscriber {
  final VoiceModelStore store;
  final AudioRecorder _recorder = AudioRecorder();
  String? _path;
  VoiceModelInfo? _model;

  VoiceTranscriber({VoiceModelStore? store})
      : store = store ?? VoiceModelStore();

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start() async {
    final id = await store.enabledModelId();
    if (id == null) throw StateError('请先在设置中下载并启用语音模型');
    if (!await hasPermission()) throw StateError('没有麦克风权限');
    _model = voiceModelById(id);
    _path = p.join((await store.directory(_model!)).path, 'recording.wav');
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: _path!,
    );
  }

  Future<String> stop() async {
    final path = await _recorder.stop();
    final model = _model;
    if (path == null || model == null) return '';
    await sherpa.initBindingsAsync();
    final dir = await store.directory(model);
    final recognizer = sherpa.OfflineRecognizer(_config(model, dir.path));
    final stream = recognizer.createStream();
    final wave = sherpa.readWave(path);
    stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
    recognizer.decode(stream);
    final text = recognizer.getResult(stream).text.trim();
    stream.free();
    recognizer.free();
    return text;
  }

  Future<void> cancel() async {
    await _recorder.cancel();
  }

  void dispose() => _recorder.dispose();

  sherpa.OfflineRecognizerConfig _config(VoiceModelInfo model, String dir) {
    final files = sherpa.OfflineModelConfig(
      tokens: model.id == 'whisper-tiny-en'
          ? p.join(dir, 'tiny.en-tokens.txt')
          : p.join(dir, 'tokens.txt'),
      numThreads: 2,
      debug: false,
      modelType: model.id == 'whisper-tiny-en' ? 'whisper' : '',
      senseVoice: model.id == 'sensevoice'
          ? sherpa.OfflineSenseVoiceModelConfig(
              model: p.join(dir, 'model.int8.onnx'), language: 'auto')
          : const sherpa.OfflineSenseVoiceModelConfig(),
      zipformerCtc: model.id == 'zipformer-zh'
          ? sherpa.OfflineZipformerCtcModelConfig(
              model: p.join(dir, 'model.int8.onnx'))
          : const sherpa.OfflineZipformerCtcModelConfig(),
      fireRedAsrCtc: model.id == 'firered-zh-en'
          ? sherpa.OfflineFireRedAsrCtcModelConfig(
              model: p.join(dir, 'model.int8.onnx'))
          : const sherpa.OfflineFireRedAsrCtcModelConfig(),
      whisper: model.id == 'whisper-tiny-en'
          ? sherpa.OfflineWhisperModelConfig(
              encoder: p.join(dir, 'tiny.en-encoder.int8.onnx'),
              decoder: p.join(dir, 'tiny.en-decoder.int8.onnx'))
          : const sherpa.OfflineWhisperModelConfig(),
    );
    return sherpa.OfflineRecognizerConfig(model: files);
  }
}
