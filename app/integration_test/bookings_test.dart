import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('create a local customer booking through the macOS app', (
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
    await tester.ensureVisible(find.text('Customer bookings').last);
    await tester.tap(find.text('Customer bookings').last);
    for (
      var i = 0;
      i < 50 && find.text('Book customer').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Book customer'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Synthetic customer').last);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'Synthetic booking',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Start UTC'),
      '2026-12-01 12:00',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'End UTC'),
      '2026-12-01 13:00',
    );
    await tester.tap(find.text('Save'));
    for (
      var i = 0;
      i < 50 && find.text('Synthetic booking').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Synthetic booking'), findsOneWidget);
    expect(find.textContaining('no invitations'), findsOneWidget);
    for (var i = 0; i < 80 && find.text('Reschedule').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('Reschedule'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Start UTC'),
      '2026-12-01 14:00',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'End UTC'),
      '2026-12-01 15:00',
    );
    await tester.tap(find.text('Save'));
    for (
      var i = 0;
      i < 80 &&
          (find.text('Reschedule booking').evaluate().isNotEmpty ||
              find.textContaining('2026-12-01 14:00').evaluate().isEmpty);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('2026-12-01 14:00'), findsOneWidget);
    await tester.ensureVisible(find.text('Cancel booking'));
    await tester.tap(find.text('Cancel booking'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Confirm cancellation'));
    for (
      var i = 0;
      i < 50 && find.textContaining('cancelled').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('cancelled'), findsOneWidget);
  });
}
