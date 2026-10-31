import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/chat/application/chat_notifications.dart';

import 'fake_chat_client.dart';

class NotificationSink implements ChatNotificationSink {
  bool allowed = true;
  final shows = <int>[];
  final cancels = <int>[];
  @override
  Future<bool> requestPermission() async => allowed;
  @override
  Future<void> show(int id, {required bool mention}) async {
    shows.add(id);
  }

  @override
  Future<void> cancel(int id) async {
    cancels.add(id);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('permission denial and focus suppress delivery; revocation cancels notification', () async {
    final client = FakeChatClient();
    final sink = NotificationSink()..allowed = false;
    final notifications = ChatNotifications(client, sink)..focused = false;
    addTearDown(notifications.dispose);
    addTearDown(client.dispose);
    expect(await notifications.enable(), isFalse);
    client.events['dm'] = [message('denied', room: 'dm')];
    client.emit();
    await Future<void>.delayed(Duration.zero);
    expect(sink.shows, isEmpty);
    sink.allowed = true;
    await notifications.enable();
    notifications.focused = true;
    client.events['dm'] = [message('focused', room: 'dm')];
    client.emit();
    await Future<void>.delayed(Duration.zero);
    expect(sink.shows, isEmpty);
    notifications.focused = false;
    client.events['dm'] = [message('background', room: 'dm')];
    client.emit();
    await Future<void>.delayed(Duration.zero);
    expect(sink.shows.length, 1);
    client.revoke('dm');
    await Future<void>.delayed(Duration.zero);
    expect(sink.cancels, contains(sink.shows.single));
    client.events['dm'] = [message('revoked', room: 'dm')];
    client.emit();
    await Future<void>.delayed(Duration.zero);
    expect(sink.shows.length, 1);
  });
  test(
    'mentions notify once and ordinary channel messages stay silent',
    () async {
      final client = FakeChatClient();
      final sink = NotificationSink();
      final notifications = ChatNotifications(client, sink)..focused = false;
      addTearDown(notifications.dispose);
      addTearDown(client.dispose);
      await notifications.enable();
      client.events['lobby'] = [message('mention', mentioned: true)];
      client.emit();
      await Future<void>.delayed(Duration.zero);
      client.emit();
      await Future<void>.delayed(Duration.zero);
      expect(sink.shows.length, 1);
      client.events['eng'] = [message('ordinary', room: 'eng')];
      client.emit();
      await Future<void>.delayed(Duration.zero);
      expect(sink.shows.length, 1);
    },
  );
}
