import 'package:monastack/features/agents/agent_configuration.dart';
import 'package:monastack/features/office/voice/live_agent_panel.dart';
import 'package:monastack/features/inference/local_inference.dart';
import 'package:monastack/features/sync/outbox_review.dart';
import 'package:monastack/features/sync/task_outbox.dart';
import 'package:monastack/features/hr/leave_requests.dart';
import 'package:monastack/features/operations/incidents.dart';
import 'package:monastack/features/customers/sales_pipeline.dart';
import 'package:monastack/features/knowledge/meetings.dart';
import 'package:monastack/features/customers/support_cases.dart';
import 'package:monastack/features/finance/journal_entries.dart';
import 'package:monastack/features/knowledge/whiteboard.dart';
import 'package:monastack/features/finance/payment_authorizations.dart';
import 'package:monastack/features/finance/expense_approvals.dart';
import 'package:monastack/features/customers/customer_directory.dart';
import 'package:monastack/features/customers/contracts.dart';
import 'package:monastack/features/customers/bookings.dart';
import 'package:monastack/features/identity/account_dialogs.dart';
import 'package:monastack/features/identity/auth_api.dart';
import 'package:monastack/features/identity/auth_session.dart';
import 'package:monastack/features/identity/credential_store.dart';
import 'package:monastack/features/identity/sign_in_panel.dart';
import 'package:monastack/features/office/communication/chat_history.dart';
import 'package:monastack/features/office/presence/realtime_session.dart';
import 'package:monastack/features/office/voice/camera_faces.dart';
import 'package:monastack/features/office/voice/voice_controller.dart';
import 'package:monastack/features/office/voice/voice_panel.dart';
import 'package:monastack/features/office/communication/workspace_tools.dart';
import 'package:monastack/features/office/rooms/room_membership.dart';
import 'package:monastack/features/knowledge/document_library.dart';
import 'package:monastack/features/agents/job_queue.dart';
import 'package:monastack/features/agents/agent_chat.dart';
import 'package:monastack/features/tasks/task_board.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:monastack/shared/node_request.dart';

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
    this.speaking,
    this.audioLevels,
    this.onlineAgents,
    this.agentPresentation,
    this.faces,
    this.company = '',
    this.onWorkspaceName,
  });
  final String room;
  final ValueNotifier<List<int>> position;
  final ValueNotifier<List<Map<String, dynamic>>> remote;
  final List<Map<String, dynamic>> actors;
  final List<Map<String, dynamic>> rooms;
  final void Function(String?) onIdentity;
  final void Function(List<String>) onPermissions;

  /// Receives the actors currently speaking in voice, for the office view.
  final ValueNotifier<Set<String>>? speaking;
  final ValueNotifier<Map<String, double>>? audioLevels;
  final ValueNotifier<Set<String>>? onlineAgents;
  final ValueNotifier<Map<String, dynamic>>? agentPresentation;

  /// Receives live camera views by actor, which replace avatar faces.
  final ValueNotifier<Map<String, Widget>>? faces;

  /// Suggested company name for setting up a new node.
  final String company;

  /// Receives the signed-in workspace's name, or `null` when signed out.
  final void Function(String?)? onWorkspaceName;
  @override
  State<Collaboration> createState() => CollaborationState();
}

