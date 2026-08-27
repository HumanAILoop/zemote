import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zemote/ui/theme.dart';

double _luminanceDifference(Color a, Color b) =>
    (a.computeLuminance() - b.computeLuminance()).abs();

void main() {
  testWidgets('chat panels have readable light-theme contrast', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      theme: buildLightTheme(),
      home: Builder(builder: (value) {
        context = value;
        return const SizedBox();
      }),
    ));

    expect(
      _luminanceDifference(ZInk.solid(context), ZInk.reasoningPanel(context)),
      greaterThan(0.45),
    );
    expect(
      _luminanceDifference(ZInk.solid(context), ZInk.panel(context)),
      greaterThan(0.45),
    );
  });

  testWidgets('chat panels have readable dark-theme contrast', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(
      theme: buildDarkTheme(),
      home: Builder(builder: (value) {
        context = value;
        return const SizedBox();
      }),
    ));

    expect(
      _luminanceDifference(ZInk.solid(context), ZInk.reasoningPanel(context)),
      greaterThan(0.45),
    );
    expect(
      _luminanceDifference(ZInk.solid(context), ZInk.panel(context)),
      greaterThan(0.45),
    );
  });
}
