import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';
import 'package:monastack/features/office/data/office_core.dart';
import 'package:monastack/features/office/world/office_world.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'macOS app walks to an authorized room and refuses a private room',
    (tester) async {
      await tester.pumpWidget(const ProviderScope(child: Monastack()));
      for (
        var i = 0;
        i < 50 && find.byType(OfficeWorld).evaluate().isEmpty;
        i++
      ) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(OfficeWorld), findsOneWidget);
      final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
      for (var i = 0; i < 50 && world.map == null; i++) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 100));
      }
      final core = await ProviderScope.containerOf(
        tester.element(find.byType(OfficeWorld)),
      ).read(officeCoreProvider.future);
      expect(
        await core.findPath(
          actor: 'an',
          start: const Cell(x: 2, y: 2),
          goal: const Cell(x: 8, y: 2),
        ),
        isNotEmpty,
      );
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Dev & QA'))
          .onTap!();
      for (var i = 0; i < 200 && world.current.toString() != '[8, 2]'; i++) {
        tester.binding.scheduleForcedFrame();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(world.current, [8, 2]);
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Finance'))
          .onTap!();
      await tester.pump();
      expect(find.textContaining('Access denied'), findsOneWidget);
      expect(world.current, [8, 2]);
    },
  );
}
