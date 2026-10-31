import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('receives synthetic silent audio over loopback', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('Synthetic media probe')));
    final room = lk.Room();
    final listener = room.createListener();
    final outsider = lk.Room();
    final outsiderListener = outsider.createListener();
    var outsiderReceived = false;
    outsiderListener.on<lk.TrackSubscribedEvent>((event) {
      if (event.track is lk.RemoteAudioTrack) outsiderReceived = true;
    });
    final subscribed = Completer<lk.RemoteAudioTrack>();
    listener.on<lk.TrackSubscribedEvent>((event) {
      if (!subscribed.isCompleted && event.track is lk.RemoteAudioTrack) {
        subscribed.complete(event.track as lk.RemoteAudioTrack);
      }
    });
    try {
      await tester.runAsync(() async {
        await room.connect(
          Platform.environment['PROBE_URL']!,
          Platform.environment['PROBE_RECEIVER_TOKEN']!,
          connectOptions: const lk.ConnectOptions(
            rtcConfiguration: lk.RTCConfiguration(iceServers: []),
          ),
        ).timeout(const Duration(seconds: 30));
        expect(room.localParticipant, isNotNull);
        expect(room.localParticipant!.audioTrackPublications, isEmpty,
            reason: 'synthetic receiver must not publish a microphone');
        await outsider.connect(
          Platform.environment['PROBE_URL']!,
          Platform.environment['PROBE_OUTSIDER_TOKEN']!,
          connectOptions: const lk.ConnectOptions(
            rtcConfiguration: lk.RTCConfiguration(iceServers: []),
          ),
        ).timeout(const Duration(seconds: 30));
        final track = await subscribed.future.timeout(const Duration(seconds: 30));
        var bytes = 0;
        for (var i = 0; i < 60 && bytes == 0; i++) {
          final stats = await track.getReceiverStats();
          bytes = (stats?.bytesReceived ?? 0).toInt();
          if (bytes == 0) await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        expect(bytes, greaterThan(0), reason: 'synthetic audio RTP bytes received');
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(outsiderReceived, isFalse, reason: 'other room cannot subscribe to this track');
      });
      debugPrint('FLUTTER_MEDIA_SUBSCRIPTION_VERIFIED');
    } finally {
      await tester.runAsync(() async {
        await room.disconnect();
        await outsider.disconnect();
        await listener.dispose();
        await outsiderListener.dispose();
        await room.dispose();
        await outsider.dispose();
      });
    }
  });
}
