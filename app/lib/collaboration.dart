import 'local_inference.dart';
import 'outbox_review.dart';
import 'task_outbox.dart';
import 'leave_requests.dart';
import 'incidents.dart';
import 'sales_pipeline.dart';
import 'meetings.dart';
import 'support_cases.dart';
import 'journal_entries.dart';
import 'whiteboard.dart';
import 'payment_authorizations.dart';
import 'expense_approvals.dart';
import 'customer_directory.dart';
import 'contracts.dart';
import 'bookings.dart';
import 'chat_history.dart';
import 'room_membership.dart';
import 'document_library.dart';
import 'job_queue.dart';
import 'task_board.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

/// Loopback development client. The server authenticates every operation.
class Collaboration extends StatefulWidget {
  const Collaboration({
    super.key,
    required this.room,
    required this.position,
    required this.remote,
    required this.actors,
    required this.rooms,
    required this.onIdentity,
    required this.onPermissions,
  });
  final String room;
  final ValueNotifier<List<int>> position;
  final ValueNotifier<List<Map<String, dynamic>>> remote;
  final List<Map<String, dynamic>> actors;
  final List<Map<String, dynamic>> rooms;
  final void Function(String?) onIdentity;
  final void Function(List<String>) onPermissions;
  @override
  State<Collaboration> createState() => _CollaborationState();
}

