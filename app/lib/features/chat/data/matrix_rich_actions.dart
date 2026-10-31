import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';

import '../domain/chat_client.dart';
import 'matrix_events.dart';

mixin MatrixRichActions on ChatClient {
  Client get sdk;
  Map<String, Timeline> get timelines;
  Room authorized(String id);
  final _threadEvents = <String, Map<String, Event>>{};
  final _uploadContent = <String, Map<String, dynamic>>{};
  final _uploadRooms = <String, String>{};

  void forgetRoom(String room) {
    _threadEvents.remove(room);
    for (final tx
        in _uploadRooms.keys.where((tx) => _uploadRooms[tx] == room).toList()) {
      _uploadContent.remove(tx);
      _uploadRooms.remove(tx);
    }
  }

  void clearRichData() {
    _threadEvents.clear();
    _uploadContent.clear();
    _uploadRooms.clear();
  }

  @override
  Future<void> react(String room, String event, String emoji) async {
    final target = authorized(room);
    final existing = timelines[room]?.aggregatedEvents[event]?['m.annotation']
        ?.where(
          (e) =>
              !e.redacted &&
              e.senderId == sdk.userID &&
              (e.content['m.relates_to'] as Map?)?['key'] == emoji,
        )
        .firstOrNull;
    if (existing != null) {
      await target.redactEvent(existing.eventId);
    } else {
      final result = await target.sendEvent({
        'm.relates_to': {
          'rel_type': 'm.annotation',
          'event_id': event,
          'key': emoji,
        },
      }, type: 'm.reaction');
      if (result == null) throw StateError('Reaction not acknowledged');
    }
  }

  @override
  Future<void> redact(String room, String event) async {
    await authorized(room).redactEvent(event);
  }

  @override
  Future<List<ChatPerson>> members(String room) async {
    final result = await authorized(room)
        .requestParticipants([Membership.join]);
    authorized(room);
    return [for (final u in result) ChatPerson('', u.id, u.calcDisplayname())];
  }

  @override
  Future<void> loadThread(String room, String root) async {
    final target = authorized(room);
    final events = _threadEvents[room] ??= {};
    final rootEvent = await timelines[room]?.getEventById(root);
    authorized(room);
    if (rootEvent != null) events[root] = rootEvent;
    String? from;
    do {
      final page = await sdk.getRelatingEventsWithRelType(
        room,
        root,
        'm.thread',
        from: from,
        limit: 100,
      );
      authorized(room);
      for (final raw in page.chunk) {
        final event = Event.fromMatrixEvent(raw, target);
        events[event.eventId] = event;
      }
      from = page.nextBatch;
    } while (from != null);
    final timeline = timelines[room];
    if (timeline != null) {
      for (final event in events.values) {
        if (!timeline.events.any((e) => e.eventId == event.eventId)) {
          timeline.events.add(event);
        }
      }
      timeline.events.sort(
        (a, b) => b.originServerTs.compareTo(a.originServerTs),
      );
    }
    notifyListeners();
  }

  @override
  Future<ChatSearchPage> search(String term, {String? next}) async {
    // Explicitly constrain to currently joined rooms. Synapse enforces membership
    // again; results are checked again after the response for concurrent leaves.
    final allowed = rooms.map((r) => r.id).toList();
    if (allowed.isEmpty) return const ChatSearchPage([], null);
    final raw = await sdk.request(
      RequestType.POST,
      '/client/v3/search',
      query: {'next_batch': ?next},
      data: {
        'search_categories': {
          'room_events': {
            'search_term': term,
            'order_by': 'recent',
            'filter': {'rooms': allowed, 'limit': 50},
            'include_state': false,
          },
        },
      },
    );
    final category = (raw['search_categories'] as Map?)?['room_events'] as Map?;
    final results = <ChatMessage>[];
    for (final row in category?['results'] as List? ?? []) {
      final event = row['result'] as Map;
      final id = event['room_id'] as String;
      if (!rooms.any((r) => r.id == id)) continue;
      final parsed = Event.fromJson(
        Map<String, dynamic>.from(event),
        authorized(id),
      );
      if (!parsed.redacted) results.add(matrixMessage(parsed, timelines[id]));
    }
    return ChatSearchPage(results, category?['next_batch'] as String?);
  }

  @override
  Future<void> upload(
    String room,
    String name,
    Uint8List bytes,
    String transactionId,
    void Function(double) progress, {
    String? thread,
  }) async {
    authorized(room);
    _uploadRooms[transactionId] = room;
    var content = _uploadContent[transactionId];
    if (content == null) {
      final http = HttpClient();
      try {
        final type =
            lookupMimeType(name, headerBytes: bytes) ??
            'application/octet-stream';
        final uri = sdk.homeserver!
            .resolve('/_matrix/media/v3/upload')
            .replace(queryParameters: {'filename': name});
        final request = await http
            .postUrl(uri)
            .timeout(const Duration(seconds: 20));
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${sdk.accessToken}',
        );
        request.headers.set(HttpHeaders.contentTypeHeader, type);
        request.contentLength = bytes.length;
        progress(0);
        await request.addStream(
          Stream<List<int>>.multi((sink) {
            for (var start = 0; start < bytes.length; start += 65536) {
              final end = (start + 65536).clamp(0, bytes.length);
              sink.add(bytes.sublist(start, end));
              progress(end / bytes.length);
            }
            sink.close();
          }),
        );
        final response = await request.close().timeout(
          const Duration(minutes: 2),
        );
        final raw = await utf8.decoder.bind(response).join();
        if (response.statusCode >= 400) throw StateError('Upload refused');
        authorized(room);
        final url = (jsonDecode(raw) as Map)['content_uri'] as String;
        content = {
          'msgtype': type.startsWith('image/') ? 'm.image' : 'm.file',
          'body': name,
          'filename': name,
          'url': url,
          'info': {'mimetype': type, 'size': bytes.length},
        };
        _uploadContent[transactionId] = content;
      } finally {
        http.close(force: true);
      }
    }
    final eventId = await authorized(room).sendEvent(
      Map<String, dynamic>.from(content),
      txid: transactionId,
      threadRootEventId: thread,
      displayPendingEvent: false,
    );
    if (eventId == null) throw StateError('Upload not acknowledged');
    _uploadContent.remove(transactionId);
    _uploadRooms.remove(transactionId);
  }

  @override
  Future<Uint8List> download(ChatMessage message) async {
    authorized(message.roomId);
    final event = await timelines[message.roomId]?.getEventById(message.id);
    if (event == null || event.redacted) {
      throw StateError('Attachment unavailable');
    }
    final file = await event.downloadAndDecryptAttachment();
    authorized(message.roomId);
    return file.bytes;
  }
}
