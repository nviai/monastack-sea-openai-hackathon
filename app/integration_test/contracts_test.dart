import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('create an internal contract proposal through the macOS app', (
    tester,
  ) async {
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
    await tester.ensureVisible(find.text('Contract proposals').last);
    await tester.tap(find.text('Contract proposals').last);
    for (
      var i = 0;
      i < 50 && find.text('Propose contract').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Propose contract'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Synthetic customer').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'Synthetic contract',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Proposed terms'),
      'Synthetic frozen terms',
    );
    await tester.tap(find.text('Submit'));
    for (
      var i = 0;
      i < 50 && find.text('Synthetic contract').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Synthetic contract'), findsOneWidget);
    expect(find.textContaining('No agreement is signed'), findsOneWidget);
    expect(find.text('Approve internally'), findsNothing);
  });
}
