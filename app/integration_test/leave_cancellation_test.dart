import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('request approved leave cancellation from the app', (
    tester,
  ) async {
    final credential = Platform.environment['MONASTACK_TEST_AN']!;
    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    for (var i = 0; i < 60 && find.text('Connect').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.enterText(find.byType(TextField).first, credential);
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
    await tester.ensureVisible(find.text('Leave requests').last);
    await tester.tap(find.text('Leave requests').last);
    for (
      var i = 0;
      i < 60 && find.text('Request cancellation').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Request cancellation'), findsOneWidget);
    await tester.tap(find.text('Request cancellation'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.text('Request cancellation of approved leave?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Confirm'));
    for (
      var i = 0;
      i < 50 && find.textContaining('cancellation_pending').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('cancellation_pending'), findsOneWidget);
  });
}
