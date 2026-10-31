import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:monastack/features/office/presence/realtime_session.dart';
import 'package:monastack/features/office/voice/voice_controller.dart';

class FakeConnection extends VoiceConnection {
  bool microphone = false;
  bool camera = false;
  bool agentMuted = false;
  bool cameraFails = false;
  bool closed = false;
  Set<String> others = {};
  Set<String> talking = {};
  @override
  Set<String> participants() => others;
  @override
  Set<String> speaking() => talking;
  @override
  Set<String> hearing() => others;
  @override
  Map<String, lk.VideoTrack> videos() => const {};
  @override
  Future<void> setMicrophone(bool enabled) async => microphone = enabled;
  @override
  Future<void> setCamera(bool enabled) async {
    if (enabled && cameraFails) throw StateError('no camera');
    camera = enabled;
  }

  @override
  Future<void> setAgentMuted(bool muted) async => agentMuted = muted;
  @override
  Future<void> close() async => closed = true;
}

/// A loopback realtime service; `statusFor` picks each token response.
Future<(HttpServer, List<Map<String, dynamic>>)> fakeRealtime(
  List<int> Function() statusFor,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <Map<String, dynamic>>[];
  server.listen((request) async {
    final body = await utf8.decoder.bind(request).join();
    if (request.uri.path == '/v1/media/status') {
      request.response.write(jsonEncode({'available': true}));
    } else {
      requests.add(jsonDecode(body) as Map<String, dynamic>);
      final status = statusFor().first;
      request.response.statusCode = status;
      if (status == 200) {
        request.response.write(
          jsonEncode({
            'url': 'ws://127.0.0.1:7880',
            'token': 'join-${requests.length}',
          }),
        );
      }
    }
    await request.response.close();
  });
  return (server, requests);
}

