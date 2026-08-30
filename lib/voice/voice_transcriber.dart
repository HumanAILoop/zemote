export 'voice_transcriber_stub.dart'
    if (dart.library.io) 'voice_transcriber_native.dart'
    if (dart.library.js_interop) 'voice_transcriber_web.dart';
