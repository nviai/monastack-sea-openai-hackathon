import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/organization/people_profiles.dart';

void main() {
  testWidgets(
    'profiles show filtered presence without assuming absence is offline',
    (tester) async {
      final remote = ValueNotifier<List<Map<String, dynamic>>>([]);
      addTearDown(remote.dispose);
      const actors = [
        {'id': 'one', 'name': 'Person One', 'kind': 'human', 'role': 'dev'},
        {'id': 'two', 'name': 'Person Two', 'kind': 'human', 'role': 'sales'},
        {'id': 'bot', 'name': 'Agent', 'kind': 'agent', 'role': 'assistant'},
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PeopleProfiles(
              actors: actors,
              remote: remote,
              connectedActor: 'one',
            ),
          ),
        ),
      );
      expect(find.text('dev · this session'), findsOneWidget);
      expect(find.text('sales · not currently visible'), findsOneWidget);
      expect(find.text('Agent · offline'), findsOneWidget);
      remote.value = [
        {'actor': 'two'},
      ];
      await tester.pump();
      expect(find.text('sales · visible in office'), findsOneWidget);
      remote.value = [];
      await tester.pump();
      expect(find.text('sales · visible in office'), findsNothing);
      expect(find.text('sales · not currently visible'), findsOneWidget);
      await tester.tap(find.text('Person Two'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('absence does not imply offline'),
        findsOneWidget,
      );
    },
  );
  testWidgets('disconnected preview does not treat a stale snapshot as live', (
    tester,
  ) async {
    final remote = ValueNotifier<List<Map<String, dynamic>>>([
      {'actor': 'two'},
    ]);
    addTearDown(remote.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PeopleProfiles(
            actors: const [
              {
                'id': 'two',
                'name': 'Person Two',
                'kind': 'human',
                'role': 'sales',
              },
            ],
            remote: remote,
            connectedActor: null,
          ),
        ),
      ),
    );
    expect(find.text('sales · status unavailable'), findsOneWidget);
    expect(find.text('sales · visible in office'), findsNothing);
  });
}
