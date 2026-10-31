import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/identity/auth_api.dart';
import 'package:monastack/features/identity/auth_session.dart';
import 'package:monastack/features/identity/credential_store.dart';

/// A loopback node that issues sessions and counts refreshes. `refreshStatus`
/// picks the answer to each refresh.
class FakeNode {
  late HttpServer server;
  int refreshes = 0;
  int logouts = 0;
  int refreshStatus = 200;
  int expiresIn = 600;
  String? lastLogoutBearer;

  Map<String, dynamic> signedIn(int n) => {
    'access_token': 'v1.access-$n',
    'expires_in': expiresIn,
    'refresh_token': 'refresh-$n',
    'session': 'session-1',
    'actor': 'an',
    'name': 'Synthetic An',
    'username': 'an',
    'admin': true,
    'workspace': {'id': 'w', 'name': 'Synthetic Co'},
  };

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      switch (request.uri.path) {
        case '/v1/auth/refresh':
          refreshes++;
          // Slow enough for concurrent callers to overlap.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          request.response.statusCode = refreshStatus;
          if (refreshStatus == 200) {
            final presented = jsonDecode(body)['refresh_token'] as String;
            final n = int.parse(presented.split('-').last) + 1;
            request.response.write(jsonEncode(signedIn(n)));
          }
        case '/v1/auth/logout':
          logouts++;
          lastLogoutBearer = request.headers.value('authorization');
          request.response.statusCode = 204;
        default:
          request.response.statusCode = 404;
      }
      await request.response.close();
    });
  }
}

void main() {
  late FakeNode node;
  late MemoryCredentialStore store;
  late AuthSession auth;
  const key = 'monastack.session.127.0.0.1';

  setUp(() async {
    node = FakeNode();
    await node.start();
    store = MemoryCredentialStore();
    auth = AuthSession(
      api: AuthApi(port: node.server.port),
      store: store,
    );
  });
  tearDown(() => node.server.close(force: true));

  String stored() =>
      jsonDecode(store.values['$key:${node.server.port}']!)['refresh_token']
          as String;

  test('restores from the keychain and saves each rotated token', () async {
    store.values['$key:${node.server.port}'] = jsonEncode({
      'refresh_token': 'refresh-1',
    });
    expect(await auth.restore(), isTrue);
    expect(auth.signedIn, isTrue);
    expect(auth.account!.workspaceName, 'Synthetic Co');
    expect(await auth.bearer(), 'v1.access-2');
    expect(stored(), 'refresh-2');
  });

  test(
    'renews before expiry with one request for concurrent callers',
    () async {
      node.expiresIn = 30; // inside the 60 s renewal margin
      await auth.adopt(SignedIn.fromJson(node.signedIn(1)));
      final bearers = await Future.wait([
        for (var i = 0; i < 5; i++) auth.bearer(),
      ]);
      expect(node.refreshes, 1, reason: 'a refresh token is presented once');
      expect(bearers.toSet(), {'v1.access-2'});
      expect(stored(), 'refresh-2');
    },
  );

  test('a revoked session signs out and forgets the token', () async {
    await auth.adopt(SignedIn.fromJson(node.signedIn(1)));
    node.refreshStatus = 401;
    var notified = 0;
    auth.addListener(() => notified++);
    expect(await auth.refreshNow(), isFalse);
    expect(auth.active, isFalse);
    expect(auth.notice, contains('Sign in again'));
    expect(store.values, isEmpty);
    expect(notified, greaterThan(0));
  });

  test('an unreachable node keeps the session for a later retry', () async {
    await auth.adopt(SignedIn.fromJson(node.signedIn(1)));
    await node.server.close(force: true);
    expect(await auth.refreshNow(), isFalse);
    expect(auth.signedIn, isTrue);
    expect(store.values, isNotEmpty);
  });

  test('sign-out ends the session on the node and here', () async {
    await auth.adopt(SignedIn.fromJson(node.signedIn(1)));
    await auth.signOut();
    expect(node.logouts, 1);
    expect(node.lastLogoutBearer, 'Bearer v1.access-1');
    expect(auth.active, isFalse);
    expect(store.values, isEmpty);
  });

  test('device tokens are used as given and never stored', () async {
    auth.useDeviceToken('local-device-token');
    expect(auth.active, isTrue);
    expect(auth.signedIn, isFalse);
    expect(await auth.bearer(), 'local-device-token');
    expect(store.values, isEmpty);
    await auth.signOut();
    expect(auth.active, isFalse);
    expect(node.logouts, 0);
  });
}
