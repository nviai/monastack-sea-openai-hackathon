import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';
import 'package:monastack/features/office/voice/voice_controller.dart';
import 'package:monastack/features/office/voice/voice_panel.dart';
import 'package:monastack/features/office/world/office_world.dart';
import 'package:path_provider/path_provider.dart';

/// Run by `backend/office-node/tests/voice_app.py`: a synthetic peer publishes
/// generated silence and a generated camera video in the lobby. This app's
/// microphone and camera are never turned on here.
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

    final boundary = GlobalKey();
    await tester.pumpWidget(
      ProviderScope(
        child: RepaintBoundary(key: boundary, child: const Monastack()),
      ),
    );
    await until(() => find.text('Connect').evaluate().isNotEmpty, 'connect UI');
    tester.widget<TextField>(find.byType(TextField).first).controller!.text =
        credential;
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, 'Connect'))
        .onPressed!();
    await until(
      () => find.byType(VoicePanel).evaluate().isNotEmpty,
      'media controls available in lobby',
    );
    VoiceController voice() =>
        tester.widget<VoicePanel>(find.byType(VoicePanel)).controller;
    expect(find.byTooltip('Turn camera on'), findsOneWidget);
    expect(find.byTooltip('Unmute microphone'), findsOneWidget);
    // Connect with capture off to verify the synthetic peer without using devices.
    voice().join('lobby');
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
    // The peer's camera replaces its drawn face in the office view.
    await until(
      () => voice().value.videos.containsKey('van'),
      'peer camera track received',
    );
    await until(
      () =>
          world.game.faceSlots.any((f) => f.actor == 'van') &&
          find
              .descendant(
                of: find.byKey(const ValueKey('face-van')),
                matching: find.byType(lk.VideoTrackRenderer),
              )
              .evaluate()
              .isNotEmpty,
      'peer camera shown as its face',
    );
    num decoded = 0;
    for (var i = 0; i < 100 && decoded < 10; i++) {
      final track = voice().value.videos['van'];
      if (track is lk.RemoteVideoTrack) {
        final stats = await tester.runAsync(track.getReceiverStats);
        decoded = stats?.framesDecoded ?? 0;
      }
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(decoded, greaterThanOrEqualTo(10), reason: 'camera frames decoded');
    expect(voice().value.camera, isFalse, reason: 'own camera stays off');
    expect(voice().value.videos.containsKey('an'), isFalse);
    expect(find.byTooltip('Turn camera on'), findsOneWidget);
    debugPrint('voice app: peer camera face shown, $decoded frames decoded');
    // Private close-up for visual review; it shows seeded names.
    world.game.focusOn([13, 12], zoomTo: 3);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    final capture = await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = await (await getTemporaryDirectory()).createTemp(
        'voice-capture-',
      );
      final file = File('${directory.path}/camera-face.png');
      await file.writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
      return file.path;
    });
    debugPrint('voice app: capture $capture');
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
    expect(voice().value.videos, isEmpty, reason: 'lobby camera not in dev');
    await until(
      () => find.byKey(const ValueKey('face-van')).evaluate().isEmpty,
      'peer camera face removed',
    );
    expect(voice().value.microphone, isFalse);
    debugPrint('voice app: followed to dev, lobby audio and camera isolated');
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
