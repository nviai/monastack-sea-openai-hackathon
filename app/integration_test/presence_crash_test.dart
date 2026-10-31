import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/main.dart';
import 'package:monastack/office_world.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('presence expires after a synthetic peer process crashes', (
    tester,
  ) async {
    Future<void> until(
      bool Function() condition,
      String reason, {
      int attempts = 300,
    }) async {
      for (var i = 0; i < attempts && !condition(); i++) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 100));
        if (reason == 'crashed peer disappears after expiry' && i % 50 == 0) {
          debugPrint('presence crash test: waiting for refresh ($i)');
        }
      }
      expect(condition(), isTrue, reason: reason);
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
    final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
    bool seesPeer() =>
        world.widget.remote.value.any((entry) => entry['actor'] == 'van');
    await until(seesPeer, 'synthetic peer visible');
    final elapsed = Stopwatch()..start();
    tester.widget<TextField>(find.byType(TextField).last).controller!.text =
        'synthetic presence crash marker';
    tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == 'Send',
          ),
        )
        .onPressed!();
    await until(
      () => find
          .text('an: synthetic presence crash marker')
          .evaluate()
          .isNotEmpty,
      'crash marker sent',
    );
    await until(
      () =>
          elapsed.elapsed >= const Duration(seconds: 25) &&
          !seesPeer() &&
          find.text('Chat · Connected').evaluate().isNotEmpty,
      'crashed peer disappears after expiry',
      attempts: 700,
    );
    tester.widget<TextField>(find.byType(TextField).last).controller!.text =
        'synthetic presence expiry verified';
    tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == 'Send',
          ),
        )
        .onPressed!();
    await until(
      () => find
          .text('an: synthetic presence expiry verified')
          .evaluate()
          .isNotEmpty,
      'expiry confirmation sent',
    );
  });
}
