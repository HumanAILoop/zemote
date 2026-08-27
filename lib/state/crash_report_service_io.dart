import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'crash_report.dart';

class CrashReportService {
  CrashReportStore? _store;

  Future<void> initialize() async {
    final dir = await getApplicationSupportDirectory();
    final store = CrashReportStore(File('${dir.path}/last_crash.json'));
    _store = store;
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      store.write('flutter', details.exception,
          details.stack ?? StackTrace.current);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      store.write('async', error, stack);
      return true;
    };
  }

  Future<CrashReport?> read() => _store?.read() ?? Future.value(null);
}

final crashReports = CrashReportService();
