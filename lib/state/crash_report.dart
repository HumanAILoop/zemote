import 'dart:convert';
import 'dart:io';

import '../update/app_version.dart';

class CrashReport {
  final String kind;
  final String error;
  final String stack;
  final String occurredAt;

  const CrashReport({
    required this.kind,
    required this.error,
    required this.stack,
    required this.occurredAt,
  });

  Map<String, dynamic> toJson() => {
        'kind': kind,
        'error': _sanitize(error),
        'stack': _sanitize(stack),
        'occurredAt': occurredAt,
        'version': appVersion,
      };

  factory CrashReport.fromJson(Map<String, dynamic> json) => CrashReport(
        kind: '${json['kind'] ?? 'unknown'}',
        error: '${json['error'] ?? ''}',
        stack: '${json['stack'] ?? ''}',
        occurredAt: '${json['occurredAt'] ?? ''}',
      );

  static String _sanitize(String value) {
    final sanitized = value.replaceAll(
      RegExp(r'([?&](?:sid|hash|t|mid)=)[^&\s]+', caseSensitive: false),
      r'\1<redacted>',
    );
    return sanitized.length > 12000
        ? sanitized.substring(0, 12000)
        : sanitized;
  }
}

class CrashReportStore {
  final File file;

  const CrashReportStore(this.file);

  Future<CrashReport?> read() async {
    try {
      if (!await file.exists()) return null;
      final value = jsonDecode(await file.readAsString());
      return value is Map
          ? CrashReport.fromJson(value.cast<String, dynamic>())
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String kind, Object error, StackTrace stack) async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(CrashReport(
        kind: kind,
        error: '$error',
        stack: '$stack',
        occurredAt: DateTime.now().toIso8601String(),
      ).toJson()));
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
