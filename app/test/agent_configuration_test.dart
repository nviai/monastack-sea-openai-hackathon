import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/agents/agent_configuration.dart';

Map<String, dynamic> fixture(bool manage) => {
  'can_manage': manage,
  'agents': [
    {
      'id': 'mona',
      'version': 0,
      'config': {
        'display_name': 'Mona',
        'gender': 'unspecified',
        'voice': 'marin',
        'system_prompt': 'Coordinator prompt',
        'enabled': true,
        'greeting': true,
        'language': 'auto',
        'tools': ['workspace'],
        'actions': ['workspace.read'],
        'idle_seconds': 60,
        'session_seconds': 600,
      },
    },
  ],
  'catalog': {
    'tools': ['workspace'],
    'voices': [
      {'id': 'marin', 'presentation': 'feminine'},
      {'id': 'cedar', 'presentation': 'masculine'},
      {'id': 'alloy', 'presentation': 'neutral'},
    ],
    'actions': [
      {
        'id': 'workspace.read',
        'label': 'Read projects',
        'tool': 'workspace',
        'supported': true,
      },
      {'id': 'code.execute', 'label': 'Execute shell', 'supported': false},
    ],
  },
};
void main() {
  testWidgets(
    'gender filters voices and save sends the current version and capabilities',
    (tester) async {
      final writes = <Object?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentConfiguration(
              request: (method, path, [body]) async {
                if (method == 'PUT') {
                  writes.add(body);
                  return {};
                }
                return path.endsWith('/audit') ? [] : fixture(true);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Male'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Male agent avatar'), findsOneWidget);
      expect(find.text('cedar'), findsOneWidget);
      expect(find.text('marin'), findsNothing);
      await tester.tap(find.text('Female'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Female agent avatar'), findsOneWidget);
      expect(find.text('marin'), findsOneWidget);
      expect(find.text('cedar'), findsNothing);
      await tester.tap(find.text('Male'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save configuration'));
      await tester.pumpAndSettle();
      final body = writes.single as Map;
      expect(body['version'], 0);
      expect(body['config']['gender'], 'male');
      expect(body['config']['voice'], 'cedar');
    },
  );
  testWidgets('activation mode and per-agent timeouts are editable and saved', (
    tester,
  ) async {
    final writes = <Object?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfiguration(
            request: (method, path, [body]) async {
              if (method == 'PUT') {
                writes.add(body);
                return {};
              }
              return path.endsWith('/audit') ? [] : fixture(true);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final mode = find.byWidgetPredicate(
      (w) =>
          w is DropdownButtonFormField<String> &&
          w.decoration.labelText == 'Start GPT-Live',
    );
    await tester.ensureVisible(mode);
    await tester.tap(mode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Automatic on room entry').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Starts a billed Live session'), findsOneWidget);
    final idle = find.widgetWithText(
      TextFormField,
      'No speech timeout (seconds)',
    );
    await tester.ensureVisible(idle);
    await tester.enterText(idle, '180');
    final muted = find.widgetWithText(
      TextFormField,
      'All microphones muted timeout (seconds)',
    );
    await tester.ensureVisible(muted);
    await tester.enterText(muted, '30');
    await tester.tap(find.text('Save configuration'));
    await tester.pumpAndSettle();
    final body = writes.single as Map;
    expect(body['config']['activation_mode'], 'automatic');
    expect(body['config']['idle_seconds'], 180);
    expect(body['config']['muted_idle_seconds'], 30);
  });
  testWidgets('members have no edit or save controls', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfiguration(
            request: (method, path, [body]) async => fixture(false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Save configuration'), findsNothing);
    expect(find.textContaining('Read-only.'), findsOneWidget);
    expect(find.text('System prompt'), findsNothing);
  });
}
