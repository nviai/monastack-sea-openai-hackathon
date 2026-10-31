import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';
import 'package:monastack/features/office/voice/voice_controller.dart';
import 'package:monastack/features/office/voice/voice_panel.dart';
import 'package:monastack/features/office/world/office_world.dart';

/// Run by `backend/office-node/tests/voice_app.py`: a synthetic peer publishes
/// generated silence in the lobby. The microphone is never unmuted here.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final credential = Platform.environment['MONASTACK_TEST_CREDENTIAL']!;
  testWidgets('app joins room voice muted and follows the room', (
    tester,
  ) async {
    Future<void> until(
      bool Function() condition,
      String label, {
      int attempts = 300,
    }) async {
      for (var i = 0; i < attempts && !condition(); i++) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue, reason: label);
    }

    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    await until(() => find.text('Connect').evaluate().isNotEmpty, 'connect UI');
    tester.widget<TextField>(find.byType(TextField).first).controller!.text =
        credential;
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Connect'))
        .onPressed!();
    await until(
      () => find.textContaining('Join voice in Lobby').evaluate().isNotEmpty,
      'voice offered for the lobby',
    );
    VoiceController voice() =>
        tester.widget<VoicePanel>(find.byType(VoicePanel)).controller;
    tester
        .widget<TextButton>(
          find.ancestor(
            of: find.textContaining('Join voice in Lobby'),
            matching: find.byWidgetPredicate((w) => w is TextButton),
          ),
        )
        .onPressed!();
    await until(
      () => voice().value.phase == VoicePhase.joined,
      'joined lobby voice',
    );
    expect(voice().value.microphone, isFalse, reason: 'muted by default');
    expect(find.byTooltip('Unmute microphone'), findsOneWidget);
    await until(
      () => voice().value.hearing.contains('van'),
      'receiving the synthetic peer audio',
    );
    debugPrint('voice app: hearing peer in lobby while muted');
    final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
    await tester.runAsync(() => world.goToRoom('dev'));
    await until(
      () => world.current.toString() == '[3, 3]',
      'walked to dev',
      attempts: 300,
    );
    await until(
      () =>
          voice().value.phase == VoicePhase.joined &&
          voice().value.room == 'dev',
      'voice followed to dev',
    );
    expect(voice().value.hearing, isEmpty, reason: 'lobby audio not in dev');
    expect(voice().value.microphone, isFalse);
    debugPrint('voice app: followed to dev, lobby audio isolated');
    tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (w) => w is IconButton && w.tooltip == 'Leave voice',
          ),
        )
        .onPressed!();
    await until(() => voice().value.phase == VoicePhase.idle, 'left voice');
  });
}
