import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/tasks/task_board.dart';

void main() {
  testWidgets('read-only member can inspect tasks without edit controls', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path == '/v1/projects') {
        return [
          {
            'id': '0123456789abcdef',
            'name': 'Restricted',
            'private': true,
            'can_edit': false,
          },
        ];
      }
      if (path.endsWith('/tasks')) {
        return [
          {
            'id': 'abcdef0123456789',
            'title': 'Readable task',
            'assignee': null,
            'state': 'todo',
            'version': 1,
          },
        ];
      }
      throw StateError('unexpected request');
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: TaskBoard(request: request, actors: const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restricted').last);
    await tester.pumpAndSettle();
    expect(find.text('Readable task'), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsNothing);
    await tester.enterText(find.byType(TextField), 'not-a-match');
    await tester.pumpAndSettle();
    expect(find.text('Readable task'), findsNothing);
    await tester.enterText(find.byType(TextField), 'Readable');
    await tester.pumpAndSettle();
    expect(find.text('Readable task'), findsOneWidget);
    expect(find.text('Task'), findsNothing);
    expect(find.text('Assign'), findsNothing);
    expect(find.text('Start'), findsNothing);
    expect(find.text('History'), findsOneWidget);
  });
  testWidgets('board creates a project and task and transitions it', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    final projects = <Map<String, dynamic>>[];
    final tasks = <Map<String, dynamic>>[];
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (method == 'GET' && path == '/v1/projects') return List.of(projects);
      if (method == 'POST' && path == '/v1/projects') {
        final p = body as Map<String, dynamic>;
        projects.add({'id': p['id'], 'name': p['name']});
        return null;
      }
      if (method == 'GET' && path.endsWith('/tasks')) return List.of(tasks);
      if (method == 'POST' && path.endsWith('/tasks')) {
        final t = body as Map<String, dynamic>;
        tasks.add({...t, 'state': 'todo', 'version': 1});
        return null;
      }
      if (method == 'POST' && path.endsWith('/transition')) {
        final t = body as Map<String, dynamic>;
        tasks.first['state'] = t['to'];
        tasks.first['version'] = 2;
        return null;
      }
      throw StateError('Unexpected operation');
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: TaskBoard(request: request, actors: const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Project'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Example project',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Example project').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Task'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Example task',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unassigned').last);
    await tester.pumpAndSettle();
    expect(find.text('Example task'), findsOneWidget);
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(tasks.single['state'], 'in_progress');
    expect(find.text('Done'), findsWidgets);
  });
  testWidgets('private project owner can invite a member', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.physicalSize = const Size(1400, 900);
    addTearDown(tester.view.resetPhysicalSize);
    final projects = <Map<String, dynamic>>[];
    final members = <String>['an'];
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (method == 'GET' && path == '/v1/projects') return List.of(projects);
      if (method == 'POST' && path == '/v1/projects') {
        final p = body as Map<String, dynamic>;
        projects.add({
          'id': p['id'],
          'name': p['name'],
          'private': p['private'],
          'owner': 'an',
        });
        return null;
      }
      if (method == 'GET' && path.endsWith('/tasks')) return [];
      if (method == 'GET' && path.endsWith('/members')) {
        return {
          'owner': 'an',
          'private': true,
          'can_manage': true,
          'members': List.of(members),
        };
      }
      if (method == 'POST' && path.endsWith('/members')) {
        final data = body as Map<String, dynamic>;
        if (data['action'] == 'grant') {
          members.add(data['actor'] as String);
        } else {
          members.remove(data['actor']);
        }
        return null;
      }
      throw StateError('Unexpected request');
    }

    const actors = [
      {'id': 'an', 'name': 'An', 'kind': 'human'},
      {'id': 'van', 'name': 'Van', 'kind': 'human'},
    ];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: TaskBoard(request: request, actors: actors),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Project'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Restricted',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restricted').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Members'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invite'));
    await tester.pumpAndSettle();
    expect(members, contains('van'));
    expect(find.text('Editor'), findsOneWidget);
  });
}
