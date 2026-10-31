import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/chat/presentation/chat_composer.dart';

import 'chat_test_host.dart';
import 'fake_chat_client.dart';

void main() {
  testWidgets('edit reply cancel reaction redaction copy and read controls', (
    tester,
  ) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final client = FakeChatClient()
      ..events['lobby'] = [
        message('own', body: 'Original', own: true, canDelete: true),
      ];
    final controller = await showChat(tester, client);
    await controller.select('lobby');
    await tester.pumpAndSettle();
    await openMessageActions(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit message'));
    await tester.pumpAndSettle();
    expect(find.text('Editing message'), findsOneWidget);
    final composer = find.descendant(
      of: find.byType(ChatComposer),
      matching: find.byType(TextField),
    );
    await tester.enterText(composer, 'Edited');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(client.calls, contains('send:lobby:null:null:own:Edited'));
    // A synced edit replaces the original visible body.
    client.events['lobby'] = [
      message('own', body: 'Edited', own: true, canDelete: true, edited: true),
    ];
    client.emit();
    await tester.pumpAndSettle();
    expect(find.text(' · edited'), findsOneWidget);
    await openMessageActions(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(find.text('Replying to a message'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel reply or edit'));
    await tester.pumpAndSettle();
    expect(controller.draft('lobby').reply, isNull);
    await openMessageActions(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('React 👍'));
    await tester.pumpAndSettle();
    expect(client.calls, contains('react:lobby:own:👍'));
    await openMessageActions(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy text'));
    await tester.pumpAndSettle();
    expect(clipboard, 'Edited');
    await tester.tap(find.byTooltip('Mark as read'));
    await tester.pumpAndSettle();
    expect(client.calls, contains('read:lobby'));
    await openMessageActions(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete message'));
    await tester.pumpAndSettle();
    expect(client.calls, contains('redact:lobby:own'));
    client.events['lobby'] = [message('own', deleted: true)];
    client.emit();
    await tester.pumpAndSettle();
    expect(find.text('Message deleted'), findsOneWidget);
    expect(find.byTooltip('Message actions'), findsNothing);
  });
  testWidgets('another sender has no edit or delete without permission', (
    tester,
  ) async {
    final client = FakeChatClient()..events['lobby'] = [message('other')];
    final controller = await showChat(tester, client);
    await controller.select('lobby');
    await tester.pumpAndSettle();
    await openMessageActions(tester);
    await tester.pumpAndSettle();
    expect(find.text('Edit message'), findsNothing);
    expect(find.text('Delete message'), findsNothing);
  });
  testWidgets(
    'mention picker typing indicator upload progress failure and retry',
    (tester) async {
      final client = FakeChatClient()..typers = ['An'];
      final controller = await showChat(tester, client);
      await controller.select('lobby');
      await tester.pumpAndSettle();
      expect(find.text('An typing…'), findsOneWidget);
      await tester.tap(find.byTooltip('Mention a person'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('An').last);
      await tester.pumpAndSettle();
      expect(controller.draft('lobby').text, '@an:test ');
      client.uploadGate = Completer<void>();
      client.failUpload = true;
      final uploading = controller.attach(
        'lobby',
        'plan.txt',
        Uint8List.fromList([1, 2, 3]),
      );
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      client.uploadGate!.complete();
      await uploading;
      await tester.pumpAndSettle();
      expect(find.text('Retry send'), findsOneWidget);
      client.failUpload = false;
      await tester.tap(find.text('Retry send'));
      await tester.pumpAndSettle();
      expect(client.sends.toSet().length, 1);
    },
  );
  testWidgets('thread has separate composer and sends relation', (
    tester,
  ) async {
    final client = FakeChatClient()..events['lobby'] = [message('root')];
    final controller = await showChat(tester, client);
    await controller.select('lobby');
    await controller.openThread(message('root'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('composer-root')),
      'In thread',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(client.calls, contains('send:lobby:root:null:null:In thread'));
  });
}
