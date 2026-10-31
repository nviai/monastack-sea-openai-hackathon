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
}
