import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:monastack/app/monastack_app.dart';
import 'package:monastack/features/office/data/office_core.dart';
import 'package:monastack/features/office/world/office_world.dart';
import 'package:monastack/platform/core_bridge.dart';

void main() {
  // The bridge completes on real ports, so the core is loaded outside the
  // widget test's fake clock and injected through the provider.
  late OfficeCore core;
  setUpAll(() async {
    await CoreBridge.ensureInitialized();
    core = await OfficeCore.load(
      seedJson: File('assets/seed.v1.json').readAsStringSync(),
      mapJson: File('assets/map.v2.json').readAsStringSync(),
    );
  });
  tearDownAll(() => core.dispose());
  testWidgets(
    'room navigation follows the native route and denies private rooms',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [officeCoreProvider.overrideWith((ref) => core)],
          child: const Monastack(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      for (
        var i = 0;
        i < 10 && find.byType(OfficeWorld).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('NVIAI Smart Technology'), findsOneWidget);
      expect(find.text('Local node optional'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
      for (var i = 0; i < 5 && world.map == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.runAsync(() => world.goToRoom('dev'));
      for (var i = 0; i < 200 && world.current.toString() != '[3, 3]'; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(world.current, [3, 3]);
      await tester.tap(find.text('Finance').first);
      await tester.pump();
      expect(find.textContaining('Access denied'), findsOneWidget);
      expect(world.current, [3, 3]);
      world.policyChanged(reset: true);
      expect(world.current, [14, 13]);
    },
  );
}
