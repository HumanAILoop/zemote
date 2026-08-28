import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:zemote/ui/settings_page.dart';

void main() {
  testWidgets('settings page shows beta update switch', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsPage(onDisconnect: () {}),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('接收 Beta 更新'), findsOneWidget);
    expect(find.byType(Switch), findsAtLeastNWidgets(1));
    expect(find.text('当前通道：稳定版（推荐）'), findsOneWidget);
  });
}
