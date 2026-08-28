import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/diagnostics_page.dart';
import 'package:zemote/ui/theme.dart';

void main() {
  testWidgets('diagnostics page renders disconnected state', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      home: const DiagnosticsPage(),
    ));

    expect(find.text('诊断中心'), findsOneWidget);
    expect(find.text('连接状态'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('未打开'), findsWidgets);
  });
}
