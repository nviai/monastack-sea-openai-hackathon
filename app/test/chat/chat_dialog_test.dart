import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/chat/application/chat_controller.dart';
import 'package:monastack/features/chat/domain/chat_client.dart';
import 'package:monastack/features/chat/presentation/chat_main_pane.dart';
import 'package:monastack/features/chat/presentation/chat_composer.dart';
import 'package:monastack/features/office/communication/workspace_tools.dart';

import 'fake_chat_client.dart';
import 'chat_test_host.dart';

void main() {
  for (final entry in {
    ChatPhase.loading: 'Connecting to chat…',
    ChatPhase.unavailable: 'Chat is not available on this server',
    ChatPhase.error: 'Chat could not connect. Your drafts are kept.',
    ChatPhase.signedOut: 'Sign in to use Chat.',
    ChatPhase.ready: 'Choose a conversation to get started.',
    ChatPhase.reconnecting:
        'Connection lost. Reconnecting… Your drafts are kept.',
  }.entries) {
    testWidgets('dialog phase ${entry.key}', (tester) async {
      final client = FakeChatClient()..phase = entry.key;
      await showChat(tester, client);
      expect(find.text(entry.value), findsOneWidget);
      if (entry.key == ChatPhase.error) {
        await tester.tap(find.text('Retry connection'));
        expect(client.calls, contains('start'));
      }
    });
  }
  testWidgets('main loading empty error retry and badges', (tester) async {
    final client = FakeChatClient()..loadGate = Completer<void>();
    final controller = await showChat(tester, client);
    expect(find.text('@2'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('channel-lobby')));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    client.loadGate!.complete();
    await tester.pumpAndSettle();
    expect(
      find.text('No messages yet. Start the conversation.'),
      findsOneWidget,
    );
    client.failLoad = true;
    await controller.select('eng');
    await tester.pumpAndSettle();
    expect(
      find.text('Conversation unavailable. Retry to reconnect.'),
      findsOneWidget,
    );
    client.failLoad = false;
    await tester.tap(find.text('Retry conversation'));
    await tester.pumpAndSettle();
    expect(
      find.text('Conversation unavailable. Retry to reconnect.'),
      findsNothing,
    );
    await tester.tap(find.text('Unreads'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('channel-eng')), findsNothing);
    await tester.tap(find.text('Mentions'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('channel-dm')), findsNothing);
  });
  testWidgets(
    'Enter sends Shift+Enter inserts newline drafts and retry deduplicate',
    (tester) async {
      final client = FakeChatClient();
      final controller = await showChat(tester, client);
      await controller.select('lobby');
      await tester.pumpAndSettle();
      final composer = find.descendant(
        of: find.byType(ChatComposer),
        matching: find.byType(TextField),
      );
      await tester.enterText(composer, 'line one');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(controller.draft('lobby').text, 'line one\n');
      expect(client.sends, isEmpty);
      await controller.select('eng');
      await tester.pumpAndSettle();
      await tester.enterText(composer, 'eng draft');
      await controller.select('lobby');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(composer).controller!.text, 'line one\n');
      client.failSend = true;
      await tester.tap(composer);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Retry send'), findsOneWidget);
      expect(controller.draft('lobby').text, 'line one\n');
      client.failSend = false;
      await tester.tap(find.text('Retry send'));
      await tester.pumpAndSettle();
      expect(client.sends.toSet().length, 1);
      expect(client.serverEvents.length, 1);
      expect(controller.draft('lobby').text, '');
      expect(controller.draft('eng').text, 'eng draft');
    },
  );
  testWidgets('details members thread and revoked-room cleanup', (
    tester,
  ) async {
    final client = FakeChatClient()
      ..events['lobby'] = [
        message('root', body: 'Original'),
        message('child', thread: 'root', body: 'Thread reply'),
      ];
    final controller = await showChat(tester, client);
    await controller.select('lobby');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Room details'));
    await tester.pumpAndSettle();
    expect(find.text('Open to authorized workspace members.'), findsOneWidget);
    await tester.tap(find.byTooltip('Members'));
    await tester.pumpAndSettle();
    expect(find.text('An'), findsWidgets);
    await controller.openThread(message('root'));
    await tester.pumpAndSettle();
    expect(find.text('Thread'), findsOneWidget);
    expect(find.text('Thread reply'), findsOneWidget);
    controller.text('lobby', 'secret', root: 'root');
    client.revoke('lobby');
    await tester.pumpAndSettle();
    expect(find.text('Original'), findsNothing);
    expect(find.text('Thread reply'), findsNothing);
    expect(find.text('Access to this conversation has ended.'), findsOneWidget);
  });
  testWidgets('thread loading error retry and empty states', (tester) async {
    final client = FakeChatClient()..threadGate = Completer<void>();
    final controller = await showChat(tester, client);
    await controller.select('lobby');
    final loading = controller.openThread(message('root'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    client.failThread = true;
    client.threadGate!.complete();
    await loading;
    await tester.pumpAndSettle();
    expect(find.text('Thread unavailable · Retry'), findsOneWidget);
    client.failThread = false;
    await tester.tap(find.text('Thread unavailable · Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Thread unavailable · Retry'), findsNothing);
    expect(find.text('No messages yet. Start the conversation.'), findsWidgets);
  });
  testWidgets('members loading error retry empty', (tester) async {
    final client = FakeChatClient()..memberGate = Completer<void>();
    final controller = await showChat(tester, client);
    await controller.select('lobby');
    controller.side(SidePane.members);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    client.failMembers = true;
    client.memberGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Members unavailable · Retry'), findsOneWidget);
    client.failMembers = false;
    client.people = [];
    await tester.tap(find.text('Members unavailable · Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No members.'), findsOneWidget);
  });
  testWidgets(
    'search sends server query, shows result, empty and error states',
    (tester) async {
      final client = FakeChatClient()..searchGate = Completer<void>();
      final controller = await showChat(tester, client);
      await tester.enterText(find.byKey(const Key('chat-search')), 'archive');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      client.searchPage = ChatSearchPage([
        message('result', body: 'An older result'),
      ], 'next');
      client.searchGate!.complete();
      await tester.pumpAndSettle();
      expect(client.calls, contains('search:archive:null'));
      expect(find.text('An older result'), findsOneWidget);
      await tester.tap(find.text('More results'));
      await tester.pumpAndSettle();
      expect(client.calls, contains('search:archive:next'));
      client.searchPage = const ChatSearchPage([], null);
      await controller.search('none');
      await tester.pumpAndSettle();
      expect(find.text('No matching messages.'), findsOneWidget);
      client.failSearch = true;
      await controller.search('error');
      await tester.pumpAndSettle();
      expect(
        find.text('Search unavailable. Retry your search.'),
        findsOneWidget,
      );
    },
  );
  testWidgets('person picker sends one-to-one and group actor sets', (
    tester,
  ) async {
    final client = FakeChatClient();
    await showChat(tester, client);
    await tester.tap(find.byTooltip('New direct message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('An'));
    await tester.tap(find.text('Linh'));
    await tester.pump();
    await tester.tap(find.text('Open conversation'));
    await tester.pumpAndSettle();
    expect(client.calls, contains('dm:an,linh'));
    await tester.tap(find.byTooltip('New direct message'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('An').last);
    await tester.pump();
    await tester.tap(find.text('Open conversation'));
    await tester.pumpAndSettle();
    expect(client.calls, contains('dm:an'));
  });
  testWidgets('current office room action is explicit', (tester) async {
    final client = FakeChatClient();
    final controller = await showChat(tester, client);
    await controller.select('lobby');
    await tester.pumpAndSettle();
    expect(find.byType(ChatMainPane), findsOneWidget);
    expect(controller.selected, 'lobby');
    await tester.tap(find.text("Open this room's chat"));
    await tester.pumpAndSettle();
    expect(controller.selected, 'eng');
  });
  testWidgets('Command K focuses server search and dialog can expand', (
    tester,
  ) async {
    final client = FakeChatClient();
    final controller = await showChat(tester, client);
    await controller.select('lobby');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('composer-main')));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('chat-search')))
          .focusNode!
          .hasFocus,
      isTrue,
    );
    await tester.tap(find.byTooltip('Expand chat'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Restore dialog size'), findsOneWidget);
  });
  testWidgets('Workspace tools Chat has unread badge', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: WorkspaceTools(chatUnread: 7)),
    );
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
  });
}
