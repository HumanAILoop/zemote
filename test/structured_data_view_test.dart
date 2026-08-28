import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/structured_data_view.dart';
import 'package:zemote/ui/theme.dart';

void main() {
  testWidgets('structured data renders labels and formatted values',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildLightTheme(),
      home: const Scaffold(
        body: StructuredDataView(data: {
          'title': 'Test task',
          'status': 'running',
          'enabled': true,
          'items': [
            {'title': 'Step one'},
          ],
        }),
      ),
    ));

    expect(find.text('标题'), findsOneWidget);
    expect(find.text('运行中'), findsOneWidget);
    expect(find.text('是'), findsOneWidget);
    expect(find.textContaining('项目'), findsOneWidget);
  });

  testWidgets('structured data keeps nested collections behind headings',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      home: const Scaffold(
        body: StructuredDataView(data: {
          'history': [
            {'status': 'completed', 'updatedAt': 1787870000000},
          ],
        }),
      ),
    ));

    expect(find.textContaining('历史'), findsOneWidget);
    await tester.tap(find.text('第 1 项'));
    await tester.pumpAndSettle();
    expect(find.text('已完成'), findsOneWidget);
    expect(find.textContaining('2026-'), findsOneWidget);
  });
}
