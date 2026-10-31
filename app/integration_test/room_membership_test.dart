import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';
import 'package:monastack/features/office/world/office_world.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('room grant and revocation update connected navigation', (
    tester,
  ) async {
    Future<void> until(
      bool Function() condition,
      String reason, {
      int attempts = 250,
    }) async {
      for (var i = 0; i < attempts && !condition(); i++) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 100));
        if (reason == 'connected' && i == 10) {
          final states = find
              .byType(Text)
              .evaluate()
              .map((e) => (e.widget as Text).data ?? '')
              .where((value) => value.startsWith('Chat ·'))
              .join(', ');
          debugPrint('membership test: chat state $states');
        }
      }
      expect(condition(), isTrue, reason: reason);
    }

    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    await until(() => find.text('Connect').evaluate().isNotEmpty, 'connect UI');
    debugPrint('membership test: connect UI');
    tester.widget<TextField>(find.byType(TextField).first).controller!.text =
        Platform.environment['MONASTACK_TEST_TOKEN']!;
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Connect'))
        .onPressed!();
    await until(
      () => find.text('Chat · Connected').evaluate().isNotEmpty,
      'connected',
    );
    debugPrint('membership test: connected');
    void finance() => tester
        .widget<ListTile>(find.widgetWithText(ListTile, 'Finance'))
        .onTap!();
    finance();
    await tester.pump();
    expect(find.textContaining('Access denied to Finance'), findsOneWidget);
    debugPrint('membership test: initial denial');
    tester.widget<TextField>(find.byType(TextField).last).controller!.text =
        'synthetic grant requested';
    tester
        .widget<IconButton>(
          find.byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Send'),
        )
        .onPressed!();
    await until(
      () => find
          .textContaining('an: synthetic grant requested')
          .evaluate()
          .isNotEmpty,
      'grant request sent',
    );
    debugPrint('membership test: signal sent');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      await tester.runAsync(() async {
        var granted = false;
        for (var i = 0; i < 100 && !granted; i++) {
          final req = await client.getUrl(
            Uri.parse(
              'http://127.0.0.1:${Platform.environment['MONASTACK_NODE_PORT']}/v1/rooms',
            ),
          );
          req.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${Platform.environment['MONASTACK_TEST_TOKEN']}',
          );
          final response = await req.close();
          final text = await response.transform(utf8.decoder).join();
          granted = text.contains('"finance"');
          if (!granted) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
        }
        expect(granted, isTrue, reason: 'grant visible at node');
        debugPrint('membership test: grant visible at node');
      });
    } finally {
      client.close(force: true);
    }
    final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
    // The node grant and the app's periodic permission refresh are separate.
    // Retry only while the prior denial is visible, so an active route is not reset.
    for (var i = 0; i < 25; i++) {
      finance();
      await tester.pump(const Duration(milliseconds: 500));
      if (find.textContaining('Access denied to Finance').evaluate().isEmpty) {
        break;
      }
    }
    expect(find.textContaining('Access denied to Finance'), findsNothing);
    debugPrint('membership test: navigating to finance');
    await until(
      () => world.current.toString() == '[25, 23]',
      'new membership allows navigation',
    );
    debugPrint('membership test: arrived');
    await until(
      () => world.current.toString() == '[14, 13]',
      'revocation returns to lobby',
      attempts: 350,
    );
    expect(find.textContaining('Room access changed'), findsOneWidget);
    finance();
    await tester.pump();
    expect(find.textContaining('Access denied to Finance'), findsOneWidget);
    tester.widget<TextField>(find.byType(TextField).last).controller!.text =
        'synthetic membership verified';
    tester
        .widget<IconButton>(
          find.byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Send'),
        )
        .onPressed!();
    await until(
      () =>
          find.text('an: synthetic membership verified').evaluate().isNotEmpty,
      'membership verification recorded',
    );
  });
}
