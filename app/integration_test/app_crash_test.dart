import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';
import 'package:monastack/features/office/world/office_world.dart';

/// Run by `backend/office-node/tests/app_crash_app.py` in two separate app
/// processes. The `victim` app is killed with SIGKILL by the harness; the
/// `observer` app must see its avatar expire and stay gone.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final role = Platform.environment['MONASTACK_TEST_ROLE']!;
  final credential = Platform.environment['MONASTACK_TEST_CREDENTIAL']!;
  final peer = Platform.environment['MONASTACK_TEST_PEER']!;
  final actor = Platform.environment['MONASTACK_TEST_ACTOR']!;
  testWidgets('a killed second app leaves no ghost avatar', (tester) async {
    Future<void> until(
      bool Function() condition,
      String label, {
      int attempts = 150,
    }) async {
      for (var i = 0; i < attempts && !condition(); i++) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue, reason: label);
    }

    bool message(String text) =>
        find.textContaining(text).evaluate().isNotEmpty;
    void icon(String tooltip) => tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (w) => w is IconButton && w.tooltip == tooltip,
          ),
        )
        .onPressed!();
    Future<void> send(String text) async {
      tester.widget<TextField>(find.byType(TextField).last).controller!.text =
          text;
      icon('Send');
      // Match the delivered chat line, not the draft field.
      await until(() => message('$actor: $text'), 'message $text');
    }

    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    await until(() => find.text('Connect').evaluate().isNotEmpty, 'connect UI');
    tester.widget<TextField>(find.byType(TextField).first).controller!.text =
        credential;
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Connect'))
        .onPressed!();
    await until(() => message('Chat · Connected'), 'connected');
    final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
    bool sees() => world.widget.remote.value.any((p) => p['actor'] == peer);
    // macOS builds are serialized, so the peer may take minutes to appear.
    await until(sees, 'peer app visible', attempts: 3000);
    debugPrint('app crash $role sees $peer');
    if (role == 'victim') {
      await send('app crash: victim ready');
      // Keep heartbeating until the harness kills this process.
      while (true) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 200));
      }
    }
    await until(
      () => message('$peer: app crash: victim ready'),
      'victim ready',
      attempts: 600,
    );
    await send('app crash: kill victim');
    final killed = DateTime.now();
    // Expiry is 20 s after the last heartbeat; the observer polls every 5 s.
    await until(() => !sees(), 'killed app expired', attempts: 450);
    final seconds = DateTime.now().difference(killed).inSeconds;
    debugPrint('app crash observer: peer gone after ${seconds}s');
    expect(seconds, lessThan(40));
    // No ghost: the avatar must not come back.
    for (var i = 0; i < 120; i++) {
      tester.binding.scheduleForcedFrame();
      await tester.pump(const Duration(milliseconds: 100));
      expect(sees(), isFalse, reason: 'ghost avatar reappeared');
    }
    await send('app crash: expiry verified');
  });
}
