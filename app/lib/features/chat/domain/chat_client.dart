import 'package:flutter/foundation.dart';

enum ChatPhase { loading, unavailable, ready, reconnecting, error, signedOut }

enum Delivery { sending, sent, failed }

@immutable
class ChatPerson {
  const ChatPerson(this.actor, this.id, this.name);
  final String actor, id, name;
}

@immutable
class ChatRoom {
  const ChatRoom({
    required this.id,
    required this.name,
    this.officeRoom,
    this.topic = '',
    this.restricted = false,
    this.unread = 0,
    this.mentions = 0,
    this.canPost = true,
  });
  final String id, name, topic;
  final String? officeRoom;
  final bool restricted, canPost;
  final int unread, mentions;
  bool get direct => officeRoom == null;
}

@immutable
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.roomId,
    required this.sender,
    required this.body,
    required this.time,
    this.own = false,
    this.canDelete = false,
    this.edited = false,
    this.deleted = false,
    this.thread,
    this.replyTo,
    this.attachment,
    this.image = false,
    this.mentioned = false,
    this.delivery = Delivery.sent,
    this.transactionId,
    this.reactions = const {},
    this.readers = const [],
  });
  final String id, roomId, sender, body;
  final DateTime time;
  final bool own, canDelete, edited, deleted, image, mentioned;
  final String? thread, replyTo, attachment, transactionId;
  final Delivery delivery;
  final Map<String, int> reactions;
  final List<String> readers;
}

class ChatSearchPage {
  const ChatSearchPage(this.messages, this.next);
  final List<ChatMessage> messages;
  final String? next;
}

/// The only seam used by presentation. SDK types stay inside data/.
abstract class ChatClient extends ChangeNotifier {
  ChatPhase get phase;
  List<ChatRoom> get rooms;
  List<ChatPerson> get people;
  String? get userId;
  Set<String> get revokedRooms;
  List<ChatMessage> messages(String room);
  List<String> typing(String room);
  bool hasOlder(String room);
  Future<void> start();
  Future<void> refreshRooms();
  Future<void> load(String room, {bool older = false});
  Future<String> send(
    String room,
    String body,
    String transactionId, {
    String? thread,
    String? replyTo,
    String? edit,
  });
  Future<void> react(String room, String event, String emoji);
  Future<void> redact(String room, String event);
  Future<void> markRead(String room);
  Future<void> setTyping(String room, bool active);
  Future<void> loadThread(String room, String root);
  Future<List<ChatPerson>> members(String room);
  Future<ChatSearchPage> search(String term, {String? next});
  Future<String> directMessage(List<String> actors);
  Future<void> upload(
    String room,
    String name,
    Uint8List bytes,
    String transactionId,
    void Function(double) progress, {
    String? thread,
  });
  Future<Uint8List> download(ChatMessage message);
  Future<String?> legacyScope(String room) async {
    final target = rooms.where((r) => r.id == room).firstOrNull;
    if (target == null) return null;
    if (target.officeRoom != null) return 'room:${target.officeRoom}';
    final others = (await members(room)).where((p) => p.id != userId).toList();
    if (others.length != 1) return null;
    final actor = people
        .where((p) => p.id == others.single.id)
        .firstOrNull
        ?.actor;
    return actor == null ? null : 'dm:$actor';
  }

  Future<List<Map<String, dynamic>>> legacy(String scope, {String? before});
  Future<void> signOut();
  Future<void> close();
}
