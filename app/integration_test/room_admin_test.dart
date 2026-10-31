import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:monastack/app/monastack_app.dart';
import 'package:monastack/features/office/world/office_world.dart';
import 'package:monastack/features/office/rooms/room_membership.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'authenticated admin explicitly grants and revokes own room membership',
    (tester) async {
      Future<void> until(
        bool Function() condition,
        String reason, {
        int attempts = 350,
      }) async {
        for (var i = 0; i < attempts && !condition(); i++) {
          tester.binding.scheduleForcedFrame();
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(condition(), isTrue, reason: reason);
      }

      Finder button(String label) => find.widgetWithText(TextButton, label);
      void finance() => tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Finance'))
          .onTap!();
      void openAdmin() => tester
          .widget<PopupMenuButton<String>>(find.byType(PopupMenuButton<String>))
          .onSelected!('room-admin');
      void choose(String value) => tester
          .widget<DropdownButton<String>>(
            find.descendant(
              of: find.byType(RoomMembership),
              matching: find.byWidgetPredicate(
                (w) =>
                    w is DropdownButton<String> &&
                    (w.items?.any((item) => item.value == value) ?? false),
              ),
            ),
          )
          .onChanged!(value);
      bool enabled(String label) =>
          find.widgetWithText(TextButton, label).evaluate().isNotEmpty &&
          tester.widget<TextButton>(button(label)).onPressed != null;
      await tester.pumpWidget(const ProviderScope(child: Monastack()));
      await until(
        () => find.text('Connect').evaluate().isNotEmpty,
        'connect UI',
      );
      tester.widget<TextField>(find.byType(TextField).first).controller!.text =
          Platform.environment['MONASTACK_TEST_TOKEN']!;
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Connect'))
          .onPressed!();
      await until(
        () => find.text('Chat · Connected').evaluate().isNotEmpty,
        'connected',
      );
      finance();
      await tester.pump();
      expect(find.textContaining('Access denied to Finance'), findsOneWidget);
      openAdmin();
      await until(
        () => find.byType(RoomMembership).evaluate().isNotEmpty,
        'room admin opened',
      );
      await until(
        () => find.text('Choose a human').evaluate().isNotEmpty,
        'room admin loaded',
      );
      choose('finance');
      await tester.pump();
      await until(
        () => find.textContaining('Current members:').evaluate().isNotEmpty,
        'finance members loaded',
      );
      choose('an');
      await tester.pump();
      await until(() => enabled('Grant access'), 'grant available');
      tester.widget<TextButton>(button('Grant access')).onPressed!();
      await until(
        () => find.text('Grant room access?').evaluate().isNotEmpty,
        'grant confirmation',
      );
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'))
          .onPressed!();
      await until(() => enabled('Revoke access'), 'grant recorded');
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Close room membership',
            ),
          )
          .onPressed!();
      await tester.pump();
      for (var i = 0; i < 25; i++) {
        finance();
        await tester.pump(const Duration(milliseconds: 500));
        if (find
            .textContaining('Access denied to Finance')
            .evaluate()
            .isEmpty) {
          break;
        }
      }
      expect(find.textContaining('Access denied to Finance'), findsNothing);
      final world = tester.state<OfficeWorldState>(find.byType(OfficeWorld));
      await until(
        () => world.current.toString() == '[2, 14]',
        'granted room reached',
      );
      openAdmin();
      await until(
        () => find.text('Choose a human').evaluate().isNotEmpty,
        'room admin reopened',
      );
      choose('finance');
      await tester.pump();
      await until(
        () => find.textContaining('Current members:').evaluate().isNotEmpty,
        'finance members reloaded',
      );
      choose('an');
      await tester.pump();
      await until(() => enabled('Revoke access'), 'revoke available');
      tester.widget<TextButton>(button('Revoke access')).onPressed!();
      await until(
        () => find.text('Revoke room access?').evaluate().isNotEmpty,
        'revoke confirmation',
      );
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Confirm'))
          .onPressed!();
      await until(() => enabled('Grant access'), 'revocation recorded');
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Close room membership',
            ),
          )
          .onPressed!();
      await tester.pump();
      await until(
        () => world.current.toString() == '[2, 2]',
        'revocation returned to lobby',
      );
      finance();
      await tester.pump();
      expect(find.textContaining('Access denied to Finance'), findsOneWidget);
      tester.widget<TextField>(find.byType(TextField).last).controller!.text =
          'synthetic room admin verified';
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Send',
            ),
          )
          .onPressed!();
      await until(
        () => find
            .text('an: synthetic room admin verified')
            .evaluate()
            .isNotEmpty,
        'verification recorded',
      );
    },
  );
}
