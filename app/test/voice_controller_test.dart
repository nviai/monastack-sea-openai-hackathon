import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/office/presence/realtime_session.dart';
import 'package:monastack/features/office/voice/voice_controller.dart';

class FakeConnection extends VoiceConnection {
  bool microphone = false;
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
  Future<void> setMicrophone(bool enabled) async => microphone = enabled;
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

  test('joins muted, follows the room and leaves on request', () async {
    final (server, requests) = await fakeRealtime(() => [200]);
    addTearDown(() => server.close(force: true));
    final connections = <FakeConnection>[];
    final tokens = <String>[];
    final voice = VoiceController(
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
}
