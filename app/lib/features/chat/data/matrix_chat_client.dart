import 'dart:async';

import 'package:matrix/matrix.dart';

import '../domain/chat_client.dart';
import 'matrix_session.dart';
import 'matrix_events.dart';
import 'matrix_rich_actions.dart';

class MatrixChatClient extends ChatClient with MatrixRichActions {
  MatrixChatClient(this.session);
  final MatrixSession session;
  @override
  Client get sdk => session.client!;
  @override
  ChatPhase phase = ChatPhase.loading;
  @override
  List<ChatPerson> people = [];
  @override
  final Set<String> revokedRooms = {};
  final Map<String, Map> mappings = {};
  @override
  final Map<String, Timeline> timelines = {};
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _closed = false, _connected = false, _initialized = false;
  final Map<String, Future<void>> _loading = {};
  Future<void>? _starting, _refreshing;
  @override
  String? get userId => session.client?.userID;
  @override
  List<ChatRoom> get rooms {
    if (session.client == null || phase == ChatPhase.signedOut) return [];
    return [
      for (final room in sdk.rooms)
        if (room.membership == Membership.join &&
            !revokedRooms.contains(room.id))
          ChatRoom(
            id: room.id,
            name:
                mappings[room.id]?['name'] as String? ??
                room.getLocalizedDisplayname(),
            officeRoom: mappings[room.id]?['office_room'] as String?,
            topic: mappings[room.id]?['topic'] as String? ?? room.topic,
            restricted:
                mappings[room.id]?['restricted'] == true ||
                !mappings.containsKey(room.id),
            unread: room.notificationCount,
            mentions: room.highlightCount,
            canPost: room.canSendDefaultMessages && !room.encrypted,
          ),
    ];
  }

  @override
  List<ChatMessage> messages(String room) {
    if (_closed ||
        revokedRooms.contains(room) ||
        sdk.getRoomById(room)?.membership != Membership.join) {
      return [];
    }
    final timeline = timelines[room];
    if (timeline == null) return [];
    return timeline.events
        .where(
          (e) =>
              e.type == 'm.room.message' && e.relationshipType != 'm.replace',
        )
        .map((e) => matrixMessage(e, timeline))
        .toList();
  }

