import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/office/presence/realtime_session.dart';

void main() {
  test('only loopback HTTP realtime endpoints are accepted', () {
    expect(RealtimeSession.parseBase('http://127.0.0.1:47831'), isNotNull);
    for (final value in [
      'https://127.0.0.1:47831',
      'http://localhost:47831',
      'http://10.0.0.2:47831',
      'http://127.0.0.1',
      'http://127.0.0.1:47831/v1',
      42,
    ]) {
      expect(RealtimeSession.parseBase(value), isNull, reason: '$value');
    }
  });

  test('a rejected ticket is replaced once and the call retried', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final seen = <String?>[];
    server.listen((request) async {
      final auth = request.headers.value(HttpHeaders.authorizationHeader);
      seen.add(auth);
      if (auth == 'Ticket stale') {
        request.response.statusCode = 401;
      } else {
        request.response.write(jsonEncode([]));
      }
      await request.response.close();
    });
    var issued = 0;
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final session = RealtimeSession(
      client: client,
      issue: () async => {
        'ticket': issued++ == 0 ? 'stale' : 'fresh',
        'expires_in': 30,
        'realtime_url': 'http://127.0.0.1:${server.port}',
      },
    );
    expect(await session.request('GET', '/v1/presence'), isEmpty);
    expect(seen, ['Ticket stale', 'Ticket fresh']);
    expect(issued, 2);
  });

  test('a non-loopback ticket response is refused before any request', () {
    final session = RealtimeSession(
      client: HttpClient(),
      issue: () async => {
        'ticket': 'x',
        'expires_in': 30,
        'realtime_url': 'http://203.0.113.1:47831',
      },
    );
    expect(session.request('GET', '/v1/presence'), throwsFormatException);
  });
}
