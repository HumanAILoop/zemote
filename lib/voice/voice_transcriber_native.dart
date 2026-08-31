import 'dart:async';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'voice_model_store_native.dart';
import 'voice_models.dart';

class VoiceTranscriber {
  final VoiceModelStore store;
  final AudioRecorder _recorder = AudioRecorder();
  final _samples = <double>[];
  StreamSubscription<Uint8List>? _audioSub;
  Timer? _previewTimer;
  sherpa.OfflineRecognizer? _recognizer;
  VoiceModelInfo? _model;
  bool _decoding = false;
  void Function(String text)? _onPartial;

  VoiceTranscriber({VoiceModelStore? store})
      : store = store ?? VoiceModelStore();

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start({void Function(String text)? onPartial}) async {
    final id = await store.enabledModelId();
    if (id == null) throw StateError('请先在设置中下载并启用语音模型');
    if (!await hasPermission()) throw StateError('没有麦克风权限');
    _model = voiceModelById(id);
    _onPartial = onPartial;
    _samples.clear();
    await sherpa.initBindingsAsync();
    final dir = await store.directory(_model!);
    _recognizer = sherpa.OfflineRecognizer(_config(_model!, dir.path));
    final audio = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    ));
    _audioSub = audio.listen(_acceptBytes);
    _previewTimer = Timer.periodic(
        const Duration(milliseconds: 1400), (_) => _emitPreview());
  }

  void _acceptBytes(Uint8List bytes) {
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final value = bytes[i] | (bytes[i + 1] << 8);
      final signed = value >= 0x8000 ? value - 0x10000 : value;
      _samples.add(signed / 32768.0);
    }
  }

  Future<void> _emitPreview() async {
    if (_samples.length < 8000 || _decoding) return;
    final text = _decode(Float32List.fromList(_samples));
    if (text.isNotEmpty) _onPartial?.call(text);
  }

  String _decode(Float32List samples) {
    final recognizer = _recognizer;
    if (recognizer == null || _decoding) return '';
    _decoding = true;
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: 16000);
      recognizer.decode(stream);
      return recognizer.getResult(stream).text.trim();
    } finally {
      stream.free();
      _decoding = false;
    }
  }

  Future<String> stop() async {
    _previewTimer?.cancel();
    await _recorder.stop();
    await _audioSub?.cancel();
    final text = _decode(Float32List.fromList(_samples));
    _resetRuntime();
    return text;
  }

  Future<void> cancel() async {
    _previewTimer?.cancel();
    await _recorder.cancel();
    await _audioSub?.cancel();
    _resetRuntime();
  }

  void _resetRuntime() {
    _recognizer?.free();
    _recognizer = null;
    _samples.clear();
    _onPartial = null;
  }

  void dispose() {
    _previewTimer?.cancel();
    _audioSub?.cancel();
    _recognizer?.free();
    _recorder.dispose();
  }

  sherpa.OfflineRecognizerConfig _config(VoiceModelInfo model, String dir) {
    final base = sherpa.OfflineModelConfig(
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
      qwen3Asr: model.id == 'qwen3-asr-06b'
          ? sherpa.OfflineQwen3AsrModelConfig(
              convFrontend: p.join(dir, 'conv_frontend.onnx'),
              encoder: p.join(dir, 'encoder.int8.onnx'),
              decoder: p.join(dir, 'decoder.int8.onnx'),
              tokenizer: p.join(dir, 'tokenizer', 'tokenizer.json'))
          : const sherpa.OfflineQwen3AsrModelConfig(),
      funasrNano: model.id == 'fun-asr-nano'
          ? sherpa.OfflineFunAsrNanoModelConfig(
              encoderAdaptor: p.join(dir, 'encoder_adaptor.int8.onnx'),
              llm: p.join(dir, 'llm.int8.onnx'),
              embedding: p.join(dir, 'embedding.int8.onnx'),
              tokenizer: p.join(dir, 'Qwen3-0.6B', 'tokenizer.json'))
          : const sherpa.OfflineFunAsrNanoModelConfig(),
    );
    return sherpa.OfflineRecognizerConfig(model: base);
  }
}