class CollaborationState extends State<Collaboration> {
  Future<void> openWorkspaceTools() async {
    if (identity == null) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => WorkspaceTools(
        account: auth.signedIn,
        admin: auth.account?.admin ?? false,
      ),
    );
    if (choice == null || !mounted) return;
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
      'account' => AccountDialog(request: request, account: auth.account!),
      'people' => PeopleAdmin(request: request, account: auth.account!),
      'company' => CompanyAdmin(request: request, account: auth.account!),
      'agent-chat' => AlertDialog(
        content: AgentChat(request: request, actors: widget.actors),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
      'agent-configuration' => AgentConfiguration(request: request),
      'agents' => JobQueue(request: request, actors: widget.actors),
      'room-admin' => RoomMembership(
        request: request,
        actors: widget.actors,
        rooms: widget.rooms,
      ),
      'inference' => const LocalInference(),
      'documents' => DocumentLibrary(request: request, rooms: widget.rooms),
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
      'expenses' => ExpenseApprovals(request: request, identity: identity),
      'journals' => JournalEntries(request: request, identity: identity),
      'payments' => PaymentAuthorizations(request: request, identity: identity),
      'incidents' => Incidents(request: request, identity: identity),
      _ => LeaveRequests(request: request, identity: identity),
    };
    if (!context.mounted) return;
    showDialog<void>(context: context, builder: (context) => target);
  }

  void openAgentChat(String agent) {
    if (!auth.active) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sign in to chat with agents.')),
      );
      return;
    }
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        content: AgentChat(
          request: request,
          actors: widget.actors,
          initialAgent: agent,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  final token = TextEditingController();
  late final AuthSession auth = AuthSession(
    api: AuthApi(port: _nodePort()),
    store: Platform.environment['MONASTACK_CREDENTIAL_STORE'] == 'memory'
        ? MemoryCredentialStore()
        : KeychainCredentialStore(),
  );
  bool connecting = false;
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

  /// Realtime presence is a separate capability; chat keeps working when it
  /// is unavailable.
  RealtimeSession? realtime;
  bool presenceAvailable = false;
  Timer? presenceTimer;
  bool presenceBusy = false;
  List<int>? published;
  String? publishedRoom;
  DateTime publishedAt = DateTime.fromMillisecondsSinceEpoch(0);
  VoiceController? voice;
  Map<String, dynamic>? liveAgent;
  DateTime liveAgentAt = DateTime(2000);
  bool liveAgentBusy = false;

  /// Consecutive presence failures; the last snapshot is kept for a few
  /// seconds so one dropped request does not make everyone vanish.
  int presenceFailures = 0;
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

  /// Sends an authenticated request. A signed-in session renews its access
  /// token once if the node reports it expired.
  Future<dynamic> request(String method, String path, [Object? body]) async {
    if (!auth.active) throw const NodeFailure(401);
    try {
      return await _requestWithCredential(
        method,
        path,
        body,
        await auth.bearer(),
      );
    } on NodeFailure catch (e) {
      if (e.status != 401 || !auth.signedIn || !await auth.refreshNow()) {
        rethrow;
      }
      return _requestWithCredential(method, path, body, await auth.bearer());
    } on StateError {
      throw const NodeFailure(401);
    }
  }

  Future<dynamic> _requestWithCredential(
    String method,
    String path,
    Object? body,
    String credential,
  ) async {
    final req = await client
        .openUrl(
          method,
          Uri.parse('http://${auth.api.host}:${_nodePort()}$path'),
        )
        .timeout(const Duration(seconds: 3));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $credential');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close().timeout(
      Duration(
        seconds: path.startsWith('/v1/agents/') && path.endsWith('/chat')
            ? 65
            : 3,
      ),
    );
    final text = await utf8.decoder
        .bind(res)
        .join()
        .timeout(const Duration(seconds: 3));
    if (res.statusCode >= 400) throw NodeFailure(res.statusCode);
    return text.isEmpty ? null : jsonDecode(text);
  }

  /// Signs in or out of collaboration as the session changes.
  void _authChanged() {
    if (!mounted) return;
    widget.onWorkspaceName?.call(auth.account?.workspaceName);
    if (auth.active && identity == null && !connecting) {
      connect();
    } else if (!auth.active && identity != null) {
      disconnect();
    }
    setState(() {});
  }

  /// Ends collaboration, then the session (sign-out) or device token.
  Future<void> signOut() async {
    await disconnect();
    if (identity == null) await auth.signOut();
  }

  Future<void> connect() async {
    if (connecting) return;
    connecting = true;
    try {
      final me = await request('GET', '/v1/me') as Map<String, dynamic>;
      realtime = RealtimeSession(
        client: client,
        issue: () =>
            request('POST', '/v1/realtime/ticket', const <String, dynamic>{}),
      );
      if (!mounted) return;
      setState(() {
        identity = me['actor'] as String;
        status = 'Connecting';
      });
      widget.onIdentity(identity);
      unawaited(refreshAgentAppearances());
      final who = identity!;
      final authority = me['authority_id'] as String?;
      if (authority == null ||
          !RegExp(r'^[a-f0-9-]{36}$').hasMatch(authority)) {
        setState(
          () => outboxError = 'Node identity unavailable; task writes disabled',
        );
      }
      final capturedSession = session;
      try {
        if (authority == null ||
            !RegExp(r'^[a-f0-9-]{36}$').hasMatch(authority)) {
          throw const OutboxFailure('invalid_authority');
        }
        final queue = await TaskOutbox.open('${authority}_$who');
        if (!mounted || identity != who || session != capturedSession) return;
        taskDelivery = TaskDelivery(
          outbox: queue,
          network: request,
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
          network: request,
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
      presenceTimer?.cancel();
      presenceTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => refreshPresence(),
      );
      voice?.dispose();
      voice = VoiceController(realtime: realtime!, session: () => session)
        ..addListener(_voiceChanged);
      await voice!.follow(widget.room);
      await refresh();
      await refreshPresence();
    } catch (_) {
      if (mounted) setState(() => status = 'Connection failed');
      // A wrong device token is simply refused; a signed-in session stays
      // and can retry.
      if (auth.usingDeviceToken) await auth.signOut();
    } finally {
      connecting = false;
    }
  }

  Future<void> refresh() async {
    if (identity == null || busy || disconnecting) return;
    busy = true;
    final requestedScope = scope;
    final requestedRoom = widget.room;
    final requestedIdentity = identity;
    try {
      final rooms = (await request('GET', '/v1/rooms') as List).cast<String>();
      if (!mounted || identity != requestedIdentity) return;
      widget.onPermissions(rooms);
      unawaited(voice?.refreshAvailability());
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

  /// Publishes this session's position when it changed (or every 5 s as a
  /// heartbeat) and reads visible presence. Runs every second and right after
  /// movement; a failure only affects presence, never chat.
  Future<void> refreshPresence() async {
    unawaited(refreshAgentAppearances());
    final presence = realtime;
    if (identity == null || presence == null || presenceBusy || disconnecting) {
      return;
    }
    presenceBusy = true;
    final requestedIdentity = identity;
    final requestedRoom = widget.room;
    final position = List<int>.of(widget.position.value);
    try {
      final now = DateTime.now();
      final moved =
          published == null ||
          published![0] != position[0] ||
          published![1] != position[1] ||
          publishedRoom != requestedRoom;
      if (position.every((c) => c >= 0) &&
          (moved || now.difference(publishedAt).inSeconds >= 5)) {
        await presence.request('POST', '/v1/presence', {
          'session': session,
          'room': requestedRoom,
          'x': position[0],
          'y': position[1],
          'seq': ++sequence,
        });
        published = position;
        publishedRoom = requestedRoom;
        publishedAt = now;
      }
      unawaited(refreshLiveAgent());
      final people = await presence.request('GET', '/v1/presence') as List;
      presenceFailures = 0;
      if (mounted && identity == requestedIdentity && !disconnecting) {
        setState(() {
          presenceAvailable = true;
          online = people.length;
          widget.remote.value = people
              .cast<Map<String, dynamic>>()
              .where((p) => p['session'] != session)
              .toList();
        });
      }
    } catch (_) {
      // Presence failure leaves text chat available.
      published = null;
      if (++presenceFailures >= 3 &&
          mounted &&
          identity == requestedIdentity &&
          !disconnecting) {
        setState(() {
          presenceAvailable = false;
          online = 0;
          widget.remote.value = [];
        });
      }
    } finally {
      presenceBusy = false;
      final current = widget.position.value;
      if (mounted &&
          identity != null &&
          !disconnecting &&
          (current[0] != position[0] ||
              current[1] != position[1] ||
              widget.room != requestedRoom)) {
        positionChanged();
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

  Map<String, dynamic> agentAppearances = {};
  bool appearancesBusy = false;
  DateTime appearancesAt = DateTime(2000);

  void resetAgentSpeech() {
    widget.agentPresentation?.value = {
      for (final entry in agentAppearances.entries)
        entry.key: {...entry.value as Map, 'text': '', 'at': 0},
    };
  }

  Future<void> refreshAgentAppearances() async {
    if (identity == null ||
        disconnecting ||
        appearancesBusy ||
        DateTime.now().difference(appearancesAt).inSeconds < 5) {
      return;
    }
    appearancesBusy = true;
    final who = identity;
    final capturedSession = session;
    try {
      final result = await request('GET', '/v1/agents/appearances') as List;
      if (!mounted ||
          identity != who ||
          session != capturedSession ||
          disconnecting) {
        return;
      }
      agentAppearances = {
        for (final agent in result)
          agent['id'] as String: {
            'name': agent['name'],
            'gender': agent['gender'],
            'voice': agent['voice'],
          },
      };
      final previous = widget.agentPresentation?.value ?? {};
      widget.agentPresentation?.value = {
        for (final entry in agentAppearances.entries)
          entry.key: {
            ...entry.value as Map,
            'text': previous[entry.key]?['text'] ?? '',
            'at': previous[entry.key]?['at'] ?? 0,
          },
      };
      appearancesAt = DateTime.now();
    } catch (_) {
      // A transient metadata failure retains the last known Office appearance.
    } finally {
      appearancesBusy = false;
    }
  }

  Future<void> refreshLiveAgent() async {
    if (liveAgentBusy ||
        identity == null ||
        disconnecting ||
        DateTime.now().difference(liveAgentAt).inMilliseconds < 1500) {
      return;
    }
    liveAgentBusy = true;
    liveAgentAt = DateTime.now();
    final room = widget.room;
    final who = identity;
    try {
      final result = await request(
        'GET',
        '/v1/live-agents/rooms/$room',
      ) as Map<String, dynamic>;
      if (!mounted || who != identity || room != widget.room || disconnecting) {
        return;
      }
      setState(() => liveAgent = result);
      final selected = result['selected'] as String;
      final captions = (result['captions'] as List? ?? [])
          .where((c) => c['speaker'] == selected)
          .toList();
      final last = captions.isEmpty ? null : captions.last;
      final appearances =
          result['appearances'] as List? ??
          [
            {
              'id': selected,
              'name': result['display_name'] ?? selected,
              'gender': result['gender'] ?? 'unspecified',
              'voice': result['voice'],
            },
          ];
      widget.agentPresentation?.value = {
        ...?widget.agentPresentation?.value,
        for (final appearance in appearances)
          appearance['id'] as String: {
            'name': appearance['name'],
            'gender': appearance['gender'] ?? 'unspecified',
            'voice': appearance['voice'],
            'text': appearance['id'] == selected ? (last?['text'] ?? '') : '',
            'at': appearance['id'] == selected ? (last?['at'] ?? 0) : 0,
          },
      };
      final active = !{
        'disabled',
        'paused',
        'offline',
        'error',
      }.contains(result['state']);
      widget.onlineAgents?.value = active ? {result['selected'] as String} : {};
      await voice?.autoJoinAgentRoom(room);
    } catch (_) {
      if (mounted && room == widget.room) {
        setState(() => liveAgent = null);
        widget.onlineAgents?.value = {};
        resetAgentSpeech();
      }
    } finally {
      liveAgentBusy = false;
    }
  }

  void _voiceChanged() {
    final state = voice?.value ?? const VoiceState();
    widget.speaking?.value = state.speaking;
    widget.audioLevels?.value = state.audioLevels;
    final faces = widget.faces;
    if (faces != null) faces.value = cameraFaces(state, faces.value);
  }

  Future<void> disconnect() async {
    if (disconnecting) return;
    disconnecting = true;
    liveAgent = null;
    widget.audioLevels?.value = {};
    widget.onlineAgents?.value = {};
    widget.agentPresentation?.value = {};
    agentAppearances = {};
    appearancesAt = DateTime(2000);
    timer?.cancel();
    presenceTimer?.cancel();
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
      presenceTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => refreshPresence(),
      );
      setState(() => status = 'Send failed; message kept in draft');
      return;
    }
    try {
      await taskDelivery?.waitForDrain();
      await chatDelivery?.waitForDrain();
    } catch (_) {}
    while ((busy || presenceBusy) && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!mounted) return;
    final closing = voice;
    voice = null;
    await closing?.leave();
    closing?.dispose();
    widget.speaking?.value = const {};
    widget.faces?.value = const {};
    try {
      await realtime?.request(
        'DELETE',
        '/v1/presence/${Uri.encodeComponent(session)}',
      );
    } catch (_) {
      /* expiry handles offline disconnects */
    }
    if (!mounted) return;
    setState(() {
      identity = null;
      realtime = null;
      presenceAvailable = false;
      published = null;
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
    movementTimer = Timer(const Duration(milliseconds: 120), refreshPresence);
  }

  @override
  void initState() {
    super.initState();
    widget.position.addListener(positionChanged);
    auth.addListener(_authChanged);
    auth.restore();
  }

  @override
  void didUpdateWidget(covariant Collaboration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) {
      oldWidget.position.removeListener(positionChanged);
      widget.position.addListener(positionChanged);
    }
    if (oldWidget.room != widget.room && identity != null) {
      messages = [];
      liveAgent = null;
      liveAgentAt = DateTime(2000);
      widget.onlineAgents?.value = {};
      resetAgentSpeech();
      refresh();
      refreshPresence();
      voice?.follow(widget.room);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    presenceTimer?.cancel();
    movementTimer?.cancel();
    voice?.dispose();
    widget.position.removeListener(positionChanged);
    auth.removeListener(_authChanged);
    auth.dispose();
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
              identity == null
                  ? (auth.active ? 'Chat · $status' : 'Sign in')
                  : 'Chat · $status',
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
          if (identity != null || auth.signedIn)
            IconButton(
              tooltip: auth.signedIn ? 'Sign out' : 'Disconnect',
              onPressed: signOut,
              icon: const Icon(Icons.logout, size: 18),
            ),
        ],
      ),
      if (auth.signedIn)
        Text(
          '${auth.account!.name} · ${auth.account!.username}',
          style: const TextStyle(fontSize: 11, color: Colors.black54),
          overflow: TextOverflow.ellipsis,
        ),
      if (identity == null && auth.signedIn)
        Row(
          children: [
            TextButton(
              onPressed: connecting ? null : connect,
              child: const Text('Retry'),
            ),
            Expanded(child: Text(status, style: const TextStyle(fontSize: 11))),
          ],
        )
      else if (identity == null) ...[
        SignInPanel(
          auth: auth,
          token: token,
          status: status,
          defaultCompany: widget.company,
          onDeviceToken: () {
            final value = token.text.trim();
            if (value.isNotEmpty) auth.useDeviceToken(value);
          },
        ),
        const Text(
          'Local node only · voice needs a connected node',
          style: TextStyle(fontSize: 11, color: Colors.black54),
        ),
      ] else ...[
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
        if (voice != null)
          VoicePanel(
            controller: voice!,
            room: widget.room,
            roomName:
                widget.rooms
                        .where((r) => r['id'] == widget.room)
                        .firstOrNull?['name']
                    as String? ??
                widget.room,
            names: {
              for (final a in widget.actors)
                a['id'] as String: a['name'] as String,
            },
          ),
        if (liveAgent != null && voice != null)
          LiveAgentPanel(
            data: liveAgent!,
            controller: voice!,
            request: request,
            onChanged: () {
              liveAgentAt = DateTime(2000);
              return refreshLiveAgent();
            },
          ),
        Text(
          presenceAvailable
              ? '$online visible session(s)'
              : 'Presence unavailable · text chat still works',
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
