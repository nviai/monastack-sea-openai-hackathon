import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';
import 'package:monastack/features/office/communication/collaboration.dart';
import 'package:monastack/features/office/voice/voice_controller.dart';
import 'package:monastack/features/office/voice/voice_panel.dart';

/// Opt-in smoke against the running local member; does not capture mic/camera.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('lobby controls and real LiveKit connection are available', (
    tester,
  ) async {
    Future<void> until(bool Function() condition, String reason) async {
      for (var i = 0; i < 300 && !condition(); i++) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue, reason: reason);
    }

    await tester.pumpWidget(const ProviderScope(child: Monastack()));
    await until(
      () => find.widgetWithText(TextField, 'Username').evaluate().isNotEmpty,
      'login form',
    );
    tester
            .widget<TextField>(find.widgetWithText(TextField, 'Username'))
            .controller!
            .text =
        'triet.le';
    tester
            .widget<TextField>(find.widgetWithText(TextField, 'Password'))
            .controller!
            .text =
        'NviaiSeaxOpenAIHackathon';
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Sign in'))
        .onPressed!();
    await until(
      () => find.byType(VoicePanel).evaluate().isNotEmpty,
      'lobby media controls',
    );
    expect(find.byTooltip('Turn camera on'), findsOneWidget);
    expect(find.byTooltip('Unmute microphone'), findsOneWidget);
    final voice = tester.widget<VoicePanel>(find.byType(VoicePanel)).controller;
    await until(
      () => voice.value.phase == VoicePhase.idle,
      'media service ready',
    );
    voice.join('lobby');
    await until(
      () => voice.value.phase == VoicePhase.joined,
      'real LiveKit connection',
    );
    expect(voice.value.microphone, isFalse);
    expect(voice.value.camera, isFalse);
    debugPrint(
      'media ready: lobby controls visible; real LiveKit joined with capture off',
    );
    await voice.leave();
    await tester
        .state<CollaborationState>(find.byType(Collaboration))
        .signOut();
    await until(
      () => find.text('Welcome to Monastack').evaluate().isNotEmpty,
      'signed out',
    );
  }, skip: Platform.environment['MONASTACK_TEST_MEDIA_READY'] != '1');
}
