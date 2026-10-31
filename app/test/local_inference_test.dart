import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/local_inference.dart';

void main() {
  testWidgets('generation is explicit and displays the local response', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.resetPhysicalSize);
    var calls = 0;
    Future<String> generate(String credential, String prompt) async {
      calls++;
      return 'Local response';
    }

    await tester.pumpWidget(
      MaterialApp(home: LocalInference(generate: generate)),
    );
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('No generation requested.'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Local inference token'),
      'test-token',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Prompt'),
      'Synthetic input',
    );
    await tester.tap(find.text('Generate'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Local response'), findsOneWidget);
  });
}
