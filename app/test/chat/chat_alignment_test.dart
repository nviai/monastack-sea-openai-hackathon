import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/chat/application/chat_controller.dart';
import 'package:monastack/features/chat/presentation/chat_atoms.dart';
import 'package:monastack/features/chat/presentation/chat_composer.dart';
import 'package:monastack/features/chat/presentation/chat_main_pane.dart';
import 'package:monastack/features/chat/presentation/chat_attachments.dart';
import 'package:monastack/features/chat/presentation/chat_message_parts.dart';
import 'package:monastack/features/chat/presentation/chat_message_tile.dart';
import 'package:monastack/features/chat/presentation/chat_side_pane.dart';
import 'package:monastack/features/chat/presentation/chat_sidebar.dart';
import 'package:monastack/features/chat/presentation/chat_sidebar_rows.dart';
import 'package:monastack/features/chat/presentation/chat_title_bar.dart';
import 'package:monastack/shared/nexus_metrics.dart';

import 'chat_nexus_support.dart';
import 'fake_chat_client.dart';

const eps = 0.01;

/// Every render box under [root], with its rectangle in global coordinates.
Iterable<Rect> boxesUnder(RenderObject root) sync* {
  final found = <RenderBox>[];
  void visit(RenderObject object) {
    if (object is RenderBox && object.hasSize && object != root) {
      found.add(object);
    }
    object.visitChildren(visit);
  }

  visit(root);
  for (final box in found) {
    yield box.localToGlobal(Offset.zero) & box.size;
  }
}

Rect rectOf(WidgetTester tester, Finder finder) => tester.getRect(finder);

