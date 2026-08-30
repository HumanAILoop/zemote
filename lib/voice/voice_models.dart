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
];

VoiceModelInfo voiceModelById(String id) =>
    voiceModels.firstWhere((model) => model.id == id);
