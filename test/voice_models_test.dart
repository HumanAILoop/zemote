import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/voice/voice_models.dart';

void main() {
  test('voice model catalog contains multiple language options', () {
    expect(voiceModels.length, greaterThanOrEqualTo(4));
    expect(voiceModelById('sensevoice').languages, contains('中'));
    expect(voiceModelById('whisper-tiny-en').languages, contains('英语'));
  });

  test('model files are relative to their declared archive directory', () {
    for (final model in voiceModels) {
      expect(model.directory, isNotEmpty);
      expect(model.files, isNotEmpty);
      expect(model.files, contains(model.mainFile));
    }
  });
}
