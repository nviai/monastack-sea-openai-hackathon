import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final phase = Platform.environment['MONASTACK_TEST_PHASE'];
  testWidgets('chat queue survives an app process restart', (tester) async {
    Future<void> until(
      bool Function() condition,
      String reason, {
      int attempts = 350,
    }) async {
      for (var i = 0; i < attempts && !condition(); i++) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 100));
        if (i > 0 && i % 100 == 0) {
          final states = find
              .byType(Text)
              .evaluate()
              .map((e) => (e.widget as Text).data ?? '')
              .where(
                (value) =>
                    value.startsWith('Chat ·') ||
                    value.startsWith('Messages pending/'),
              )
              .join(', ');
          debugPrint('chat process restart: $reason ($states)');
        }
      }
      expect(condition(), isTrue, reason: reason);
    }

    Finder sendButton() =>
        find.byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Send');
    void send(String value) {
      tester.widget<TextField>(find.byType(TextField).last).controller!.text =
          value;
      tester.widget<IconButton>(sendButton()).onPressed!();
    }

    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    await until(() => find.text('Connect').evaluate().isNotEmpty, 'connect UI');
    tester.widget<TextField>(find.byType(TextField).first).controller!.text =
        Platform.environment['MONASTACK_TEST_TOKEN']!;
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Connect'))
        .onPressed!();
    await until(
      () => find.text('Chat · Connected').evaluate().isNotEmpty,
      'connected',
    );
    if (phase == 'queue') {
      send('synthetic outage marker $pid');
      await until(
        () =>
            find.text('Chat · Offline or access denied').evaluate().isNotEmpty,
        'node outage',
      );
      send('synthetic process restart message');
      await until(
        () =>
            find.text('Messages pending/rejected: 1').evaluate().isNotEmpty &&
            tester.widget<IconButton>(sendButton()).onPressed != null,
        'message persisted',
      );
      expect(find.text('Messages pending/rejected: 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } else if (phase == 'replay') {
      await until(
        () => find
            .text('an: synthetic process restart message')
            .evaluate()
            .isNotEmpty,
        'message delivered after process restart',
      );
      expect(find.text('Messages pending/rejected: 1'), findsNothing);
      send('synthetic replay process $pid');
      await until(
        () => find
            .text('an: synthetic replay process $pid')
            .evaluate()
            .isNotEmpty,
        'replay process recorded',
      );
    } else {
      fail('unknown test phase');
    }
  });
}
