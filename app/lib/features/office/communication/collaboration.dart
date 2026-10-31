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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:monastack/features/chat/application/chat_controller.dart';
import 'package:monastack/features/chat/application/chat_notifications.dart';
import 'package:monastack/features/chat/data/matrix_chat_client.dart';
import 'package:monastack/features/chat/data/matrix_session.dart';
import 'package:monastack/features/chat/presentation/chat_dialog.dart';
import 'package:monastack/features/chat/presentation/legacy_outbox.dart';
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

part 'collaboration_session.dart';
part 'collaboration_connection.dart';

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

class CollaborationState extends _CollaborationConnection {
  Future<void> openWorkspaceTools() async {
    if (identity == null) return;
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: chatController ?? queueNotifier,
        builder: (context, _) => WorkspaceTools(
          account: auth.signedIn,
          admin: auth.account?.admin ?? false,
          chatUnread: chatController?.unread ?? 0,
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'chat') {
      openChat();
      return;
    }
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

  void openChat({bool currentRoom = false}) {
    final controller = chatController;
    final matrix = chatClient;
    if (controller == null || matrix == null) return;
    if (currentRoom) {
      final target = matrix.rooms
          .where((r) => r.officeRoom == widget.room)
          .firstOrNull;
      if (target != null) unawaited(controller.select(target.id));
    }
    showDialog<void>(
      context: context,
      builder: (_) => ProviderScope(
        overrides: [
          chatClientProvider.overrideWithValue(matrix),
          chatControllerProvider.overrideWithValue(controller),
        ],
        child: ChatDialog(
          currentRoom: () => widget.room,
          enableNotifications: chatNotifications?.enable,
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              identity == null
                  ? (auth.active ? 'Office · $status' : 'Sign in')
                  : 'Office · $status',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
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
        if (queuedChat.isNotEmpty)
          TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => LegacyOutbox(entries: queuedChat),
            ),
            child: Text('Earlier messages not sent: ${queuedChat.length}'),
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
        ListenableBuilder(
          listenable: chatController ?? queueNotifier,
          builder: (context, _) => TextButton.icon(
            onPressed: () => openChat(currentRoom: true),
            icon: Badge(
              isLabelVisible: (chatController?.unread ?? 0) > 0,
              label: Text('${chatController?.unread ?? 0}'),
              child: const Icon(Icons.forum_outlined),
            ),
            label: const Text("Open this room's chat"),
          ),
        ),
      ],
    ],
  );
}
