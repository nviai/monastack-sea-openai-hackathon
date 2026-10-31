import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';
import 'package:monastack/features/identity/auth_api.dart';
import 'package:monastack/features/office/presence/realtime_session.dart';
import 'package:monastack/features/office/voice/voice_controller.dart';

/// Two real RTC peers via master and member; no microphone/camera capture.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('master and member clients meet in one LiveKit room', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Shared media verification')),
      ),
    );
    Future<void> until(bool Function() condition, String reason) async {
      for (var i = 0; i < 300 && !condition(); i++) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(condition(), isTrue, reason: reason);
    }

    final authClientA = HttpClient()..idleTimeout = Duration.zero;
    final authClientB = HttpClient()..idleTimeout = Duration.zero;
    final apiA = AuthApi(port: 47830, client: authClientA),
        apiB = AuthApi(port: 47840, client: authClientB);
    final a = await apiA.login('pha.le', 'NviaiSeaxOpenAIHackathon');
    final b = await apiB.login('hao.hua', 'NviaiSeaxOpenAIHackathon');
    final clientA = HttpClient(), clientB = HttpClient();
    final rtA = RealtimeSession(
      client: clientA,
      issue: () => apiA.call(
        'POST',
        '/v1/realtime/ticket',
        body: {},
        bearer: a.accessToken,
      ),
    );
    final rtB = RealtimeSession(
      client: clientB,
      issue: () => apiB.call(
        'POST',
        '/v1/realtime/ticket',
        body: {},
        bearer: b.accessToken,
      ),
    );
    final sa = const Uuid().v4(), sb = const Uuid().v4();
    final va = VoiceController(realtime: rtA, session: () => sa),
        vb = VoiceController(realtime: rtB, session: () => sb);
    Timer? heartbeat;
    var seq = 0;
    Future<void> publish() async {
      final n = ++seq;
      await Future.wait([
        rtA.request('POST', '/v1/presence', {
          'session': sa,
          'room': 'lobby',
          'x': 14,
          'y': 13,
          'seq': n,
        }),
        rtB.request('POST', '/v1/presence', {
          'session': sb,
          'room': 'lobby',
          'x': 14,
          'y': 13,
          'seq': n,
        }),
      ]);
    }

    try {
      final ticketA = await apiA.call(
        'POST',
        '/v1/realtime/ticket',
        body: {},
        bearer: a.accessToken,
      );
      final ticketB = await apiB.call(
        'POST',
        '/v1/realtime/ticket',
        body: {},
        bearer: b.accessToken,
      );
      expect(ticketA['realtime_url'], ticketB['realtime_url']);
      await publish();
      heartbeat = Timer.periodic(
        const Duration(seconds: 1),
        (_) => unawaited(publish().catchError((_) {})),
      );
      va.join('lobby');
      vb.join('lobby');
      await until(
        () =>
            va.value.phase == VoicePhase.joined &&
            vb.value.phase == VoicePhase.joined,
        'both real RTC peers joined',
      );
      await until(
        () =>
            va.value.participants.contains('hua-hao') &&
            vb.value.participants.contains('le-pha'),
        'peers see each other across master and member',
      );
      expect(va.value.microphone, isFalse);
      expect(vb.value.camera, isFalse);
      final pa = await rtA.request('GET', '/v1/presence') as List;
      final pb = await rtB.request('GET', '/v1/presence') as List;
      expect(pa.any((p) => p['actor'] == 'hua-hao'), isTrue);
      expect(pb.any((p) => p['actor'] == 'le-pha'), isTrue);
      debugPrint(
        'shared media: real master/member peers see each other in one LiveKit room and shared presence',
      );
    } finally {
      heartbeat?.cancel();
      await va.leave();
      await vb.leave();
      va.dispose();
      vb.dispose();
      for (final cleanup in <Future<dynamic> Function()>[
        () => rtA.request('DELETE', '/v1/presence/$sa'),
        () => rtB.request('DELETE', '/v1/presence/$sb'),
        () => apiA.call('POST', '/v1/auth/logout', bearer: a.accessToken),
        () => apiB.call('POST', '/v1/auth/logout', bearer: b.accessToken),
      ]) {
        try {
          await cleanup();
        } catch (_) {}
      }
      authClientA.close(force: true);
      authClientB.close(force: true);
      clientA.close(force: true);
      clientB.close(force: true);
    }
  }, skip: Platform.environment['MONASTACK_TEST_SHARED_MEDIA'] != '1');
}
