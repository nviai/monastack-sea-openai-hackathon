import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/chat/application/chat_controller.dart';
import 'package:monastack/features/chat/domain/chat_client.dart';
import 'package:monastack/features/chat/presentation/chat_message_tile.dart';

import 'chat_nexus_support.dart';
import 'fake_chat_client.dart';

void main() {
  setUpAll(loadNexusFonts);
  for (final brightness in Brightness.values) {
    for (final size in chatSizes) {
      final tag = '${sizeName(size)}-${brightness.name}';
      testWidgets('chat panes fit $tag', (tester) async {
        final controller = await pumpNexusChat(tester, size, brightness);
        Future<void> check(String pane) async {
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$pane $tag');
          final semantics = tester.ensureSemantics();
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          semantics.dispose();
          await screenshot(tester, '$pane-$tag');
        }

        await check('main');
        controller.side(SidePane.details);
        await check('details');
        controller.side(SidePane.members);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await controller.openThread(message('hello'));
        await check('thread');
        controller.side(SidePane.none);
        await tester.pumpAndSettle();
        if (size.width < 850) {
          await tester.tap(find.byTooltip('Conversations'));
        } else {
          controller.setFilter(ChatFilter.unreads);
        }
        await check('sidebar');
      });
    }
  }

  // States that need a gesture or a failure: hover toolbar, failed send,
  // reply bar, reconnect banner. Same checks, narrow and wide.
  for (final brightness in Brightness.values) {
    for (final size in [chatSizes[1], chatSizes[3]]) {
      final tag = '${sizeName(size)}-${brightness.name}';
      testWidgets('chat states fit $tag', (tester) async {
        final client = nexusClient();
        final controller = await pumpNexusChat(
          tester,
          size,
          brightness,
          client: client,
        );
        client.failSend = true;
        controller.text('lobby', 'Attaching the log too');
        await controller.send('lobby');
        await tester.pumpAndSettle();
        await controller.mode('lobby', message('hello'));
        client.phase = ChatPhase.reconnecting;
        client.emit();
        await tester.pumpAndSettle();
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        await mouse.moveTo(
          tester.getCenter(find.byType(ChatMessageTile).at(1)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // No contrast guideline here: two banners push list rows out of the
        // viewport, and rows kept in the cache extent are read against the
        // pixels of the banners drawn over them. Contrast is checked above.
        await screenshot(tester, 'states-$tag');
        await mouse.removePointer();
      });
    }
  }
}
