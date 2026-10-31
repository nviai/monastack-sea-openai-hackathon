import 'dart:async';
import 'dart:typed_data';

import 'package:monastack/features/chat/domain/chat_client.dart';

class FakeChatClient extends ChatClient {
  @override
  ChatPhase phase = ChatPhase.ready;
  @override
  List<ChatRoom> rooms = const [
    ChatRoom(
      id: 'lobby',
      officeRoom: 'lobby',
      name: 'Lobby',
      topic: 'Meet the team',
      unread: 3,
      mentions: 2,
    ),
    ChatRoom(
      id: 'eng',
      officeRoom: 'engineering',
      name: 'Engineering',
      restricted: true,
    ),
    ChatRoom(id: 'dm', name: 'An and Linh', unread: 1),
  ];
  @override
  List<ChatPerson> people = const [
    ChatPerson('me', '@me:test', 'Me'),
    ChatPerson('an', '@an:test', 'An'),
    ChatPerson('linh', '@linh:test', 'Linh'),
  ];
  @override
  String? userId = '@me:test';
  @override
  Set<String> revokedRooms = {};
  final events = <String, List<ChatMessage>>{};
  final calls = <String>[];
  final sends = <String>[];
  final serverEvents = <String, String>{};
  bool failThread = false;
  Completer<void>? threadGate;
  bool failSend = false,
      failLoad = false,
      failMembers = false,
      failSearch = false,
      failUpload = false;
  Completer<void>? loadGate, memberGate, searchGate, uploadGate;
  List<String> typers = [];
  List<Map<String, dynamic>> history = [];
  ChatSearchPage searchPage = const ChatSearchPage([], null);
  @override
  List<ChatMessage> messages(String room) =>
      revokedRooms.contains(room) ? [] : events[room] ?? [];
  @override
  List<String> typing(String room) => typers;
  @override
  bool hasOlder(String room) => true;
  void emit() => notifyListeners();
  void revoke(String room) {
    rooms = rooms.where((r) => r.id != room).toList();
    revokedRooms.add(room);
    emit();
  }

  @override
  Future<void> start() async {
    calls.add('start');
  }

  @override
  Future<void> refreshRooms() async {
    calls.add('refresh');
  }

  @override
  Future<void> load(String room, {bool older = false}) async {
    calls.add('load:$room:$older');
    await loadGate?.future;
    if (failLoad) throw StateError('offline');
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
    sends.add(transactionId);
    calls.add('send:$room:$thread:$replyTo:$edit:$body');
    final id = serverEvents.putIfAbsent(
      transactionId,
      () => 'event-$transactionId',
    );
    if (failSend) throw StateError('response lost');
    return id;
  }

  @override
  Future<void> react(String room, String event, String emoji) async {
    calls.add('react:$room:$event:$emoji');
  }

  @override
  Future<void> redact(String room, String event) async {
    calls.add('redact:$room:$event');
  }

  @override
  Future<void> markRead(String room) async {
    calls.add('read:$room');
  }

  @override
  Future<void> setTyping(String room, bool active) async {
    calls.add('typing:$room:$active');
  }

  @override
  Future<void> loadThread(String room, String root) async {
    calls.add('thread:$room:$root');
    await threadGate?.future;
    if (failThread) throw StateError('Thread unavailable');
  }

  @override
  Future<List<ChatPerson>> members(String room) async {
    await memberGate?.future;
    if (failMembers) throw StateError('offline');
    return people;
  }

  @override
  Future<ChatSearchPage> search(String term, {String? next}) async {
    calls.add('search:$term:$next');
    await searchGate?.future;
    if (failSearch) throw StateError('search offline');
    return searchPage;
  }

  @override
  Future<String> directMessage(List<String> actors) async {
    calls.add('dm:${actors.join(',')}');
    return 'dm';
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
    sends.add(transactionId);
    calls.add('upload:$room:$thread:$name');
    progress(.5);
    await uploadGate?.future;
    if (failUpload) throw StateError('upload failed');
    serverEvents.putIfAbsent(transactionId, () => 'file-$transactionId');
    progress(1);
  }

  @override
  Future<Uint8List> download(ChatMessage message) async {
    calls.add('download:${message.id}');
    if (revokedRooms.contains(message.roomId)) throw StateError('revoked');
    return Uint8List(0);
  }

  @override
  Future<List<Map<String, dynamic>>> legacy(
    String scope, {
    String? before,
  }) async {
    calls.add('legacy:$scope:$before');
    if (failLoad) throw StateError('revoked');
    return history;
  }

  @override
  Future<void> signOut() async {
    phase = ChatPhase.signedOut;
    rooms = [];
    emit();
  }

  @override
  Future<void> close() async {}
}

ChatMessage message(
  String id, {
  String room = 'lobby',
  String body = 'Hello **team**',
  bool own = false,
  bool canDelete = false,
  bool deleted = false,
  bool edited = false,
  String? thread,
  String? attachment,
  bool image = false,
  bool mentioned = false,
  Map<String, int> reactions = const {},
  List<String> readers = const [],
}) => ChatMessage(
  id: id,
  roomId: room,
  sender: own ? 'Me' : 'An',
  body: body,
  time: DateTime.now().add(const Duration(seconds: 1)),
  own: own,
  canDelete: canDelete,
  deleted: deleted,
  edited: edited,
  thread: thread,
  attachment: attachment,
  image: image,
  mentioned: mentioned,
  reactions: reactions,
  readers: readers,
);
