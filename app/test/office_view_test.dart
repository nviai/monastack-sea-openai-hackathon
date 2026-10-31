import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/office/world/office_world.dart';

void main() {
  testWidgets(
    'reduce motion completes a valid route without stepped animation',
    (tester) async {
      tester.view.physicalSize = const Size(800, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final remote = ValueNotifier<List<Map<String, dynamic>>>([]);
      addTearDown(remote.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OfficeWorld(
              seed: const {'rooms': []},
              remote: remote,
              actor: 'synthetic',
              findPath: (start, goal) async => [
                start,
                [3, 2],
                [4, 2],
              ],
              onPosition: (_, _) {},
              onError: (_) {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.byTooltip('Reduce motion'));
      await tester.pump();
      expect(find.byTooltip('Enable motion'), findsOneWidget);
      await tester.tapAt(const Offset(400, 250));
      await tester.pump(const Duration(milliseconds: 100));
      final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
      expect(world.current, [4, 2]);
    },
  );
  testWidgets('system reduced motion also avoids stepped animation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final remote = ValueNotifier<List<Map<String, dynamic>>>([]);
    addTearDown(remote.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: OfficeWorld(
              seed: const {'rooms': []},
              remote: remote,
              actor: 'synthetic',
              findPath: (start, goal) async => [
                start,
                [3, 2],
                [4, 2],
              ],
              onPosition: (_, _) {},
              onError: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tapAt(const Offset(400, 250));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.state<OfficeWorldState>(find.byType(OfficeWorld)).current, [
      4,
      2,
    ]);
  });
  testWidgets('zoom keeps its focal point and reset restores click targeting', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final remote = ValueNotifier<List<Map<String, dynamic>>>([]);
    addTearDown(remote.dispose);
    final destinations = <List<int>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OfficeWorld(
            seed: const {'rooms': []},
            remote: remote,
            actor: 'synthetic',
            findPath: (start, goal) async {
              destinations.add(goal);
              return null;
            },
            onPosition: (_, _) {},
            onError: (_) {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    const point = Offset(400, 250);
    await tester.tapAt(point);
    final initial = destinations.last;
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.tapAt(point);
    expect(destinations.last, initial);
    await tester.dragFrom(point, const Offset(80, 0));
    await tester.tapAt(point);
    expect(destinations.last, isNot(initial));
    await tester.tap(find.byTooltip('Reset view'));
    await tester.tapAt(point);
    expect(destinations.last, initial);
  });
  testWidgets('clicking an offline agent opens its profile, not a walk', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final remote = ValueNotifier<List<Map<String, dynamic>>>([]);
    addTearDown(remote.dispose);
    final selected = <String>[];
    final walks = <List<int>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OfficeWorld(
            seed: const {
              'rooms': [],
              'actors': [
                {'id': 'mona', 'name': 'Mona', 'kind': 'agent'},
              ],
            },
            remote: remote,
            actor: 'synthetic',
            findPath: (start, goal) async {
              walks.add(goal);
              return null;
            },
            onPosition: (_, _) {},
            onError: (_) {},
            onSelectActor: selected.add,
          ),
        ),
      ),
    );
    final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
    // The asset read completes on the real event loop.
    for (var i = 0; i < 100 && world.map == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump(const Duration(milliseconds: 50));
    final seat = world.map!.desks.firstWhere((d) => d.assignee == 'mona').seat;
    final game = world.game;
    final body = game.toScreen(
      game.iso.project(seat.x.toDouble(), seat.y.toDouble(), 20),
    );
    await tester.tapAt(body);
    await tester.pump(const Duration(milliseconds: 50));
    expect(selected, ['mona']);
    expect(walks, isEmpty);
    await tester.tapAt(game.toScreen(game.iso.project(14, 14)));
    expect(walks, [
      [14, 14],
    ]);
  });

  testWidgets('live camera views replace faces and open the profile', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final remote = ValueNotifier<List<Map<String, dynamic>>>([
      {
        'session': 's2',
        'actor': 'van',
        'room': 'lobby',
        'x': 12,
        'y': 13,
        'seq': 1,
      },
    ]);
    addTearDown(remote.dispose);
    final faces = ValueNotifier<Map<String, Widget>>(const {});
    addTearDown(faces.dispose);
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OfficeWorld(
            seed: const {'rooms': []},
            remote: remote,
            actor: 'synthetic',
            findPath: (start, goal) async => null,
            onPosition: (_, _) {},
            onError: (_) {},
            onSelectActor: selected.add,
            faces: faces,
          ),
        ),
      ),
    );
    final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
    for (var i = 0; i < 100 && world.map == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 50));
    expect(world.game.faceSlots, isEmpty, reason: 'no camera, drawn faces');
    faces.value = {
      'synthetic': const ColoredBox(key: Key('cam-self'), color: Colors.red),
      'van': const ColoredBox(key: Key('cam-van'), color: Colors.blue),
    };
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('cam-self')), findsOneWidget);
    expect(find.byKey(const Key('cam-van')), findsOneWidget);
    final game = world.game;
    final van = game.faceSlots.firstWhere((f) => f.actor == 'van');
    // The bubble sits where the head would be, above the feet.
    final feet = game.toScreen(game.iso.project(12, 13));
    expect(van.center.dx, closeTo(feet.dx, 1));
    expect(van.center.dy, lessThan(feet.dy));
    expect(van.diameter, greaterThanOrEqualTo(30));
    expect(
      tester.getRect(find.byKey(const Key('cam-van'))).center.dx,
      closeTo(van.center.dx, 1),
    );
    await tester.tapAt(van.center);
    await tester.pump(const Duration(milliseconds: 50));
    expect(selected, ['van']);
    faces.value = const {};
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('cam-van')), findsNothing);
    expect(game.faceSlots, isEmpty);
  });
}
