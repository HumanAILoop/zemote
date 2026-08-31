class VoiceModelInfo {
  final String id;
  final String name;
  final String description;
  final String languages;
  final String archiveUrl;
  final String directory;
  final String mainFile;
  final List<String> files;

  const VoiceModelInfo({
    required this.id,
    required this.name,
    required this.description,
    required this.languages,
    required this.archiveUrl,
    required this.directory,
    required this.mainFile,
    required this.files,
  });
}

const voiceModels = <VoiceModelInfo>[
  VoiceModelInfo(
    id: 'sensevoice',
    name: 'SenseVoice Small',
    description: '中文、英语、粤语、日语、韩语，综合推荐',
    languages: '中 / 英 / 粤 / 日 / 韩',
    archiveUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2',
    directory: 'sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17',
    mainFile: 'model.int8.onnx',
    files: ['model.int8.onnx', 'tokens.txt'],
  ),
  VoiceModelInfo(
    id: 'zipformer-zh',
    name: 'Zipformer CTC',
    description: '中文准确率优先，适合普通话语音输入',
    languages: '中文',
    archiveUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-zipformer-ctc-zh-int8-2025-07-03.tar.bz2',
    directory: 'sherpa-onnx-zipformer-ctc-zh-int8-2025-07-03',
    mainFile: 'model.int8.onnx',
    files: ['model.int8.onnx', 'tokens.txt'],
  ),
  VoiceModelInfo(
    id: 'firered-zh-en',
    name: 'FireRed ASR',
    description: '中文和英语，适合中英混合输入',
    languages: '中 / 英',
    archiveUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25.tar.bz2',
    directory: 'sherpa-onnx-fire-red-asr2-ctc-zh_en-int8-2026-02-25',
    mainFile: 'model.int8.onnx',
    files: ['model.int8.onnx', 'tokens.txt'],
  ),
  VoiceModelInfo(
    id: 'whisper-tiny-en',
    name: 'Whisper Tiny',
    description: '英语轻量模型，资源占用较低',
    languages: '英语',
    archiveUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-tiny.en.tar.bz2',
    directory: 'sherpa-onnx-whisper-tiny.en',
    mainFile: 'tiny.en-encoder.int8.onnx',
    files: [
      'tiny.en-encoder.int8.onnx',
      'tiny.en-decoder.int8.onnx',
      'tiny.en-tokens.txt',
    ],
  ),
  VoiceModelInfo(
    id: 'qwen3-asr-06b',
    name: 'Qwen3-ASR 0.6B',
    description: '多语种和中文方言，准确率优先，资源占用较高',
    languages: '中 / 英 / 粤 / 日 / 韩 / 其他',
    archiveUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2',
    directory: 'sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25',
    mainFile: 'encoder.int8.onnx',
    files: [
      'conv_frontend.onnx',
      'encoder.int8.onnx',
      'decoder.int8.onnx',
      'tokenizer/tokenizer.json',
    ],
  ),
  VoiceModelInfo(
    id: 'fun-asr-nano',
    name: 'Fun-ASR Nano',
    description: '中文、英语、日语，中文场景准确率优先',
    languages: '中 / 英 / 日',
    archiveUrl:
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-funasr-nano-int8-2025-12-30.tar.bz2',
    directory: 'sherpa-onnx-funasr-nano-int8-2025-12-30',
    mainFile: 'llm.int8.onnx',
    files: [
      'encoder_adaptor.int8.onnx',
      'llm.int8.onnx',
      'embedding.int8.onnx',
      'Qwen3-0.6B/tokenizer.json',
    ],
  ),
];

VoiceModelInfo voiceModelById(String id) =>
    voiceModels.firstWhere((model) => model.id == id);
