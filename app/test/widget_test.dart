import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:monastack/main.dart';
import 'package:monastack/office_world.dart';

void main() {
  testWidgets(
    'room navigation follows the native route and denies private rooms',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.physicalSize = const Size(1400, 900);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(const ProviderScope(child: Monastack()));
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
      expect(find.text('Connect to local node'), findsOneWidget);
      final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
      for (var i = 0; i < 5 && world.map == null; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      world.goToRoom('dev');
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(world.current, [8, 2]);
      await tester.tap(find.text('Finance').first);
      await tester.pump();
      expect(find.textContaining('Access denied'), findsOneWidget);
      expect(world.current, [8, 2]);
      world.policyChanged(reset: true);
      expect(world.current, [2, 2]);
    },
  );
}
