import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/voice/voice_models.dart';

void main() {
  test('voice model catalog contains multiple language options', () {
    expect(voiceModels.length, greaterThanOrEqualTo(6));
    expect(voiceModelById('sensevoice').languages, contains('中'));
    expect(voiceModelById('whisper-tiny-en').languages, contains('英语'));
    expect(voiceModelById('qwen3-asr-06b').languages, contains('其他'));
    expect(voiceModelById('fun-asr-nano').description, contains('中文'));
  });

  test('model files are relative to their declared archive directory', () {
    for (final model in voiceModels) {
      expect(model.directory, isNotEmpty);
      expect(model.files, isNotEmpty);
      expect(model.files, contains(model.mainFile));
    }
  });
}
