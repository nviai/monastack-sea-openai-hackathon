import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/chat/application/chat_controller.dart';
import 'package:monastack/features/chat/domain/chat_client.dart';

import 'fake_chat_client.dart';

void main() {
  late FakeChatClient client;
  late ChatController controller;
  setUp(() {
    client = FakeChatClient();
    controller = ChatController(client);
  });
  tearDown(() {
    controller.dispose();
    client.dispose();
  });
  test(
    'lost acknowledgment retries the original transaction and keeps draft',
    () async {
      await controller.select('lobby');
      controller.text('lobby', 'one event');
      client.failSend = true;
      await controller.send('lobby');
      expect(controller.draft('lobby').text, 'one event');
      expect(controller.timeline('lobby').single.delivery, Delivery.failed);
      client.failSend = false;
      await controller.send('lobby');
      expect(client.sends.length, 2);
      expect(client.sends.toSet().length, 1);
      expect(client.serverEvents.length, 1);
      expect(controller.draft('lobby').text, '');
      expect(controller.timeline('lobby').single.delivery, Delivery.sent);
      final pending = controller.pending.single;
      client.events['lobby'] = [
        ChatMessage(
          id: pending.eventId!,
          roomId: 'lobby',
          sender: 'Me',
          body: pending.body,
          time: DateTime.now(),
          transactionId: pending.transaction,
        ),
      ];
      expect(controller.timeline('lobby').length, 1);
    },
  );
  test('typing notices are sent on state change, not per keystroke', () {
    controller.text('lobby', 'a');
    controller.text('lobby', 'ab');
    controller.text('lobby', 'abc');
    expect(client.calls.where((c) => c.startsWith('typing:')), [
      'typing:lobby:true',
    ]);
    controller.text('lobby', '');
    expect(client.calls.where((c) => c.startsWith('typing:')), [
      'typing:lobby:true',
      'typing:lobby:false',
    ]);
  });
  test(
    'channel DM and thread drafts stay separate and edit/reply cancel',
    () async {
      controller.text('lobby', 'channel');
      controller.text('dm', 'private');
      controller.text('lobby', 'thread draft', root: 'root');
      await controller.select('eng');
      await controller.select('lobby');
      expect(controller.draft('lobby').text, 'channel');
      expect(controller.draft('lobby', 'root').text, 'thread draft');
      expect(controller.draft('dm').text, 'private');
      controller.mode(
        'lobby',
        message('original', body: 'old', own: true),
        edit: true,
      );
      expect(controller.draft('lobby').edit, 'original');
      expect(controller.draft('lobby').text, 'old');
      controller.cancelMode('lobby');
      expect(controller.draft('lobby').edit, isNull);
      controller.mode('lobby', message('reply'));
      await controller.send('lobby');
      expect(client.calls, contains('send:lobby:null:reply:null:old'));
    },
  );
  test('thread load, reactions, redaction, read receipts use client', () async {
    await controller.openThread(message('root'));
    expect(controller.thread, 'root');
    expect(controller.pane, SidePane.thread);
    expect(client.calls, contains('thread:lobby:root'));
    await controller.act(() => client.react('lobby', 'root', '👍'));
    await controller.act(() => client.redact('lobby', 'root'));
    await controller.act(() => client.markRead('lobby'));
    expect(
      client.calls,
      containsAll(['react:lobby:root:👍', 'redact:lobby:root', 'read:lobby']),
    );
  });
  test(
    'revocation erases all panes, results, pending messages and drafts',
    () async {
      await controller.select('lobby');
      controller.text('lobby', 'restricted');
      client.failSend = true;
      await controller.send('lobby');
      await controller.openThread(message('root'));
      controller.searchResults = [message('result')];
      client.revoke('lobby');
      expect(controller.selected, isNull);
      expect(controller.thread, isNull);
      expect(controller.pane, SidePane.none);
      expect(controller.searchResults, isEmpty);
      expect(controller.pending, isEmpty);
      expect(controller.draft('lobby').text, '');
      expect(controller.error, contains('Access'));
      await controller.send('lobby');
      expect(client.sends.length, 1);
    },
  );
  test(
    'server search pagination, errors and revoked result filtering',
    () async {
      client.searchPage = ChatSearchPage([message('old')], 'page-2');
      await controller.search('older than loaded');
      expect(client.calls.last, 'search:older than loaded:null');
      await controller.search('older than loaded', more: true);
      expect(client.calls.last, 'search:older than loaded:page-2');
      client.failSearch = true;
      await controller.search('test');
      expect(controller.error, contains('Search unavailable'));
    },
  );
  test('failed upload keeps bytes and transaction for retry', () async {
    client.failUpload = true;
    await controller.attach(
      'lobby',
      'image.png',
      Uint8List.fromList([1, 2]),
      root: 'root',
    );
    final upload = controller.pending.single;
    expect(upload.delivery, Delivery.failed);
    expect(upload.bytes, isNotEmpty);
    client.failUpload = false;
    await controller.retry(upload);
    expect(client.sends.toSet().length, 1);
    expect(client.serverEvents.length, 1);
    expect(controller.pending, isEmpty);
  });
  test('sign-out clears account-specific content', () async {
    controller.text('dm', 'private');
    await controller.select('dm');
    await client.signOut();
    expect(controller.selected, isNull);
    expect(controller.draft('dm').text, '');
  });
}
