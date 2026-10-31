import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/agents/agent_chat.dart';
import 'package:monastack/features/agents/ui_actions.dart';
import 'package:monastack/shared/node_request.dart';

const actors = [
  {'id': 'dev-agent', 'name': 'Dev Agent', 'kind': 'agent', 'role': 'agent'},
  {'id': 'qa-agent', 'name': 'QA Agent', 'kind': 'agent', 'role': 'agent'},
];
void main() {
  testWidgets(
    'UI tool calls execute locally and report results before the final answer',
    (tester) async {
      late BuildContext root;
      final opened = <String>[];
      var calls = 0;
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async {
        if (method == 'GET') return {'configured': true, 'model': 'test'};
        final payload = body as Map;
        calls++;
        if (calls == 1) {
          expect(
            (payload['ui_controls'] as List).any(
              (c) => c['id'] == 'open:tasks',
            ),
            isTrue,
          );
          return {
            'ui_action': {'id': 'open:tasks', 'value': ''},
            'ui_call_id': 'call-1',
            'ui_history': [],
            'text': 'Working',
          };
        }
        expect((payload['ui_history'] as List).last['call_id'], 'call-1');
        return {'text': 'Task board opened.'};
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              root = context;
              return Scaffold(
                body: AgentChat(
                  request: request,
                  actors: actors,
                  uiActions: UiActions(
                    root: () => root,
                    active: () => true,
                    navigate: opened.add,
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Open task board');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(opened, ['tasks']);
      expect(calls, 2);
      expect(find.text('Task board opened.'), findsOneWidget);
    },
  );
  testWidgets('sends selected agent history and keeps agents separate', (
    tester,
  ) async {
    final calls = <String>[];
    final payloads = <Map<String, dynamic>>[];
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (method == 'GET') return {'configured': true, 'model': 'test-model'};
      calls.add(path);
      payloads.add(body as Map<String, dynamic>);
      return {'text': 'Agent reply', 'incomplete': false};
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentChat(
            request: request,
            actors: actors,
            initialAgent: 'qa-agent',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'First question');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(calls.single, '/v1/agents/qa-agent/chat');
    expect(find.text('Agent reply'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Follow up');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect((payloads.last['messages'] as List).length, 3);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dev Agent · Software Engineer').last);
    await tester.pumpAndSettle();
    expect(find.text('Agent reply'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Dev question');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(calls.last, '/v1/agents/dev-agent/chat');
    expect((payloads.last['messages'] as List).length, 1);
  });

  testWidgets('failed provider calls retain draft for retry', (tester) async {
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (method == 'GET') return {'configured': true, 'model': 'test-model'};
      throw const NodeFailure(429);
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentChat(request: request, actors: actors),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep my question');
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(find.text('Keep my question'), findsOneWidget);
    expect(find.textContaining('quota'), findsOneWidget);
    expect(find.text('You'), findsNothing);
  });

  testWidgets('missing backend key disables sending', (tester) async {
    Future<dynamic> request(String method, String path, [Object? body]) async =>
        {'configured': false, 'model': 'test-model'};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentChat(request: request, actors: actors),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == 'Send',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      find.text('OpenAI is not configured on this office node.'),
      findsOneWidget,
    );
  });
}
