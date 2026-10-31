import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../domain/chat_client.dart';

final chatClientProvider = Provider<ChatClient>(
  (ref) => throw StateError('No chat session'),
);
final chatControllerProvider = Provider<ChatController>((ref) {
  final controller = ChatController(ref.watch(chatClientProvider));
  ref.onDispose(controller.dispose);
  return controller;
});

enum ChatFilter { all, unreads, mentions }

enum SidePane { none, thread, details, members, search }

enum PaneLoad { ready, loading, error }

class ChatDraft {
  String text = '';
  String? reply, edit;
}

class PendingMessage {
  PendingMessage({
    required this.room,
    required this.body,
    required this.transaction,
    this.thread,
    this.reply,
    this.edit,
    this.bytes,
    this.name,
  });
  final String room, body, transaction;
  final String? thread, reply, edit, name;
  final Uint8List? bytes;
  String? eventId;
  Delivery delivery = Delivery.sending;
  double progress = 0;
  ChatMessage get message => ChatMessage(
    id: eventId ?? transaction,
    roomId: room,
    sender: 'You',
    body: body,
    time: DateTime.now(),
    own: true,
    transactionId: transaction,
    delivery: delivery,
    thread: thread,
  );
}

class ChatController extends ChangeNotifier {
  ChatController(this.client) {
    client.addListener(_changed);
  }
  final ChatClient client;
  String? selected, thread;
  SidePane pane = SidePane.none;
  PaneLoad threadState = PaneLoad.ready;
  ChatFilter filter = ChatFilter.all;
  String? error;
  bool loading = false, searching = false;
  final Set<String> loadingRooms = {};
  List<ChatMessage> searchResults = [];
  String searchTerm = '';
  String? searchNext;
  final Map<String, ChatDraft> _drafts = {};
  final List<PendingMessage> pending = [];
  bool _disposed = false;
  int _searchGeneration = 0;
  final Map<String, DateTime> _typingSent = {};
  int get unread => client.rooms.fold(0, (n, r) => n + r.unread);
  ChatRoom? get room => client.rooms.where((r) => r.id == selected).firstOrNull;
  String draftKey(String room, String? root) => '$room|${root ?? ''}';
  ChatDraft draft(String room, [String? root]) =>
      _drafts.putIfAbsent(draftKey(room, root), ChatDraft.new);
  void _changed() {
    final revoked = client.revokedRooms;
    _drafts.removeWhere(
      (key, _) => revoked.any((id) => key.startsWith('$id|')),
    );
    pending.removeWhere((p) => revoked.contains(p.room));
    searchResults.removeWhere((m) => revoked.contains(m.roomId));
    if (revoked.contains(selected)) {
      selected = null;
      thread = null;
      pane = SidePane.none;
      error = 'Access to this conversation has ended.';
    }
    if (client.phase == ChatPhase.signedOut) {
      _searchGeneration++;
      _drafts.clear();
      pending.clear();
      selected = thread = null;
      searchResults.clear();
    }
    notifyListeners();
  }

