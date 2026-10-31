import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('app displays a synthetic host report as unverified', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    for (var i = 0; i < 60 && find.text('Connect').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.enterText(
      find.byType(TextField).first,
      Platform.environment['MONASTACK_TEST_AN']!,
    );
    await tester.tap(find.text('Connect'));
    for (
      var i = 0;
      i < 80 && find.textContaining('Chat · Connected').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('Chat · Connected'), findsOneWidget);
    await tester.tap(find.text('Workspace tools'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Agent proposals').last);
    for (
      var i = 0;
      i < 60 &&
          find.text('Synthetic app host report').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Synthetic app host report'), findsOneWidget);
    expect(find.textContaining('not independently verified'), findsOneWidget);
  });
}
