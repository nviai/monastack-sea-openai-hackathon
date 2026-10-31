import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('show posted activity balance through the app', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    for (var i = 0; i < 60 && find.text('Connect').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.enterText(
      find.byType(TextField).first,
      Platform.environment['MONASTACK_TEST_TOKEN']!,
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
    await tester.ensureVisible(find.text('Journal entries').last);
    await tester.tap(find.text('Journal entries').last);
    for (
      var i = 0;
      i < 50 && find.text('View activity balance').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('View activity balance'));
    for (
      var i = 0;
      i < 50 && find.text('Posted activity balance').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('VND · Debit 100 · Credit 100'), findsOneWidget);
    expect(find.textContaining('No opening balances'), findsOneWidget);
  });
}
