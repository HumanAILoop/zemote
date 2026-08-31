import 'dart:async';
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
  Timer? _previewTimer;
  sherpa.OfflineRecognizer? _recognizer;
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
    final files = store.filesFor(_model!.id);
    if (files == null) throw StateError('当前页面没有可用模型缓存');
    _prepareFiles(_model!, files);
    _recognizer = sherpa.OfflineRecognizer(_config(_model!));
    _stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    ));
    _stream!.listen(_acceptBytes);
    _previewTimer = Timer.periodic(
        const Duration(milliseconds: 1400), (_) => _emitPreview());
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

  void _acceptBytes(Uint8List bytes) {
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final value = bytes[i] | (bytes[i + 1] << 8);
      final signed = value >= 0x8000 ? value - 0x10000 : value;
      _samples.add(signed / 32768.0);
    }
  }

  Future<String> stop() async {
    _previewTimer?.cancel();
    await _recorder.stop();
    final text = _decode(Float32List.fromList(_samples));
    _resetRuntime();
    return text;
  }

  Future<void> cancel() async {
    await _recorder.cancel();
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
    _recognizer?.free();
    _recorder.dispose();
  }

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
      qwen3Asr: model.id == 'qwen3-asr-06b'
          ? sherpa.OfflineQwen3AsrModelConfig(
              convFrontend: '$dir/conv_frontend.onnx',
              encoder: '$dir/encoder.int8.onnx',
              decoder: '$dir/decoder.int8.onnx',
              tokenizer: '$dir/tokenizer/tokenizer.json')
          : const sherpa.OfflineQwen3AsrModelConfig(),
      funasrNano: model.id == 'fun-asr-nano'
          ? sherpa.OfflineFunAsrNanoModelConfig(
              encoderAdaptor: '$dir/encoder_adaptor.int8.onnx',
              llm: '$dir/llm.int8.onnx',
              embedding: '$dir/embedding.int8.onnx',
              tokenizer: '$dir/Qwen3-0.6B/tokenizer.json')
          : const sherpa.OfflineFunAsrNanoModelConfig(),
    );
    return sherpa.OfflineRecognizerConfig(model: base);
  }
}
