import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'voice_model_store_web.dart';
import 'voice_models.dart';

class VoiceTranscriber {
  final VoiceModelStore store;
  final AudioRecorder _recorder = AudioRecorder();
  final _samples = <double>[];
  Stream<Uint8List>? _stream;
  VoiceModelInfo? _model;

  VoiceTranscriber({VoiceModelStore? store})
      : store = store ?? VoiceModelStore();

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start() async {
    final id = await store.enabledModelId();
    if (id == null) throw StateError('请先在设置中下载并启用语音模型');
    if (!await hasPermission()) throw StateError('没有麦克风权限');
    _model = voiceModelById(id);
    _samples.clear();
    _stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    ));
    _stream!.listen(_acceptBytes);
  }

  void _acceptBytes(Uint8List bytes) {
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final value = bytes[i] | (bytes[i + 1] << 8);
      final signed = value >= 0x8000 ? value - 0x10000 : value;
      _samples.add(signed / 32768.0);
    }
  }

  Future<String> stop() async {
    await _recorder.stop();
    final model = _model;
    final files = model == null ? null : store.filesFor(model.id);
    if (model == null || files == null || _samples.isEmpty) return '';
    await sherpa.initBindingsAsync();
    _prepareFiles(model, files);
    final recognizer = sherpa.OfflineRecognizer(_config(model));
    final stream = recognizer.createStream();
    try {
      stream.acceptWaveform(
        samples: Float32List.fromList(_samples),
        sampleRate: 16000,
      );
      recognizer.decode(stream);
      return recognizer.getResult(stream).text.trim();
    } finally {
      stream.free();
      recognizer.free();
      _samples.clear();
    }
  }

  Future<void> cancel() async {
    await _recorder.cancel();
    _samples.clear();
  }

  void dispose() => _recorder.dispose();

  void _prepareFiles(VoiceModelInfo model, Map<String, Uint8List> files) {
    final module = globalContext.getProperty('Module'.toJS) as JSObject;
    final fs = module.getProperty('FS'.toJS) as JSObject;
    final mkdir = fs.getProperty('mkdir'.toJS) as JSFunction;
    try {
      mkdir.callAsFunction(fs, '/models'.toJS);
    } catch (_) {}
    try {
      mkdir.callAsFunction(fs, '/models/${model.id}'.toJS);
    } catch (_) {}
    final writeFile = fs.getProperty('writeFile'.toJS) as JSFunction;
    for (final entry in files.entries) {
      writeFile.callAsFunction(
          fs, '/models/${model.id}/${entry.key}'.toJS, entry.value.toJS);
    }
  }

  sherpa.OfflineRecognizerConfig _config(VoiceModelInfo model) {
    final dir = '/models/${model.id}';
    final base = sherpa.OfflineModelConfig(
      tokens:
          '$dir/${model.id == 'whisper-tiny-en' ? 'tiny.en-tokens.txt' : 'tokens.txt'}',
      numThreads: 1,
      debug: false,
      modelType: model.id == 'whisper-tiny-en' ? 'whisper' : '',
      senseVoice: model.id == 'sensevoice'
          ? sherpa.OfflineSenseVoiceModelConfig(
              model: '$dir/model.int8.onnx', language: 'auto')
          : const sherpa.OfflineSenseVoiceModelConfig(),
      zipformerCtc: model.id == 'zipformer-zh'
          ? sherpa.OfflineZipformerCtcModelConfig(model: '$dir/model.int8.onnx')
          : const sherpa.OfflineZipformerCtcModelConfig(),
      fireRedAsrCtc: model.id == 'firered-zh-en'
          ? sherpa.OfflineFireRedAsrCtcModelConfig(
              model: '$dir/model.int8.onnx')
          : const sherpa.OfflineFireRedAsrCtcModelConfig(),
      whisper: model.id == 'whisper-tiny-en'
          ? sherpa.OfflineWhisperModelConfig(
              encoder: '$dir/tiny.en-encoder.int8.onnx',
              decoder: '$dir/tiny.en-decoder.int8.onnx')
          : const sherpa.OfflineWhisperModelConfig(),
    );
    return sherpa.OfflineRecognizerConfig(model: base);
  }
}
