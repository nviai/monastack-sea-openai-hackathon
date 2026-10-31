import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/features/inference/local_inference.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final token = Platform.environment['MONASTACK_TEST_INFERENCE_TOKEN'];
  testWidgets('macOS UI generates with configured local model', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LocalInference()));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(
      find.widgetWithText(TextField, 'Local inference token'),
      token!,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Prompt'),
      'Say hello in one short sentence.',
    );
    await tester.tap(find.text('Generate'));
    await tester.pump(const Duration(milliseconds: 100));
    for (
      var i = 0;
      i < 300 && find.text('Generating…').evaluate().isNotEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.text('Local model unavailable, busy, or credential rejected.'),
      findsNothing,
    );
    final output = tester.widget<SelectableText>(
      find.byKey(const ValueKey('local-model-output')),
    );
    expect(output.data, isNotEmpty);
    expect(output.data, isNot('No generation requested.'));
  }, skip: token == null);
}