  @override
  List<String> typing(String room) => revokedRooms.contains(room)
      ? []
      : sdk
                .getRoomById(room)
                ?.typingUsers
                .where((u) => u.id != userId)
                .map((u) => u.calcDisplayname())
                .toList() ??
            [];
  @override
  bool hasOlder(String room) => timelines[room]?.canRequestHistory ?? true;
  @override
  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);
  Future<void> _start() async {
    if (_closed) return;
    phase = ChatPhase.loading;
    notifyListeners();
    try {
      if (!_connected) {
        final client = await session.open();
        if (_closed) {
          await session.close();
          return;
        }
        if (client == null) {
          phase = ChatPhase.unavailable;
          notifyListeners();
          return;
        }
        _connected = true;
        _subscriptions.add(
          client.onSync.stream.listen((update) {
            // Leave is processed before rendering or notifying about this batch.
            for (final id in update.rooms?.leave?.keys ?? <String>[]) {
              revoke(id);
            }
            if (_initialized) phase = ChatPhase.ready;
            // Keep notification candidates available even for unopened DMs.
            for (final room in rooms) {
              if ((room.direct || room.mentions > 0) &&
                  !timelines.containsKey(room.id)) {
                unawaited(load(room.id).catchError((_) {}));
              }
            }
            notifyListeners();
          }),
        );
        _subscriptions.add(
          client.onSyncStatus.stream.listen((update) {
            if (_closed || !_initialized) return;
            phase = update.status == SyncStatus.error
                ? ChatPhase.reconnecting
                : ChatPhase.ready;
            notifyListeners();
          }),
        );
      }
      await refreshRooms();
      final users = await session.request('GET', '/v1/chat/users') as List;
      people = [
        for (final p in users)
          ChatPerson(
            p['actor'] as String,
            p['user_id'] as String,
            p['name'] as String,
          ),
      ];
      for (final room in rooms) {
        if (room.direct || room.mentions > 0) await load(room.id);
      }
      if (!_closed) {
        _initialized = true;
        phase = ChatPhase.ready;
        notifyListeners();
      }
    } catch (_) {
      if (!_connected) await session.close();
      if (!_closed) {
        phase = ChatPhase.error;
        notifyListeners();
      }
    }
  }

  void revoke(String id) {
    forgetRoom(id);
    revokedRooms.add(id);
    timelines.remove(id)?.cancelSubscriptions();
    mappings.remove(id);
  }

  @override
  Future<void> refreshRooms() =>
      _refreshing ??= _refreshRooms().whenComplete(() => _refreshing = null);
  Future<void> _refreshRooms() async {
    if (_closed || session.client == null) return;
    final rows = await session.request('GET', '/v1/chat/rooms') as List;
    if (_closed) return;
    final allowed = {for (final r in rows) r['matrix_room_id'] as String};
    for (final id in mappings.keys.toList()) {
      if (!allowed.contains(id)) revoke(id);
    }
    for (final r in rows) {
      final id = r['matrix_room_id'] as String;
      mappings[id] = r as Map;
      // A new node authorization grants access again. Never use old cached timeline.
      revokedRooms.remove(id);
    }
    notifyListeners();
  }

  @override
  Room authorized(String id) {
    final room = sdk.getRoomById(id);
    if (_closed ||
        revokedRooms.contains(id) ||
        room == null ||
        room.membership != Membership.join) {
      throw StateError('Room access ended');
    }
    if (room.encrypted) throw StateError('Encrypted rooms are not supported');
    return room;
  }

  @override
  Future<void> load(String room, {bool older = false}) async {
    if (_loading.containsKey(room)) {
      await _loading[room];
      if (!older) return;
    }
    final flight = _load(room, older: older);
    _loading[room] = flight;
    try {
      await flight;
    } finally {
      _loading.remove(room);
    }
  }

  Future<void> _load(String room, {bool older = false}) async {
    final target = authorized(room);
    final timeline =
        timelines[room] ??
        await target.getTimeline(
          onUpdate: () {
            if (!_closed && !revokedRooms.contains(room)) notifyListeners();
          },
        );
    if (_closed ||
        revokedRooms.contains(room) ||
        target.membership != Membership.join) {
      timeline.cancelSubscriptions();
      throw StateError('Room access ended');
    }
    timelines[room] = timeline;
    if (older && timeline.canRequestHistory) await timeline.requestHistory();
    if (!_closed) {
      authorized(room);
      notifyListeners();
    }
  }

  @override
  Future<String> send(
    String room,
    String body,
    String transactionId, {
    String? thread,
    String? replyTo,
    String? edit,
  }) async {
    final target = authorized(room);
    final reply = replyTo == null
        ? null
        : await timelines[room]?.getEventById(replyTo);
    authorized(room);
    if (replyTo != null && reply == null) {
      throw StateError('Reply is no longer available');
    }
    final id = await target.sendTextEvent(
      body,
      txid: transactionId,
      parseCommands: false,
      displayPendingEvent: false,
      inReplyTo: reply,
      threadRootEventId: thread,
      editEventId: edit,
    );
    if (id == null) throw StateError('Message not acknowledged');
    return id;
  }

  @override
  Future<void> markRead(String room) async {
    authorized(room);
    await timelines[room]?.setReadMarker();
    if (!_closed) notifyListeners();
  }

  @override
  Future<void> setTyping(String room, bool active) =>
      authorized(room).setTyping(active);
  @override
  Future<String> directMessage(List<String> actors) async {
    final result = await session.request('POST', '/v1/chat/dms', {
      'actors': actors,
    }) as Map;
    final id = result['matrix_room_id'] as String;
    // The node registry is the authority for deduplication and group membership.
    if (sdk.getRoomById(id) == null) {
      await sdk.onSync.stream
          .firstWhere((_) => sdk.getRoomById(id) != null)
          .timeout(const Duration(seconds: 35));
    }
    notifyListeners();
    return id;
  }

  @override
  Future<List<Map<String, dynamic>>> legacy(
    String scope, {
    String? before,
  }) async => (await session.request(
    'GET',
    '/v1/chat/legacy/${Uri.encodeComponent(scope)}?limit=50'
        '${before == null ? '' : '&before=${Uri.encodeQueryComponent(before)}'}',
  ) as List).cast<Map<String, dynamic>>();
  @override
  Future<void> signOut() async {
    phase = ChatPhase.signedOut;
    await _stopListeners();
    notifyListeners();
    await session.logout();
  }

  Future<void> _stopListeners() async {
    _closed = true;
    clearRichData();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    for (final timeline in timelines.values) {
      timeline.cancelSubscriptions();
    }
    timelines.clear();
    mappings.clear();
    people = [];
  }

  @override
  Future<void> close() async {
    await _stopListeners();
    await session.close();
  }
}