  Future<void> select(String id) async {
    if (!client.rooms.any((r) => r.id == id)) return;
    selected = id;
    thread = null;
    pane = SidePane.none;
    error = null;
    loading = true;
    notifyListeners();
    try {
      await client.load(id);
    } catch (_) {
      if (selected == id) {
        error = 'Conversation unavailable. Retry to reconnect.';
      }
    } finally {
      if (!_disposed && selected == id) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> older(String id) async {
    if (!loadingRooms.add(id)) return;
    notifyListeners();
    await act(() => client.load(id, older: true));
    loadingRooms.remove(id);
    if (!_disposed) notifyListeners();
  }

  List<ChatMessage> timeline(String id, {String? root}) {
    final events = client.messages(id);
    final local = pending
        .where(
          (p) =>
              p.room == id &&
              !(p.edit != null && p.delivery == Delivery.sent) &&
              !events.any(
                (e) => e.id == p.eventId || e.transactionId == p.transaction,
              ),
        )
        .map((p) => p.message);
    return [...local, ...events]
        .where(
          (m) => root == null
              ? m.thread == null
              : m.thread == root || m.id == root,
        )
        .toList();
  }

  Future<void> send(String id, {String? root}) async {
    final value = draft(id, root);
    final text = value.text;
    if (text.trim().isEmpty ||
        !client.rooms.any((r) => r.id == id && r.canPost)) {
      return;
    }
    // A failed send retains its immutable envelope and transaction. Pressing Enter
    // again on an unchanged draft retries it instead of creating another event.
    final prior = pending
        .where(
          (p) =>
              p.room == id &&
              p.thread == root &&
              p.body == text &&
              p.reply == value.reply &&
              p.edit == value.edit &&
              p.bytes == null &&
              p.delivery != Delivery.sent,
        )
        .firstOrNull;
    if (prior?.delivery == Delivery.sending) return;
    final item =
        prior ??
        PendingMessage(
          room: id,
          body: text,
          transaction: const Uuid().v4(),
          thread: root,
          reply: value.reply,
          edit: value.edit,
        );
    if (prior == null) pending.insert(0, item);
    await retry(item);
  }

  Future<void> retry(PendingMessage item) async {
    if (!client.rooms.any((r) => r.id == item.room && r.canPost)) return;
    item.delivery = Delivery.sending;
    error = null;
    notifyListeners();
    try {
      if (item.bytes != null) {
        await client.upload(
          item.room,
          item.name!,
          item.bytes!,
          item.transaction,
          (progress) {
            item.progress = progress;
            if (!_disposed) notifyListeners();
          },
          thread: item.thread,
        );
        pending.remove(item);
      } else {
        item.eventId = await client.send(
          item.room,
          item.body,
          item.transaction,
          thread: item.thread,
          replyTo: item.reply,
          edit: item.edit,
        );
        item.delivery = Delivery.sent;
      }
      if (_disposed || !client.rooms.any((r) => r.id == item.room)) return;
      final value = draft(item.room, item.thread);
      if (value.text == item.body) {
        value.text = '';
        value.reply = value.edit = null;
      }
      _typing(item.room, false);
    } catch (_) {
      if (_disposed || !client.rooms.any((r) => r.id == item.room)) return;
      item.delivery = Delivery.failed;
      error = 'Message not sent. Your draft is kept; retry when connected.';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> attach(
    String id,
    String name,
    Uint8List bytes, {
    String? root,
  }) async {
    final item = PendingMessage(
      room: id,
      body: name,
      transaction: const Uuid().v4(),
      thread: root,
      bytes: bytes,
      name: name,
    );
    pending.insert(0, item);
    await retry(item);
  }

  void text(String id, String value, {String? root}) {
    draft(id, root).text = value;
    _typing(id, value.isNotEmpty);
  }

  /// One typing notice per state change, refreshed before the server expires it.
  void _typing(String id, bool active) {
    final sent = _typingSent[id];
    final now = DateTime.now();
    if (active
        ? sent != null && now.difference(sent) < const Duration(seconds: 15)
        : sent == null) {
      return;
    }
    if (active) {
      _typingSent[id] = now;
    } else {
      _typingSent.remove(id);
    }
    unawaited(client.setTyping(id, active).catchError((_) {}));
  }

  Future<void> mode(
    String id,
    ChatMessage message, {
    bool edit = false,
    String? root,
  }) async {
    if (selected != id) await select(id);
    if (selected != id || _disposed) return;
    if (pane == SidePane.search) pane = SidePane.none;
    final value = draft(id, root);
    if (edit) {
      value.edit = message.id;
      value.reply = null;
      value.text = message.body;
    } else {
      value.reply = message.id;
      value.edit = null;
    }
    notifyListeners();
  }

  void cancelMode(String id, {String? root}) {
    final value = draft(id, root);
    value.reply = value.edit = null;
    notifyListeners();
  }

  Future<void> openThread(ChatMessage message) async {
    if (selected != message.roomId) await select(message.roomId);
    if (selected != message.roomId) return;
    thread = message.thread ?? message.id;
    pane = SidePane.thread;
    await refreshThread();
  }

  Future<void> refreshThread() async {
    final id = selected, root = thread;
    if (id == null || root == null) return;
    threadState = PaneLoad.loading;
    notifyListeners();
    try {
      await client.loadThread(id, root);
      if (!_disposed && selected == id && thread == root) {
        threadState = PaneLoad.ready;
      }
    } catch (_) {
      if (!_disposed && selected == id && thread == root) {
        threadState = PaneLoad.error;
      }
    }
    if (!_disposed) notifyListeners();
  }

  void side(SidePane value) {
    pane = value;
    notifyListeners();
  }

  void setFilter(ChatFilter value) {
    filter = value;
    notifyListeners();
  }

  Future<void> search(String term, {bool more = false}) async {
    if (term.trim().isEmpty) return;
    final generation = ++_searchGeneration;
    pane = SidePane.search;
    searching = true;
    error = null;
    if (!more) {
      searchResults = [];
      searchNext = null;
    }
    searchTerm = term;
    notifyListeners();
    try {
      final result = await client.search(term, next: more ? searchNext : null);
      if (_disposed || generation != _searchGeneration) return;
      searchResults = [...searchResults, ...result.messages]
          .where(
            (m) =>
                !client.revokedRooms.contains(m.roomId) &&
                client.rooms.any((r) => r.id == m.roomId),
          )
          .toList();
      searchNext = result.next;
    } catch (_) {
      if (generation == _searchGeneration) {
        error = 'Search unavailable. Retry your search.';
      }
    } finally {
      if (!_disposed && generation == _searchGeneration) {
        searching = false;
        notifyListeners();
      }
    }
  }

  Future<void> act(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      error = 'Could not complete this action. Check access and retry.';
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    client.removeListener(_changed);
    super.dispose();
  }
}
