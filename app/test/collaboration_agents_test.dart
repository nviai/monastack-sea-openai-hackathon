import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/identity/auth_api.dart';
import 'package:monastack/features/identity/auth_session.dart';
import 'package:monastack/features/identity/credential_store.dart';
import 'package:monastack/features/office/communication/collaboration.dart';
import 'package:monastack/shared/node_request.dart';

class TestCollaboration extends Collaboration {
  const TestCollaboration({
    super.key,
    required super.room,
    required super.position,
    required super.remote,
    required super.agentPresentation,
  }) : super(
         actors: const [],
         rooms: const [],
         onIdentity: ignoreIdentity,
         onPermissions: ignorePermissions,
       );
  static void ignoreIdentity(String? _) {}
  static void ignorePermissions(List<String> _) {}
  @override
  CollaborationState createState() => TestCollaborationState();
}

class TestCollaborationState extends CollaborationState {
  final AuthSession _testAuth = AuthSession(
    api: AuthApi(port: 1),
    store: MemoryCredentialStore(),
  );
  @override
  AuthSession get auth => _testAuth;
  bool roomDenied = false;
  @override
  Future<dynamic> request(String method, String path, [Object? body]) async {
    if (path == '/v1/agents/appearances') {
      return [
        {'id': 'mona', 'name': 'Mona', 'gender': 'female', 'voice': 'marin'},
        {'id': 'qa-agent', 'name': 'Iris', 'gender': 'female', 'voice': 'sage'},
        {
          'id': 'dev-agent',
          'name': 'Atlas',
          'gender': 'male',
          'voice': 'cedar',
        },
      ];
    }
    if (path.startsWith('/v1/live-agents/rooms/')) {
      if (roomDenied) throw const NodeFailure(403);
      return {
        'selected': 'mona',
        'state': 'offline',
        'display_name': 'Mona',
        'gender': 'female',
        'voice': 'marin',
        'captions': [
          {'speaker': 'mona', 'text': 'Lobby reply', 'at': 100},
        ],
      };
    }
    throw StateError('Unexpected request: $path');
  }

  @override
  Future<void> refresh() async {}
  @override
  Future<void> refreshPresence() async {}
}

void main() {
  testWidgets(
    'Matrix session preserves all agent appearances across room changes and room denial',
    (tester) async {
      final key = GlobalKey<CollaborationState>();
      final presentation = ValueNotifier<Map<String, dynamic>>({});
      final position = ValueNotifier<List<int>>([0, 0]);
      final remote = ValueNotifier<List<Map<String, dynamic>>>([]);
      Widget office(String room) => MaterialApp(
        home: Scaffold(
          body: TestCollaboration(
            key: key,
            room: room,
            position: position,
            remote: remote,
            agentPresentation: presentation,
          ),
        ),
      );
      await tester.pumpWidget(office('lobby'));
      final state = key.currentState! as TestCollaborationState;
      state.identity = 'an';
      await state.refreshAgentAppearances();
      expect(presentation.value['qa-agent']['name'], 'Iris');
      expect(presentation.value['dev-agent']['gender'], 'male');
      await state.refreshLiveAgent();
      expect(presentation.value.length, 3);
      expect(presentation.value['mona']['text'], 'Lobby reply');
      await tester.pumpWidget(office('dev'));
      expect(presentation.value.length, 3);
      expect(presentation.value['mona']['text'], '');
      expect(presentation.value['qa-agent']['gender'], 'female');
      state.roomDenied = true;
      await state.refreshLiveAgent();
      expect(presentation.value.length, 3);
      expect(presentation.value['dev-agent']['name'], 'Atlas');
      await tester.pumpWidget(const SizedBox());
      presentation.dispose();
      position.dispose();
      remote.dispose();
    },
  );
}
