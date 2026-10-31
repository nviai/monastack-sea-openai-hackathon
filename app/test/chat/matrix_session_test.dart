import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:monastack/features/chat/data/matrix_session.dart';
import 'package:monastack/features/chat/domain/chat_client.dart';
import 'package:monastack/features/chat/data/matrix_chat_client.dart';
import 'package:monastack/features/identity/credential_store.dart';

const matrixUser = '@test:fakeServer.notExisting';
const matrixRoom = '!1234:fakeServer.notExisting';

class RecordingMatrixTransport extends FakeMatrixApi {
  RecordingMatrixTransport() {
    servers.add('http://127.0.0.1:8008');
  }
  final requests = <http.Request>[];
  final sends = <String, String>{};
  bool dropSendResponse = false;
  int batch = 0;
  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    Object response;
    if (path.endsWith('/account/whoami')) {
      response = {'user_id': matrixUser, 'device_id': 'GHTYAJCE'};
    } else if (path.endsWith('/sync')) {
      response = {
        'next_batch': 'batch-${batch++}',
        'rooms': {
          'join': {
            matrixRoom: {
              'state': {
                'events': [
                  {
                    'event_id': r'$member',
                    'origin_server_ts': 1,
                    'type': 'm.room.member',
                    'state_key': matrixUser,
                    'sender': matrixUser,
                    'content': {'membership': 'join', 'displayname': 'Test'},
                  },
                  {
                    'event_id': r'$name',
                    'origin_server_ts': 2,
                    'type': 'm.room.name',
                    'state_key': '',
                    'sender': matrixUser,
                    'content': {'name': 'Lobby'},
                  },
                ],
              },
              'timeline': {
                'prev_batch': 'older',
                'events': [
                  {
                    'event_id': r'$one',
                    'type': 'm.room.message',
                    'sender': matrixUser,
                    'origin_server_ts': 100,
                    'content': {'msgtype': 'm.text', 'body': 'Synced message'},
                  },
                ],
              },
              'unread_notifications': {
                'notification_count': 2,
                'highlight_count': 1,
              },
            },
          },
        },
      };
      if (batch > 1) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } else if (path.contains('/send/m.room.message/')) {
      final txn = path.split('/').last;
      final event = sends.putIfAbsent(txn, () => r'$sent');
      if (dropSendResponse) {
        dropSendResponse = false;
        throw StateError('Lost response after server acceptance');
      }
      response = {'event_id': event};
    } else if (path.endsWith('/search')) {
      response = {
        'search_categories': {
          'room_events': {
            'results': [
              {
                'result': {
                  'room_id': matrixRoom,
                  'event_id': r'$old',
                  'type': 'm.room.message',
                  'sender': matrixUser,
                  'origin_server_ts': 1,
                  'content': {
                    'msgtype': 'm.text',
                    'body': 'From older server history',
                  },
                },
              },
            ],
          },
        },
      };
    } else {
      return super.mockIntercept(request);
    }
    return http.Response(
      jsonEncode(response),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  late MemoryCredentialStore store;
  late RecordingMatrixTransport transport;
  late List<String> nodeCalls;
  late bool enabled;
  late MatrixSession session;
  Future<dynamic> node(String method, String path, [Object? body]) async {
    nodeCalls.add('$method $path');
    return switch (path) {
      '/v1/chat/config' => {
        'enabled': enabled,
        'homeserver_url': 'http://127.0.0.1:8008',
        'server_name': 'test',
      },
      '/v1/chat/session' => {
        'user_id': matrixUser,
        'login_token': 'test-jwt',
        'expires_in': 60,
      },
      '/v1/chat/rooms' => [
        {
          'office_room': 'lobby',
          'matrix_room_id': matrixRoom,
          'name': 'Lobby',
          'topic': '',
          'restricted': false,
        },
      ],
      '/v1/chat/users' => [
        {
          'actor': 'test',
          'user_id': matrixUser,
          'name': 'Test',
          'kind': 'human',
        },
      ],
      _ => throw StateError('Unexpected node endpoint'),
    };
  }

  setUp(() {
    store = MemoryCredentialStore();
    transport = RecordingMatrixTransport();
    nodeCalls = [];
    enabled = true;
    session = MatrixSession(
      request: node,
      store: store,
      node: '127.0.0.1:47830',
      actor: 'test',
      httpClient: transport,
    );
  });
  tearDown(() async {
    await session.close();
  });
  test('disabled config opens no Matrix connection', () async {
    enabled = false;
    expect(await session.open(), isNull);
    final adapter = MatrixChatClient(session);
    await adapter.refreshRooms();
    adapter.dispose();
    expect(nodeCalls, ['GET /v1/chat/config']);
    expect(transport.requests, isEmpty);
  });
  test('JWT login uses SDK sync, keychain restore and device logout', () async {
    final sdk = await session.open();
    expect(sdk, isNotNull);
    expect(sdk!.encryptionEnabled, isFalse);
    expect(store.values.keys, contains(session.key));
    final login = transport.requests.singleWhere(
      (r) => r.method == 'POST' && r.url.path.endsWith('/login'),
    );
    expect(
      jsonDecode(login.body),
      containsPair('type', 'org.matrix.login.jwt'),
    );
    expect(jsonDecode(login.body), containsPair('token', 'test-jwt'));
    expect(transport.requests.any((r) => r.url.path.endsWith('/sync')), isTrue);
    await session.close();
    final second = MatrixSession(
      request: node,
      store: store,
      node: '127.0.0.1:47830',
      actor: 'test',
      httpClient: transport,
    );
    session = second;
    await second.open();
    expect(nodeCalls.where((v) => v == 'POST /v1/chat/session').length, 1);
    await second.logout();
    expect(store.values, isEmpty);
    expect(
      transport.requests.any((r) => r.url.path.endsWith('/logout')),
      isTrue,
    );
  });
  test('node and actor keys are isolated', () async {
    await session.open();
    final otherActor = MatrixSession(
      request: node,
      store: store,
      node: '127.0.0.1:47830',
      actor: 'different',
      httpClient: transport,
    );
    final otherNode = MatrixSession(
      request: node,
      store: store,
      node: '127.0.0.1:47840',
      actor: 'test',
      httpClient: transport,
    );
    expect(otherActor.key, isNot(session.key));
    expect(otherNode.key, isNot(session.key));
    await otherActor.open();
    await otherNode.open();
    expect(nodeCalls.where((v) => v == 'POST /v1/chat/session').length, 3);
    await otherActor.logout();
    await otherNode.logout();
    expect(store.values.keys, [session.key]);
  });
  test('real SDK adapter sends one transaction and searches server history', () async {
    final client = MatrixChatClient(session);
    await client.start();
    expect(
      client.phase,
      ChatPhase.ready,
      reason: Logs().outputEvents
          .map((e) => '${e.title}: ${e.exception?.runtimeType}')
          .join('\n'),
    );
    expect(
      client.rooms.map((r) => r.id),
      contains(matrixRoom),
      reason:
          'SDK rooms: ${client.sdk.rooms.map((r) => '${r.id}:${r.membership}')}; requests: ${transport.requests.map((r) => r.url.path)}; logs: ${Logs().outputEvents.map((e) => e.title)}',
    );
    await client.load(matrixRoom);
    expect(
      client.messages(matrixRoom).any((m) => m.body == 'Synced message'),
      isTrue,
    );
    transport.dropSendResponse = true;
    await client.send(matrixRoom, 'Hello @other:monastack.local', 'stable-txn');
    expect(
      transport.requests
          .where((r) => r.url.path.contains('/send/m.room.message/'))
          .length,
      2,
    );
    expect(transport.sends.length, 1);
    final sent = transport.requests.lastWhere(
      (r) => r.url.path.contains('/send/m.room.message/'),
    );
    expect((jsonDecode(sent.body)['m.mentions'] as Map)['user_ids'], [
      '@other:monastack.local',
    ]);
    final result = await client.search('older');
    expect(result.messages.single.body, 'From older server history');
    final search = transport.requests.lastWhere(
      (r) => r.url.path.endsWith('/search'),
    );
    expect(
      jsonDecode(
        search.body,
      )['search_categories']['room_events']['filter']['rooms'],
      [matrixRoom],
    );
    await client.signOut();
    client.dispose();
  });
}
