import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../domain/chat_client.dart';

abstract class ChatNotificationSink {
  Future<bool> requestPermission();
  Future<void> show(int id, {required bool mention});
  Future<void> cancel(int id);
}

class MacChatNotifications implements ChatNotificationSink {
  final plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  @override
  Future<bool> requestPermission() async {
    if (!_initialized) {
      await plugin.initialize(
        settings: const InitializationSettings(
          macOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
      _initialized = true;
    }
    return await plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true) ??
        false;
  }

  @override
  Future<void> show(int id, {required bool mention}) async {
    if (!_initialized) return;
    // Never place message bodies, room names or sender identities on the lock
    // screen. Delivered notifications cannot retain restricted previews.
    await plugin.show(
      id: id,
      title: 'Monastack',
      body: mention
          ? 'You have a new mention.'
          : 'You have a new direct message.',
      notificationDetails: const NotificationDetails(
        macOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
    );
  }

  @override
  Future<void> cancel(int id) async {
    if (_initialized) await plugin.cancel(id: id);
  }
}

class ChatNotifications with WidgetsBindingObserver {
  ChatNotifications(this.client, this.sink) {
    focused =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    client.addListener(_changed);
  }
  final ChatClient client;
  final ChatNotificationSink sink;
  bool focused = true, permitted = false, disposed = false, _checking = false;
  final seen = <String>{};
  final posted = <String, int>{};
  final started = DateTime.now();
  int _id = 0;
  Future<bool> enable() async {
    try {
      permitted = await sink.requestPermission();
    } catch (_) {
      permitted = false;
    }
    return permitted;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    focused = state == AppLifecycleState.resumed;
  }

  void _changed() {
    for (final room in posted.keys.toList()) {
      if (client.revokedRooms.contains(room) ||
          client.phase == ChatPhase.signedOut) {
        unawaited(sink.cancel(posted.remove(room)!).catchError((_) {}));
      }
    }
    if (!_checking && !disposed) unawaited(_check());
  }

  Future<void> _check() async {
    _checking = true;
    try {
      for (final room in client.rooms.toList()) {
        final candidates = client
            .messages(room.id)
            .where((m) => !m.own && m.time.isAfter(started) && seen.add(m.id))
            .toList();
        if (!permitted ||
            focused ||
            candidates.isEmpty ||
            (!room.direct && !candidates.any((m) => m.mentioned))) {
          continue;
        }
        // Check node permissions immediately before delivery, then check synced
        // membership too. A failed authorization refresh suppresses delivery.
        await client.refreshRooms();
        if (disposed ||
            focused ||
            !permitted ||
            client.revokedRooms.contains(room.id) ||
            !client.rooms.any((r) => r.id == room.id)) {
          continue;
        }
        final id = posted.putIfAbsent(room.id, () => ++_id);
        await sink.show(id, mention: candidates.any((m) => m.mentioned));
        if (client.revokedRooms.contains(room.id)) await sink.cancel(id);
      }
    } catch (_) {
      /* Notifications must never disrupt sync or expose stale data. */
    } finally {
      _checking = false;
    }
  }

  void dispose() {
    disposed = true;
    client.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    for (final id in posted.values) {
      unawaited(sink.cancel(id).catchError((_) {}));
    }
    posted.clear();
  }
}
