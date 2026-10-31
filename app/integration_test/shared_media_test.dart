import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:uuid/uuid.dart';
import 'package:monastack/features/chat/data/matrix_chat_client.dart';
import 'package:monastack/features/chat/data/matrix_session.dart';
import 'package:monastack/features/chat/domain/chat_client.dart';
import 'package:monastack/features/identity/credential_store.dart';
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

    final authClientA = HttpClient()..idleTimeout = const Duration(seconds: 1);
    final authClientB = HttpClient()..idleTimeout = const Duration(seconds: 1);
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
    final va = VoiceController(
          cameraOnJoin: false,
          realtime: rtA,
          session: () => sa,
        ),
        vb = VoiceController(
          cameraOnJoin: false,
          realtime: rtB,
          session: () => sb,
        );
    bool restoreAgentPause = false;
    Timer? heartbeat;
    MatrixChatClient? chatA, chatB;
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
      if (Platform.environment['MONASTACK_TEST_LIVE_AGENT'] == '1') {
        final status = await apiA.call(
          'GET',
          '/v1/live-agents/rooms/lobby',
          bearer: a.accessToken,
        ) as Map;
        restoreAgentPause = status['state'] == 'paused';
        if (restoreAgentPause) {
          await apiA.call(
            'POST',
            '/v1/live-agents/rooms/lobby',
            body: {'action': 'resume'},
            bearer: a.accessToken,
          );
        }
      }
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
      if (Platform.environment['MONASTACK_TEST_LIVE_AGENT'] == '1') {
        await until(
          () =>
              va.value.hearing.contains('mona') &&
              vb.value.hearing.contains('mona'),
          'both Flutter clients subscribe to one live Mona',
        );
        await va.setAgentMuted(true);
        await until(
          () => !va.value.hearing.contains('mona'),
          'local agent mute disables only this subscription',
        );
        expect(vb.value.hearing.contains('mona'), isTrue);
        expect(va.value.participants.contains('hua-hao'), isTrue);
        await va.setAgentMuted(false);
        await until(
          () => va.value.hearing.contains('mona'),
          'local agent unmute restores subscription',
        );
        debugPrint(
          'live agent: shared Mona received by both Flutter clients; local mute/unmute preserves the other peer; capture stays off',
        );
      }
      if (Platform.environment['MONASTACK_TEST_MATRIX_CHAT'] == '1') {
        MatrixChatClient chat(
          AuthApi api,
          String access,
          String actor,
          String node,
        ) => MatrixChatClient(
          MatrixSession(
            request: (method, path, [body]) =>
                api.call(method, path, body: body, bearer: access),
            store: MemoryCredentialStore(),
            node: node,
            actor: actor,
          ),
        );
        chatA = chat(apiA, a.accessToken, a.actor, 'integration-master');
        chatB = chat(apiB, b.accessToken, b.actor, 'integration-member');
        await Future.wait([chatA.start(), chatB.start()]);
        await until(
          () =>
              chatA!.phase == ChatPhase.ready &&
              chatB!.phase == ChatPhase.ready &&
              chatA.rooms.any((r) => r.officeRoom == 'lobby') &&
              chatB.rooms.any((r) => r.officeRoom == 'lobby'),
          'two actual Matrix SDK clients connected through master and member',
        );
        final lobbyA = chatA.rooms
            .firstWhere((r) => r.officeRoom == 'lobby')
            .id;
        final lobbyB = chatB.rooms
            .firstWhere((r) => r.officeRoom == 'lobby')
            .id;
        expect(lobbyA, lobbyB);
        await Future.wait([chatA.load(lobbyA), chatB.load(lobbyB)]);
        final marker = 'Matrix + LiveKit integration ${const Uuid().v4()}';
        final message = await chatA.send(lobbyA, marker, const Uuid().v4());
        await until(
          () => chatB!
              .messages(lobbyB)
              .any((m) => m.id == message && m.body == marker),
          'Matrix delivers a real message while LiveKit stays connected',
        );
        expect(va.value.phase, VoicePhase.joined);
        expect(vb.value.phase, VoicePhase.joined);
        final appearances = await apiA.call(
          'GET',
          '/v1/agents/appearances',
          bearer: a.accessToken,
        ) as List;
        expect(appearances.map((x) => x['name']).toSet(), {
          'Mona',
          'Atlas',
          'Iris',
          'Nova',
          'Leo',
          'Luna',
        });
        expect(appearances.where((x) => x['gender'] == 'female').length, 4);
        await chatA.redact(lobbyA, message);
        debugPrint(
          'matrix + live agents: real Dart SDK message crossed nodes while shared LiveKit remained connected; all six configured avatars available',
        );
      }
      final pa = await rtA.request('GET', '/v1/presence') as List;
      final pb = await rtB.request('GET', '/v1/presence') as List;
      expect(pa.any((p) => p['actor'] == 'hua-hao'), isTrue);
      expect(pb.any((p) => p['actor'] == 'le-pha'), isTrue);
      debugPrint(
        'shared media: real master/member peers see each other in one LiveKit room and shared presence',
      );
    } finally {
      heartbeat?.cancel();
      await chatA?.signOut();
      await chatB?.signOut();
      await va.leave();
      await vb.leave();
      va.dispose();
      vb.dispose();
      for (final cleanup in <Future<dynamic> Function()>[
        if (restoreAgentPause)
          () => apiA.call(
            'POST',
            '/v1/live-agents/rooms/lobby',
            body: {'action': 'pause'},
            bearer: a.accessToken,
          ),
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