class _CollaborationState extends State<Collaboration> {
  final token = TextEditingController();
  final draft = TextEditingController();
  final messageScroll = ScrollController();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  String session = const Uuid().v4();
  Timer? timer;
  Timer? movementTimer;
  String? identity;
  String? peer;
  String status = 'Disconnected';
  List<dynamic> messages = [];
  int online = 0;
  int sequence = 0;
  bool busy = false;
  bool sending = false;
  bool sendFailed = false;
  bool disconnecting = false;
  String? pendingId, pendingBody, pendingScope;
  TaskDelivery? taskDelivery;
  TaskDelivery? chatDelivery;
  String? outboxError;
  String? chatOutboxError;
  List<Map<String, dynamic>> queuedTasks = [];
  List<Map<String, dynamic>> queuedChat = [];
  final queueNotifier = ValueNotifier<List<Map<String, dynamic>>>([]);
  String get scope => peer == null ? 'room:${widget.room}' : 'dm:$peer';
  int _nodePort() {
    final port = int.tryParse(
      Platform.environment['MONASTACK_NODE_PORT'] ?? '47830',
    );
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('Invalid local node port');
    }
    return port;
  }

  Future<dynamic> request(String method, String path, [Object? body]) =>
      _requestWithCredential(method, path, body, token.text.trim());
  Future<dynamic> _requestWithCredential(
    String method,
    String path,
    Object? body,
    String credential,
  ) async {
    final req = await client
        .openUrl(method, Uri.parse('http://127.0.0.1:${_nodePort()}$path'))
        .timeout(const Duration(seconds: 3));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $credential');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close().timeout(const Duration(seconds: 3));
    final text = await utf8.decoder
        .bind(res)
        .join()
        .timeout(const Duration(seconds: 3));
    if (res.statusCode >= 400) throw NodeFailure(res.statusCode);
    return text.isEmpty ? null : jsonDecode(text);
  }

  Future<void> connect() async {
    try {
      final me = await request('GET', '/v1/me') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        identity = me['actor'] as String;
        status = 'Connecting';
      });
      widget.onIdentity(identity);
      final who = identity!;
      final authority = me['authority_id'] as String?;
      if (authority == null ||
          !RegExp(r'^[a-f0-9-]{36}$').hasMatch(authority)) {
        setState(
          () => outboxError = 'Node identity unavailable; task writes disabled',
        );
      }
      final capturedSession = session;
      final credential = token.text.trim();
      try {
        if (authority == null ||
            !RegExp(r'^[a-f0-9-]{36}$').hasMatch(authority)) {
          throw const OutboxFailure('invalid_authority');
        }
        final queue = await TaskOutbox.open('${authority}_$who');
        if (!mounted || identity != who || session != capturedSession) return;
        taskDelivery = TaskDelivery(
          outbox: queue,
          network: (method, path, [body]) =>
              _requestWithCredential(method, path, body, credential),
          active: () =>
              mounted &&
              identity == who &&
              session == capturedSession &&
              !disconnecting,
          onChanged: (items) {
            if (mounted) {
              queueNotifier.value = items;
              setState(() {
                queuedTasks = items;
                outboxError = null;
              });
            }
          },
        );
        await taskDelivery!.updateView();
      } catch (_) {
        if (mounted) setState(() => outboxError = 'Task queue unavailable');
      }
      try {
        if (authority == null ||
            !RegExp(r'^[a-f0-9-]{36}$').hasMatch(authority)) {
          throw const OutboxFailure('invalid_authority');
        }
        final queue = await TaskOutbox.open('${authority}_$who', chat: true);
        if (!mounted || identity != who || session != capturedSession) return;
        chatDelivery = TaskDelivery(
          outbox: queue,
          network: (method, path, [body]) =>
              _requestWithCredential(method, path, body, credential),
          active: () =>
              mounted &&
              identity == who &&
              session == capturedSession &&
              !disconnecting,
          onChanged: (items) {
            if (mounted) {
              setState(() {
                queuedChat = items;
                chatOutboxError = null;
              });
            }
          },
        );
        await chatDelivery!.updateView();
      } catch (_) {
        if (mounted) {
          setState(
            () => chatOutboxError =
                'Message queue unavailable; sending disabled.',
          );
        }
      }
      timer?.cancel();
      timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
      await refresh();
    } catch (_) {
      if (mounted) setState(() => status = 'Connection failed');
    }
  }

  Future<void> refresh() async {
    if (identity == null || busy || disconnecting) return;
    busy = true;
    final requestedScope = scope;
    final requestedRoom = widget.room;
    final requestedPosition = List<int>.of(widget.position.value);
    final requestedIdentity = identity;
    try {
      final rooms = (await request('GET', '/v1/rooms') as List).cast<String>();
      if (!mounted || identity != requestedIdentity) return;
      widget.onPermissions(rooms);
      await request('POST', '/v1/presence', {
        'session': session,
        'room': requestedRoom,
        'x': requestedPosition[0],
        'y': requestedPosition[1],
        'seq': ++sequence,
      });
      final people = await request('GET', '/v1/presence') as List<dynamic>;
      final chat = await request(
        'GET',
        '/v1/messages/${Uri.encodeComponent(requestedScope)}',
      ) as List<dynamic>;
      if (mounted &&
          identity == requestedIdentity &&
          scope == requestedScope &&
          widget.room == requestedRoom) {
        final delivery = taskDelivery;
        if (delivery != null) {
          unawaited(
            delivery.drain().catchError((_) {
              if (mounted && identical(taskDelivery, delivery)) {
                setState(() => outboxError = 'Task queue unavailable');
              }
            }),
          );
        }
        final chatQueue = chatDelivery;
        if (chatQueue != null) {
          unawaited(
            chatQueue.drain().catchError((_) {
              if (mounted && identical(chatDelivery, chatQueue)) {
                setState(
                  () => chatOutboxError =
                      'Message queue unavailable; sending disabled.',
                );
              }
            }),
          );
        }
        final followMessages =
            !messageScroll.hasClients ||
            messageScroll.position.maxScrollExtent - messageScroll.offset < 40;
        setState(() {
          online = people.length;
          widget.remote.value = people
              .cast<Map<String, dynamic>>()
              .where((p) => p['session'] != session)
              .toList();
          messages = chat;
          status = 'Connected';
        });
        if (followMessages) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && messageScroll.hasClients) {
              messageScroll.jumpTo(messageScroll.position.maxScrollExtent);
            }
          });
        }
      }
    } catch (e) {
      if (mounted &&
          identity == requestedIdentity &&
          scope == requestedScope &&
          widget.room == requestedRoom) {
        widget.onPermissions([]);
        setState(() {
          status = 'Offline or access denied';
          messages = [];
          online = 0;
          widget.remote.value = [];
        });
      }
    } finally {
      busy = false;
      if (mounted &&
          identity != null &&
          (scope != requestedScope || widget.room != requestedRoom)) {
        refresh();
      }
    }
  }

  Future<void> send() async {
    if (identity == null ||
        draft.text.trim().isEmpty ||
        sending ||
        disconnecting) {
      return;
    }
    final content = draft.text.trim();
    final sendScope = scope;
    if (pendingBody != content || pendingScope != sendScope) {
      pendingId = const Uuid().v4();
      pendingBody = content;
      pendingScope = sendScope;
    }
    final id = pendingId!;
    sendFailed = false;
    setState(() => sending = true);
    try {
      final delivery = chatDelivery;
      if (delivery == null) throw const OutboxFailure('queue_unavailable');
      final path = '/v1/messages/${Uri.encodeComponent(sendScope)}';
      if (!TaskOutbox.supports('POST', path)) {
        throw const OutboxFailure('unsupported_message_target');
      }
      await delivery.request('POST', path, {
        'id': id,
        'op': id,
        'body': content,
      });
      if (mounted) {
        if (draft.text.trim() == content && scope == sendScope) draft.clear();
        pendingId = pendingBody = pendingScope = null;
        await refresh();
      }
    } on TaskChangeQueued {
      if (mounted) {
        if (draft.text.trim() == content && scope == sendScope) draft.clear();
        pendingId = pendingBody = pendingScope = null;
        setState(() => status = 'Message queued');
      }
    } on TaskChangeRejected {
      if (mounted) {
        if (draft.text.trim() == content && scope == sendScope) draft.clear();
        pendingId = pendingBody = pendingScope = null;
        setState(() => status = 'Message rejected; review queue');
      }
    } catch (_) {
      sendFailed = true;
      if (mounted) {
        setState(() => status = 'Send failed; message kept in draft');
      }
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> disconnect() async {
    if (disconnecting) return;
    disconnecting = true;
    timer?.cancel();
    movementTimer?.cancel();
    final waitForSend = sending;
    while (sending && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!mounted) return;
    if (waitForSend && sendFailed) {
      while (busy && mounted) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (!mounted) return;
      disconnecting = false;
      timer = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
      setState(() => status = 'Send failed; message kept in draft');
      return;
    }
    try {
      await taskDelivery?.waitForDrain();
      await chatDelivery?.waitForDrain();
    } catch (_) {}
    while (busy && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!mounted) return;
    try {
      await request('DELETE', '/v1/presence/${Uri.encodeComponent(session)}');
    } catch (_) {
      /* expiry handles offline disconnects */
    }
    if (!mounted) return;
    setState(() {
      identity = null;
      taskDelivery = null;
      chatDelivery = null;
      queuedTasks = [];
      queuedChat = [];
      queueNotifier.value = [];
      outboxError = null;
      chatOutboxError = null;
      disconnecting = false;
      session = const Uuid().v4();
      sequence = 0;
      widget.remote.value = [];
      peer = null;
      messages = [];
      pendingId = pendingBody = pendingScope = null;
      draft.clear();
      token.clear();
      status = 'Disconnected';
    });
    widget.onIdentity(null);
  }

  Future<dynamic> taskRequest(
    String method,
    String path, [
    Object? body,
  ]) async {
    if (!TaskOutbox.supports(method, path)) return request(method, path, body);
    final delivery = taskDelivery;
    if (delivery == null) throw const OutboxFailure('unavailable');
    return delivery.request(method, path, body);
  }

  void positionChanged() {
    if (movementTimer?.isActive ?? false) return;
    movementTimer = Timer(const Duration(milliseconds: 350), refresh);
  }

  @override
  void initState() {
    super.initState();
    widget.position.addListener(positionChanged);
  }

  @override
  void didUpdateWidget(covariant Collaboration old) {
    super.didUpdateWidget(old);
    if (old.position != widget.position) {
      old.position.removeListener(positionChanged);
      widget.position.addListener(positionChanged);
    }
    if (old.room != widget.room && identity != null) {
      messages = [];
      refresh();
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    movementTimer?.cancel();
    widget.position.removeListener(positionChanged);
    client.close(force: true);
    queueNotifier.dispose();
    token.dispose();
    draft.dispose();
    messageScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              identity == null ? 'Connect to local node' : 'Chat · $status',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          if (identity != null)
            IconButton(
              tooltip: 'Conversation history',
              onPressed: () {
                final selectedScope = scope;
                showDialog<void>(
                  context: context,
                  builder: (_) =>
                      ChatHistory(request: request, scope: selectedScope),
                );
              },
              icon: const Icon(Icons.history, size: 18),
            ),
          if (identity != null)
            IconButton(
              tooltip: 'Disconnect',
              onPressed: disconnect,
              icon: const Icon(Icons.logout, size: 18),
            ),
        ],
      ),
      if (identity == null) ...[
        TextField(
          controller: token,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Enrollment token',
            isDense: true,
          ),
        ),
        Row(
          children: [
            TextButton(onPressed: connect, child: const Text('Connect')),
            Expanded(child: Text(status, style: const TextStyle(fontSize: 11))),
          ],
        ),
        const Text(
          'Local node only · voice unavailable',
          style: TextStyle(fontSize: 11, color: Colors.black54),
        ),
      ] else ...[
        PopupMenuButton<String>(
          tooltip: 'Workspace tools',
          onSelected: (choice) {
            final Widget target = switch (choice) {
              'tasks' => TaskBoard(
                request: taskRequest,
                actors: widget.actors,
                queue: queueNotifier,
                reviewQueue: () {
                  final delivery = taskDelivery;
                  if (delivery != null) {
                    showDialog<void>(
                      context: context,
                      builder: (context) => OutboxReview(delivery: delivery),
                    );
                  }
                },
              ),
              'agents' => JobQueue(request: request, actors: widget.actors),
              'room-admin' => RoomMembership(
                request: request,
                actors: widget.actors,
                rooms: widget.rooms,
              ),
              'inference' => const LocalInference(),
              'documents' => DocumentLibrary(
                request: request,
                rooms: widget.rooms,
              ),
              'customers' => CustomerDirectory(request: request),
              'sales' => SalesPipeline(request: request),
              'contracts' => Contracts(request: request, identity: identity),
              'bookings' => Bookings(request: request),
              'support' => SupportCases(request: request),
              'meetings' => Meetings(
                request: request,
                rooms: widget.rooms,
                identity: identity,
              ),
              'whiteboard' => Whiteboard(request: request, rooms: widget.rooms),
              'expenses' => ExpenseApprovals(
                request: request,
                identity: identity,
              ),
              'journals' => JournalEntries(
                request: request,
                identity: identity,
              ),
              'payments' => PaymentAuthorizations(
                request: request,
                identity: identity,
              ),
              'incidents' => Incidents(request: request, identity: identity),
              _ => LeaveRequests(request: request, identity: identity),
            };
            showDialog<void>(context: context, builder: (context) => target);
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'tasks', child: Text('Open task board')),
            PopupMenuItem(value: 'agents', child: Text('Agent proposals')),
            PopupMenuItem(value: 'room-admin', child: Text('Room membership')),
            PopupMenuItem(value: 'documents', child: Text('Documents')),
            PopupMenuItem(value: 'inference', child: Text('Local text model')),
            PopupMenuItem(value: 'customers', child: Text('Customers')),
            PopupMenuItem(value: 'sales', child: Text('Sales pipeline')),
            PopupMenuItem(
              value: 'contracts',
              child: Text('Contract proposals'),
            ),
            PopupMenuItem(value: 'bookings', child: Text('Customer bookings')),
            PopupMenuItem(value: 'support', child: Text('Customer support')),
            PopupMenuItem(value: 'meetings', child: Text('Meetings')),
            PopupMenuItem(value: 'whiteboard', child: Text('Whiteboard')),
            PopupMenuItem(value: 'expenses', child: Text('Expense approvals')),
            PopupMenuItem(value: 'journals', child: Text('Journal entries')),
            PopupMenuItem(
              value: 'payments',
              child: Text('Payment authorizations'),
            ),
            PopupMenuItem(value: 'leave', child: Text('Leave requests')),
            PopupMenuItem(value: 'incidents', child: Text('Incidents')),
          ],
          child: const Padding(
            padding: EdgeInsets.all(8),
            child: Text('Workspace tools'),
          ),
        ),
        if (outboxError != null)
          Text(
            outboxError!,
            style: const TextStyle(color: Colors.red, fontSize: 11),
          ),
        if (chatOutboxError != null)
          Text(
            chatOutboxError!,
            style: const TextStyle(color: Colors.red, fontSize: 11),
          ),
        if (queuedChat.isNotEmpty && chatDelivery != null)
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) =>
                  OutboxReview(delivery: chatDelivery!, chat: true),
            ),
            child: Text('Messages pending/rejected: ${queuedChat.length}'),
          ),
        if (queuedTasks.isNotEmpty && taskDelivery != null)
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => OutboxReview(delivery: taskDelivery!),
            ),
            child: Text('Task changes pending/rejected: ${queuedTasks.length}'),
          ),
        Text(
          '$online visible session(s) · voice unavailable',
          style: const TextStyle(fontSize: 11, color: Colors.black54),
        ),
        DropdownButton<String>(
          isExpanded: true,
          value: peer ?? '',
          items: [
            const DropdownMenuItem(value: '', child: Text('Room conversation')),
            ...widget.actors
                .where((a) => a['kind'] == 'human' && a['id'] != identity)
                .map(
                  (a) => DropdownMenuItem(
                    value: a['id'] as String,
                    child: Text('DM · ${a['name']}'),
                  ),
                ),
          ],
          onChanged: (v) {
            setState(() {
              peer = v == '' ? null : v;
              messages = [];
            });
            refresh();
          },
        ),
        SizedBox(
          height: 120,
          child: messages.isEmpty
              ? const Center(
                  child: Text(
                    'No messages',
                    style: TextStyle(color: Colors.black45),
                  ),
                )
              : ListView.builder(
                  controller: messageScroll,
                  itemCount: messages.length,
                  itemBuilder: (context, i) {
                    final m = messages[i] as Map<String, dynamic>;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '${m['sender']}: ${m['body']}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    );
                  },
                ),
        ),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: draft,
                onSubmitted: (_) => send(),
                decoration: const InputDecoration(
                  hintText: 'Write a message',
                  isDense: true,
                ),
              ),
            ),
            IconButton(
              onPressed: sending || disconnecting ? null : send,
              tooltip: 'Send',
              icon: const Icon(Icons.send),
            ),
          ],
        ),
        const Text(
          'Message queue stores text unencrypted on this device.',
          style: TextStyle(fontSize: 10, color: Colors.black54),
        ),
      ],
    ],
  );
}