void main() {
  late HttpClient client;
  setUp(() => client = HttpClient());
  tearDown(() => client.close(force: true));

  RealtimeSession session(HttpServer server) => RealtimeSession(
    client: client,
    issue: () async => {
      'ticket': 't',
      'expires_in': 30,
      'realtime_url': 'http://127.0.0.1:${server.port}',
    },
  );

  test('camera defaults on after join, microphone stays off, and manual camera off persists', () async {
    final (server, _) = await fakeRealtime(() => [200]);
    addTearDown(() => server.close(force: true));
    final connection = FakeConnection();
    final voice = VoiceController(
      realtime: session(server),
      session: () => 'human',
      connector: (_, _) async => connection,
    );
    addTearDown(voice.dispose);
    expect(connection.camera, false);
    await voice.join('lobby');
    expect(connection.camera, true);
    expect(voice.value.camera, true);
    expect(voice.value.microphone, false);
    await voice.setCamera(false);
    await voice.follow('dev');
    expect(connection.camera, false);
    expect(voice.value.camera, false);
  });

  test('agent auto-join receives only; explicit leave is respected until room changes', () async {
    final (server, requests) = await fakeRealtime(() => [200]);
    addTearDown(() => server.close(force: true));
    final connections = <FakeConnection>[];
    final voice = VoiceController(
      cameraOnJoin: false,
      realtime: session(server),
      session: () => 'human',
      connector: (_, _) async {
        final c = FakeConnection();
        connections.add(c);
        return c;
      },
    );
    addTearDown(voice.dispose);
    await voice.follow('lobby');
    await voice.autoJoinAgentRoom('lobby');
    expect(voice.value.phase, VoicePhase.joined);
    expect(connections.single.microphone, false);
    expect(connections.single.camera, false);
    await voice.autoJoinAgentRoom('lobby');
    expect(requests.length, 1);
    await voice.setAgentMuted(true);
    expect(connections.single.agentMuted, true);
    await voice.leave();
    await voice.autoJoinAgentRoom('lobby');
    expect(requests.length, 1);
    await voice.follow('dev');
    await voice.autoJoinAgentRoom('dev');
    expect(requests.length, 2);
    expect(connections.last.agentMuted, true);
    expect(connections.last.microphone, false);
    expect(connections.last.camera, false);
  });

  test(
    'a delayed agent status for a previous room cannot join media',
    () async {
      final (server, requests) = await fakeRealtime(() => [200]);
      addTearDown(() => server.close(force: true));
      final voice = VoiceController(
        cameraOnJoin: false,
        realtime: session(server),
        session: () => 'human',
        connector: (_, _) async => FakeConnection(),
      );
      addTearDown(voice.dispose);
      await voice.follow('dev');
      await voice.autoJoinAgentRoom('lobby');
      expect(requests, isEmpty);
      expect(voice.value.microphone, false);
    },
  );

  for (final camera in [false, true]) {
    test('device button auto-connects from lobby: camera=$camera', () async {
      final (server, requests) = await fakeRealtime(() => [200]);
      addTearDown(() => server.close(force: true));
      final connection = FakeConnection();
      final voice = VoiceController(
        cameraOnJoin: false,
        realtime: session(server),
        session: () => 'session-1',
        connector: (_, _) async => connection,
      );
      addTearDown(voice.dispose);
      await voice.refreshAvailability();
      expect(voice.value.phase, VoicePhase.idle);
      if (camera) {
        await voice.toggleCamera('lobby');
      } else {
        await voice.toggleMicrophone('lobby');
      }
      expect(voice.value.phase, VoicePhase.joined);
      expect(connection.camera, camera);
      expect(connection.microphone, !camera);
      expect(requests.single['room'], 'lobby');
      if (camera) {
        await voice.toggleCamera('lobby');
      } else {
        await voice.toggleMicrophone('lobby');
      }
      expect(connection.camera, isFalse);
      expect(connection.microphone, isFalse);
      expect(requests.length, 1);
    });
  }

  test(
    'leaving while a device button connects cannot re-enable capture',
    () async {
      final (server, _) = await fakeRealtime(() => [200]);
      addTearDown(() => server.close(force: true));
      final started = Completer<void>();
      final ready = Completer<VoiceConnection>();
      final connection = FakeConnection();
      final voice = VoiceController(
        cameraOnJoin: false,
        realtime: session(server),
        session: () => 'session-1',
        connector: (_, _) {
          started.complete();
          return ready.future;
        },
      );
      addTearDown(voice.dispose);
      final pending = voice.toggleCamera('lobby');
      await started.future;
      await voice.leave();
      ready.complete(connection);
      await pending;
      expect(voice.value.phase, VoicePhase.idle);
      expect(connection.camera, isFalse);
      expect(connection.closed, isTrue);
    },
  );

  test('joins muted, follows the room and leaves on request', () async {
    final (server, requests) = await fakeRealtime(() => [200]);
    addTearDown(() => server.close(force: true));
    final connections = <FakeConnection>[];
    final tokens = <String>[];
    final voice = VoiceController(
      cameraOnJoin: false,
      realtime: session(server),
      session: () => 'session-1',
      connector: (url, token) async {
        tokens.add(token);
        final c = FakeConnection();
        connections.add(c);
        return c;
      },
    );
    addTearDown(voice.dispose);
    await voice.refreshAvailability();
    expect(voice.value.phase, VoicePhase.idle);
    await voice.join('lobby');
    expect(voice.value.phase, VoicePhase.joined);
    expect(voice.value.microphone, isFalse, reason: 'muted by default');
    expect(connections.single.microphone, isFalse);
    expect(requests.single, {'room': 'lobby', 'session': 'session-1'});
    await voice.setMicrophone(true);
    expect(connections.single.microphone, isTrue);
    await voice.follow('dev');
    expect(connections.first.closed, isTrue);
    expect(voice.value.room, 'dev');
    expect(voice.value.microphone, isFalse, reason: 'muted again in new room');
    expect(requests.last['room'], 'dev');
    await voice.leave();
    expect(connections.last.closed, isTrue);
    expect(voice.value.phase, VoicePhase.idle);
    expect(tokens, ['join-1', 'join-2']);
  });

  test('waits for presence, then reports denial as text fallback', () async {
    final statuses = [409, 409, 200, 403];
    var index = 0;
    final (server, requests) = await fakeRealtime(() => [statuses[index++]]);
    addTearDown(() => server.close(force: true));
    final voice = VoiceController(
      cameraOnJoin: false,
      realtime: session(server),
      session: () => 's',
      connector: (url, token) async => FakeConnection(),
    );
    addTearDown(voice.dispose);
    await voice.join('lobby');
    expect(voice.value.phase, VoicePhase.joined);
    expect(requests.length, 3);
    await voice.follow('finance');
    expect(voice.value.phase, VoicePhase.error);
    expect(voice.value.message, contains('room chat'));
  });

  test('a server-side disconnect rejoins while voice is wanted', () async {
    final (server, requests) = await fakeRealtime(() => [200]);
    addTearDown(() => server.close(force: true));
    final connections = <FakeConnection>[];
    final voice = VoiceController(
      cameraOnJoin: false,
      realtime: session(server),
      session: () => 's',
      connector: (url, token) async {
        final c = FakeConnection();
        connections.add(c);
        return c;
      },
    );
    addTearDown(voice.dispose);
    await voice.join('lobby');
    connections.single.onClosed!();
    expect(voice.value.phase, VoicePhase.joining);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    expect(voice.value.phase, VoicePhase.joined);
    expect(connections, hasLength(2));
    expect(requests, hasLength(2));
    final speaking = <Set<String>>[];
    void record() => speaking.add(voice.value.speaking);
    voice.addListener(record);
    connections.last
      ..others = {'van'}
      ..talking = {'van'};
    connections.last.onChanged!();
    expect(voice.value.participants, {'van'});
    expect(setEquals(speaking.last, {'van'}), isTrue);
  });

  test(
    'camera preference follows room changes and failures leave voice connected',
    () async {
      final (server, _) = await fakeRealtime(() => [200]);
      addTearDown(() => server.close(force: true));
      final connections = <FakeConnection>[];
      final voice = VoiceController(
        cameraOnJoin: false,
        realtime: session(server),
        session: () => 's',
        connector: (url, token) async {
          final c = FakeConnection();
          connections.add(c);
          return c;
        },
      );
      addTearDown(voice.dispose);
      await voice.setCamera(true);
      expect(voice.value.camera, isFalse, reason: 'no camera before joining');
      await voice.join('lobby');
      expect(
        voice.value.camera,
        isTrue,
        reason: 'explicit camera preference is applied on join',
      );
      expect(connections.single.camera, isTrue);
      await voice.setCamera(true);
      expect(voice.value.camera, isTrue);
      expect(connections.single.camera, isTrue);
      await voice.follow('dev');
      expect(
        voice.value.camera,
        isTrue,
        reason: 'camera follows its explicit preference',
      );
      expect(connections.last.camera, isTrue);
      connections.last.cameraFails = true;
      await voice.setCamera(true);
      expect(voice.value.camera, isFalse);
      expect(voice.value.message, contains('Camera unavailable'));
      expect(voice.value.phase, VoicePhase.joined, reason: 'voice continues');
    },
  );
}
