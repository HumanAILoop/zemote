class CrashReportSummary {
  final String kind;

  const CrashReportSummary(this.kind);
}

class CrashReportService {
  Future<void> initialize() async {}

  Future<CrashReportSummary?> read() async => null;
}

final crashReports = CrashReportService();
