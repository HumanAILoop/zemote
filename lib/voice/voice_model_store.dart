export 'voice_model_store_stub.dart'
    if (dart.library.io) 'voice_model_store_native.dart'
    if (dart.library.js_interop) 'voice_model_store_web.dart';
