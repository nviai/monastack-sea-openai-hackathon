import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/office/voice/live_agent_panel.dart';
import 'package:monastack/features/office/voice/voice_controller.dart';
import 'package:monastack/features/office/presence/realtime_session.dart';

import 'dart:io';

void main() {
  testWidgets(
    'room agent controls route approval and selection to authenticated APIs',
    (tester) async {
      final client = HttpClient();
      final controller = VoiceController(
        cameraOnJoin: false,
        realtime: RealtimeSession(client: client, issue: () async => {}),
        session: () => 'human',
      );
      addTearDown(() {
        controller.dispose();
        client.close(force: true);
      });
      final requests = <List<Object?>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LiveAgentPanel(
                data: {
                  'room': 'dev',
                  'agents': ['dev-agent', 'qa-agent'],
                  'selected': 'dev-agent',
                  'enabled': true,
                  'state': 'listening',
                  'can_control': true,
                  'captions': [
                    {'speaker': 'dev-agent', 'text': 'Ready'},
                  ],
                  'operations': [
                    {
                      'id': 'operation-1',
                      'title': 'Review release',
                      'project': 'project-1',
                    },
                  ],
                },
                controller: controller,
                request: (method, path, [body]) async {
                  requests.add([method, path, body]);
                  return {};
                },
                onChanged: () async {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('Create task: Review release'), findsOneWidget);
      expect(find.text('dev-agent: Ready'), findsNothing);
      expect(find.byIcon(Icons.volume_up_rounded), findsOneWidget);
      await tester.tap(find.text('Approve task'));
      await tester.pumpAndSettle();
      expect(requests.last, [
        'POST',
        '/v1/live-agents/operations/operation-1',
        {'action': 'approve'},
      ]);
      await tester.tap(find.text('Pause agent'));
      await tester.pumpAndSettle();
      expect(requests.last, [
        'POST',
        '/v1/live-agents/rooms/dev',
        {'action': 'pause'},
      ]);
      await tester.tap(find.text('Mute agent'));
      await tester.pumpAndSettle();
      expect(controller.agentMuted, true);
      expect(find.text('Unmute agent'), findsOneWidget);
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
    },
  );
}
