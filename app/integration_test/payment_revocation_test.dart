import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('revoke an internal payment authorization through the app', (
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
    await tester.ensureVisible(find.text('Payment authorizations').last);
    await tester.tap(find.text('Payment authorizations').last);
    for (var i = 0; i < 50 && find.text('Revoke').evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Revoke'), findsOneWidget);
    await tester.tap(find.text('Revoke'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Revoke authorization?'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    for (
      var i = 0;
      i < 50 && find.textContaining('revoked').evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('revoked'), findsOneWidget);
  });
}
