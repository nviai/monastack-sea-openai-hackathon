import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/office/rooms/room_membership.dart';

const rooms = <Map<String, dynamic>>[
  {'id': 'finance', 'name': 'Finance', 'restricted': true},
  {'id': 'lobby', 'name': 'Lobby', 'restricted': false},
];
const actors = <Map<String, dynamic>>[
  {'id': 'an', 'name': 'Synthetic Admin', 'kind': 'human'},
  {'id': 'van', 'name': 'Synthetic Member', 'kind': 'human'},
  {'id': 'bot', 'name': 'Synthetic Agent', 'kind': 'agent'},
];

void main() {
  Future<void> chooseMember(WidgetTester tester) async {
    final dropdown = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownButton<String> &&
          (widget.items?.any((item) => item.value == 'van') ?? false),
    );
    tester.widget<DropdownButton<String>>(dropdown).onChanged!('van');
    await tester.pumpAndSettle();
  }

  testWidgets(
    'room changes require confirmation and retry a lost response with the same operation',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final members = <String>[];
      final operations = <String>[];
      var version = 0;
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async {
        if (path.endsWith('/capabilities')) return {'can_manage': true};
        if (path.endsWith('/history')) return <dynamic>[];
        if (method == 'GET') {
          return {'members': List<String>.of(members), 'version': version};
        }
        final change = body as Map<String, dynamic>;
        operations.add(change['op'] as String);
        if (operations.length == 1) {
          members.add(change['actor'] as String);
          version++;
          throw const SocketException('synthetic lost response');
        }
        return null;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: RoomMembership(request: request, rooms: rooms, actors: actors),
        ),
      );
      await tester.pumpAndSettle();
      await chooseMember(tester);
      await tester.tap(find.text('Grant access'));
      await tester.pumpAndSettle();
      expect(find.text('Grant room access?'), findsOneWidget);
      expect(operations, isEmpty);
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not confirm'), findsOneWidget);
      await tester.tap(find.text('Grant access'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(operations.length, 2);
      expect(operations[0], operations[1]);
      expect(
        find.textContaining('Current members: Synthetic Member'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'revoking admin authority clears data and invalidates an open confirmation',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var allowed = true;
      var writes = 0;
      Future<dynamic> request(
        String method,
        String path, [
        Object? body,
      ]) async {
        if (path.endsWith('/capabilities')) return {'can_manage': allowed};
        if (path.endsWith('/history')) {
          return [
            {'actor': 'an', 'action': 'grant', 'subject': 'van'},
          ];
        }
        if (method == 'GET') return {'members': <String>[], 'version': 0};
        writes++;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: RoomMembership(request: request, rooms: rooms, actors: actors),
        ),
      );
      await tester.pumpAndSettle();
      await chooseMember(tester);
      await tester.tap(find.text('Grant access'));
      await tester.pumpAndSettle();
      allowed = false;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('Room administration access changed'), findsOneWidget);
      expect(find.text('Confirm'), findsNothing);
      expect(writes, 0);
      allowed = true;
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(find.text('Room administration access changed'), findsOneWidget);
      expect(find.text('Confirm'), findsNothing);
    },
  );

  testWidgets('non-admin users do not request membership details', (
    tester,
  ) async {
    final paths = <String>[];
    Future<dynamic> request(String method, String path, [Object? body]) async {
      paths.add(path);
      return {'can_manage': false};
    }

    await tester.pumpWidget(
      MaterialApp(
        home: RoomMembership(request: request, rooms: rooms, actors: actors),
      ),
    );
    await tester.pumpAndSettle();
    expect(paths, ['/v1/room-admin/capabilities']);
    expect(find.text('Room administration access denied.'), findsOneWidget);
    expect(find.text('Grant access'), findsNothing);
  });

  testWidgets('a changed membership version invalidates an open confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var version = 0;
    var writes = 0;
    Future<dynamic> request(String method, String path, [Object? body]) async {
      if (path.endsWith('/capabilities')) return {'can_manage': true};
      if (path.endsWith('/history')) return <dynamic>[];
      if (method == 'GET') return {'members': <String>[], 'version': version};
      writes++;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: RoomMembership(request: request, rooms: rooms, actors: actors),
      ),
    );
    await tester.pumpAndSettle();
    await chooseMember(tester);
    await tester.tap(find.text('Grant access'));
    await tester.pumpAndSettle();
    version++;
    await tester.pump(const Duration(seconds: 5));
    await tester.pump();
    expect(find.text('Room administration access changed'), findsOneWidget);
    expect(find.text('Confirm'), findsNothing);
    expect(writes, 0);
  });
}