void main() {
  setUpAll(loadNexusFonts);
  for (final size in chatSizes) {
    for (final brightness in Brightness.values) {
      final tag = '${sizeName(size)}-${brightness.name}';
      final wide = size.width >= NxSize.wide;
      final inline = wide && size.width >= NxSize.sideInline;

      testWidgets('headers are 52 high in main, thread and details $tag', (
        tester,
      ) async {
        final controller = await pumpNexusChat(tester, size, brightness);
        Finder header(Type pane) => find.descendant(
          of: find.byType(pane),
          matching: find.byType(PaneHeader),
        );
        expect(
          rectOf(tester, find.byType(ChatTitleBar)).height,
          NxSize.titleBar,
        );
        final main = rectOf(tester, header(ChatMainPane));
        expect(main.height, NxSize.header);
        await controller.openThread(message('hello'));
        await tester.pumpAndSettle();
        final thread = rectOf(tester, header(ChatSidePane));
        expect(thread.height, NxSize.header);
        controller.side(SidePane.details);
        await tester.pumpAndSettle();
        final details = rectOf(tester, header(ChatSidePane));
        expect(details.height, NxSize.header);
        if (inline) {
          // Side by side: same top and same height.
          expect(thread.top, main.top);
          expect(details.top, main.top);
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('messages and composer share their edges $tag', (
        tester,
      ) async {
        final controller = await pumpNexusChat(tester, size, brightness);
        final bodies = find.byType(MessageBody);
        final lefts = <double>[
          for (var i = 0; i < bodies.evaluate().length; i++)
            tester.getTopLeft(bodies.at(i)).dx,
        ];
        expect(lefts.length, greaterThan(1));
        for (final left in lefts) {
          expect((left - lefts.first).abs(), lessThan(eps), reason: '$lefts');
        }
        // Grouped follow-ups, the deleted note and file cards line up too.
        final text = tester.getTopLeft(find.text('Message deleted')).dx;
        expect((text - lefts.first).abs(), lessThan(eps));
        final file = tester.getTopLeft(find.byType(FileCard).first).dx;
        expect((file - lefts.first).abs(), lessThan(eps));
        // Avatar size and the timeline gutter equal the composer's edges.
        final avatars = find.descendant(
          of: find.byType(ChatMessageTile),
          matching: find.byWidgetPredicate((w) => w is NexusAvatar && !w.face),
        );
        expect(avatars, findsWidgets);
        for (var i = 0; i < avatars.evaluate().length; i++) {
          expect(
            tester.getSize(avatars.at(i)),
            const Size.square(NxSize.avatar),
          );
        }
        final composer = rectOf(
          tester,
          find.descendant(
            of: find.byType(ChatComposer),
            matching: find.byType(FocusFrame),
          ),
        );
        final tile = rectOf(tester, find.byType(ChatMessageTile).first);
        final pane = rectOf(tester, find.byType(ChatMainPane));
        final avatarLeft = tester.getTopLeft(avatars.first).dx;
        expect(composer.left, closeTo(avatarLeft, eps));
        expect(composer.left - pane.left, NxSpace.s20);
        expect(pane.right - composer.right, NxSpace.s20);
        expect(tile.left, pane.left);
        expect(tile.right, pane.right);
        controller.side(SidePane.none);
      });

      testWidgets('thread gutters equal the thread composer $tag', (
        tester,
      ) async {
        final controller = await pumpNexusChat(tester, size, brightness);
        await controller.openThread(message('hello'));
        await tester.pumpAndSettle();
        final pane = rectOf(tester, find.byType(ChatSidePane));
        final composer = rectOf(
          tester,
          find.descendant(
            of: find.byType(ChatSidePane),
            matching: find.descendant(
              of: find.byType(ChatComposer),
              matching: find.byType(FocusFrame),
            ),
          ),
        );
        final avatar = tester.getTopLeft(
          find
              .descendant(
                of: find.descendant(
                  of: find.byType(ChatSidePane),
                  matching: find.byType(ChatMessageTile),
                ),
                matching: find.byWidgetPredicate(
                  (w) => w is NexusAvatar && !w.face,
                ),
              )
              .first,
        );
        expect(composer.left, closeTo(avatar.dx, eps));
        expect(composer.left - pane.left, NxSpace.s16);
        expect(pane.right - composer.right, NxSpace.s16);
      });

      testWidgets('sidebar rows are 30 high and centred $tag', (tester) async {
        await pumpNexusChat(tester, size, brightness);
        if (!wide) {
          await tester.tap(find.byTooltip('Conversations'));
          await tester.pumpAndSettle();
        }
        final rows = find.byType(ChannelRow);
        expect(rows, findsNWidgets(3));
        for (var i = 0; i < 3; i++) {
          final row = rectOf(tester, rows.at(i));
          expect(row.height, NxSize.row);
          final lead = find.descendant(
            of: rows.at(i),
            matching: find.byWidgetPredicate(
              (w) => w is Icon || w is NexusAvatar,
            ),
          );
          final mark = rectOf(tester, lead.first);
          expect(mark.center.dy, closeTo(row.center.dy, eps));
          final name = rectOf(
            tester,
            find.descendant(of: rows.at(i), matching: find.byType(Text)).first,
          );
          expect(name.center.dy, closeTo(row.center.dy, 1));
        }
        final left = rectOf(tester, rows.first).left;
        for (var i = 1; i < 3; i++) {
          expect(rectOf(tester, rows.at(i)).left, left);
          expect(
            rectOf(tester, rows.at(i)).width,
            rectOf(tester, rows.first).width,
          );
        }
        expect(tester.takeException(), isNull);
      });

      testWidgets('nothing passes its pane right edge $tag', (tester) async {
        final controller = await pumpNexusChat(tester, size, brightness);
        void expectInside(Type pane, String state) {
          final root = tester.renderObject<RenderBox>(find.byType(pane).first);
          final edge = root.localToGlobal(Offset.zero).dx + root.size.width;
          final bottom = root.localToGlobal(Offset.zero).dy + root.size.height;
          for (final rect in boxesUnder(root)) {
            // Scrolled-away list items sit outside the pane's vertical span.
            if (rect.top >= bottom ||
                rect.bottom <= root.localToGlobal(Offset.zero).dy) {
              continue;
            }
            expect(
              rect.right,
              lessThanOrEqualTo(edge + eps),
              reason: '$pane $state $tag: $rect past $edge',
            );
          }
        }

        expectInside(ChatMainPane, 'main');
        controller.side(SidePane.details);
        await tester.pumpAndSettle();
        expectInside(ChatSidePane, 'details');
        controller.side(SidePane.members);
        await tester.pumpAndSettle();
        expectInside(ChatSidePane, 'members');
        await controller.openThread(message('hello'));
        await tester.pumpAndSettle();
        expectInside(ChatSidePane, 'thread');
        controller.side(SidePane.none);
        await tester.pumpAndSettle();
        if (!wide) {
          await tester.tap(find.byTooltip('Conversations'));
          await tester.pumpAndSettle();
        }
        expectInside(ChatSidebar, 'sidebar');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
