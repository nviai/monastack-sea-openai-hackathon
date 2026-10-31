import 'package:flutter/material.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_tokens.dart';
import '../application/chat_controller.dart';
import '../domain/chat_client.dart';
import 'chat_atoms.dart';
import 'chat_composer.dart';
import 'chat_message_tile.dart';
import 'chat_timeline.dart';
import 'chat_title_bar.dart';

/// Thread, room details, members or search results beside (or over) the
/// main pane. Its header is the same 52 px as the main pane's.
class ChatSidePane extends StatelessWidget {
  const ChatSidePane({
    super.key,
    required this.controller,
    this.inline = false,
  });
  final ChatController controller;

  /// Drawn as a column beside the main pane: a hairline on its left edge.
  final bool inline;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    final room = controller.room;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: nx.surface,
        border: inline ? Border(left: BorderSide(color: nx.line)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PaneHeader(
            leftPad: NxSpace.s16,
            children: [
              Text(switch (controller.pane) {
                SidePane.thread => 'Thread',
                SidePane.details => 'Room details',
                SidePane.members => 'Members',
                SidePane.search => 'Search results',
                SidePane.none => '',
              }, style: nx.text(NexusTokens.t14, weight: NexusTokens.w640)),
              if (controller.pane == SidePane.thread && room != null) ...[
                const SizedBox(width: NxSpace.s10),
                Expanded(
                  child: Text(
                    '# ${room.name}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: nx.text(NexusTokens.t125, color: nx.ink3),
                  ),
                ),
              ] else
                const Spacer(),
              GhostIconButton(
                tooltip: 'Close side pane',
                onPressed: () => controller.side(SidePane.none),
                icon: Icons.close,
              ),
            ],
          ),
          Expanded(child: _body(context, nx, room)),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, NexusTokens nx, ChatRoom? room) =>
      switch (controller.pane) {
        SidePane.thread when room != null && controller.thread != null =>
          Column(
            children: [
              if (controller.threadState == PaneLoad.loading)
                const LinearProgressIndicator(minHeight: NxSize.progress),
              if (controller.threadState == PaneLoad.error)
                TextButton(
                  onPressed: controller.refreshThread,
                  child: const Text('Thread unavailable · Retry'),
                ),
              Expanded(
                child: ChatTimeline(
                  controller: controller,
                  room: room.id,
                  thread: controller.thread,
                  gutter: NxSpace.s16,
                ),
              ),
              ChatComposer(
                controller: controller,
                room: room.id,
                thread: controller.thread,
              ),
            ],
          ),
        SidePane.details when room != null => _Details(room: room),
        SidePane.members when room != null => ChatMembers(
          key: ValueKey(room.id),
          client: controller.client,
          room: room.id,
        ),
        SidePane.search => _Search(controller: controller),
        _ => const ChatNote('Choose a conversation.'),
      };
}

class _Details extends StatelessWidget {
  const _Details({required this.room});
  final ChatRoom room;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    final label = nx.text(
      NexusTokens.t12,
      weight: NexusTokens.w580,
      color: nx.ink3,
    );
    final body = nx.text(
      NexusTokens.t135,
      color: nx.ink2,
      height: NexusTokens.lhBody,
    );
    return ListView(
      padding: const EdgeInsets.all(NxSpace.s16),
      children: [
        Text(
          room.name,
          style: nx.text(NexusTokens.t15, weight: NexusTokens.w640),
        ),
        const SizedBox(height: NxSpace.s16),
        Text('Topic', style: label),
        const SizedBox(height: NxSpace.s4),
        Text(room.topic.isEmpty ? 'No topic set.' : room.topic, style: body),
        const SizedBox(height: NxSpace.s16),
        Text('Access', style: label),
        const SizedBox(height: NxSpace.s4),
        Text(
          room.restricted
              ? 'Restricted conversation. Membership is required.'
              : 'Open to authorized workspace members.',
          style: body,
        ),
        const SizedBox(height: NxSpace.s8),
        Text(
          room.restricted
              ? 'New members can read messages sent after joining.'
              : 'Members can read shared channel history.',
          style: body,
        ),
      ],
    );
  }
}

class _Search extends StatelessWidget {
  const _Search({required this.controller});
  final ChatController controller;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(NxSpace.s12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Full-history results for “${controller.searchTerm}”',
              style: nx.text(NexusTokens.t125, color: nx.ink2),
            ),
          ),
        ),
        if (controller.searching)
          const LinearProgressIndicator(minHeight: NxSize.progress),
        Expanded(
          child: controller.searchResults.isEmpty && !controller.searching
              ? const ChatNote('No matching messages.')
              : ListView(
                  children: [
                    for (final message in controller.searchResults)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: NxSpace.s8,
                            ),
                            child: TextButton(
                              onPressed: () =>
                                  controller.select(message.roomId),
                              child: Text(
                                controller.client.rooms
                                        .where((r) => r.id == message.roomId)
                                        .firstOrNull
                                        ?.name ??
                                    'Conversation',
                              ),
                            ),
                          ),
                          ChatMessageTile(
                            message: message,
                            controller: controller,
                            gutter: NxSpace.s16,
                          ),
                        ],
                      ),
                  ],
                ),
        ),
        if (controller.searchNext != null)
          TextButton(
            onPressed: controller.searching
                ? null
                : () => controller.search(controller.searchTerm, more: true),
            child: const Text('More results'),
          ),
      ],
    );
  }
}

class ChatMembers extends StatefulWidget {
  const ChatMembers({super.key, required this.client, required this.room});
  final ChatClient client;
  final String room;
  @override
  State<ChatMembers> createState() => _ChatMembersState();
}

class _ChatMembersState extends State<ChatMembers> {
  late Future<List<ChatPerson>> members = widget.client.members(widget.room);
  @override
  Widget build(BuildContext context) => FutureBuilder<List<ChatPerson>>(
    future: members,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Center(
          child: TextButton(
            onPressed: () => setState(() {
              members = widget.client.members(widget.room);
            }),
            child: const Text('Members unavailable · Retry'),
          ),
        );
      }
      if (!snapshot.hasData) return const Center(child: ChatSpinner());
      if (snapshot.data!.isEmpty) return const ChatNote('No members.');
      final nx = context.nx;
      return ListView(
        padding: const EdgeInsets.all(NxSpace.s10),
        children: [
          for (final member in snapshot.data!)
            SizedBox(
              height: NxSize.row,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: NxSpace.s8),
                child: Row(
                  children: [
                    NexusAvatar(
                      name: member.name,
                      size: NxSize.avatarSm,
                      radius: NxSize.avatarSmRadius,
                      fontSize: NexusTokens.t10,
                    ),
                    const SizedBox(width: NxSpace.s8),
                    Expanded(
                      child: Text(
                        member.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: nx.text(NexusTokens.t13, color: nx.ink),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}
