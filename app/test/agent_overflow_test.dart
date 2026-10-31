import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/office/voice/live_agent_panel.dart';
import 'package:monastack/features/office/voice/voice_controller.dart';
import 'package:monastack/features/office/presence/realtime_session.dart';
import 'package:monastack/features/organization/people_profiles.dart';
import 'package:monastack/shared/workspace_theme.dart';

import 'chat/chat_nexus_support.dart' show loadNexusFonts;

void main() {
  setUpAll(loadNexusFonts);
  for (final width in [220.0, 256.0, 292.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('two agents fit sidebar $width at text scale $scale', (
        tester,
      ) async {
        final client = HttpClient();
        final controller = VoiceController(
          cameraOnJoin: false,
          realtime: RealtimeSession(client: client, issue: () async => {}),
          session: () => 'human',
        );
        final presence = ValueNotifier<List<Map<String, dynamic>>>([]);
        addTearDown(() {
          controller.dispose();
          client.close(force: true);
          presence.dispose();
        });
        final requests = <Object?>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: workspaceTheme(),
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    height: 520,
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          PeopleProfiles(
                            actors: const [
                              {
                                'id': 'dev-agent',
                                'name': 'Atlas with a deliberately long custom display name',
                                'kind': 'agent',
                                'role': 'agent',
                              },
                              {
                                'id': 'qa-agent',
                                'name': 'Iris',
                                'kind': 'agent',
                                'role': 'agent',
                              },
                            ],
                            remote: presence,
                            connectedActor: 'le-pha',
                            shrinkWrap: true,
                          ),
                          LiveAgentPanel(
                            data: {
                              'room': 'dev',
                              'agents': ['dev-agent', 'qa-agent'],
                              'selected': 'dev-agent',
                              'display_name': 'Atlas with a deliberately long custom display name',
                              'enabled': true,
                              'state': 'listening',
                              'can_control': true,
                              'activation_mode': 'automatic',
                              'operations': [],
                            },
                            controller: controller,
                            request: (method, path, [body]) async {
                              requests.add(body);
                              return {};
                            },
                            onChanged: () async {},
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final selector = find.byType(DropdownButton<String>);
        await tester.ensureVisible(selector);
        await tester.pumpAndSettle();
        await tester.tap(selector);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Iris · QA Engineer').last);
        await tester.pumpAndSettle();
        expect(requests.last, {'action': 'select', 'agent': 'qa-agent'});
        expect(tester.takeException(), isNull);
      });
    }
  }
}
