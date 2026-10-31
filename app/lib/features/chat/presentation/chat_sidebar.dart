import 'package:flutter/material.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_tokens.dart';
import '../application/chat_controller.dart';
import 'chat_atoms.dart';
import 'chat_here_card.dart';
import 'chat_sidebar_rows.dart';
import 'person_picker.dart';

class ChatSidebar extends StatelessWidget {
  const ChatSidebar({
    super.key,
    required this.controller,
    required this.currentRoom,
    this.searchFocus,
    this.divider = true,
  });
  final ChatController controller;
  final String currentRoom;
  final FocusNode? searchFocus;

  /// A hairline on the right edge when beside the main pane.
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    final client = controller.client;
    final rooms = client.rooms
        .where(
          (r) => switch (controller.filter) {
            ChatFilter.all => true,
            ChatFilter.unreads => r.unread > 0,
            ChatFilter.mentions => r.mentions > 0,
          },
        )
        .toList();
    final current = client.rooms
        .where((r) => r.officeRoom == currentRoom)
        .firstOrNull;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NxSpace.s10,
        vertical: NxSpace.s12,
      ),
      decoration: BoxDecoration(
        color: nx.surface2,
        border: divider ? Border(right: BorderSide(color: nx.line)) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SearchField(controller: controller, focus: searchFocus),
          Padding(
            padding: const EdgeInsets.only(
              top: NxSpace.s10,
              bottom: NxSpace.s4,
            ),
            child: Wrap(
              spacing: NxSpace.s4,
              runSpacing: NxSpace.s4,
              children: [
                for (final value in ChatFilter.values)
                  FilterChipButton(
                    label: switch (value) {
                      ChatFilter.all => 'All',
                      ChatFilter.unreads => 'Unreads',
                      ChatFilter.mentions => 'Mentions',
                    },
                    count: switch (value) {
                      ChatFilter.all => 0,
                      ChatFilter.unreads =>
                        client.rooms.where((r) => r.unread > 0).length,
                      ChatFilter.mentions =>
                        client.rooms.where((r) => r.mentions > 0).length,
                    },
                    selected: controller.filter == value,
                    onTap: () => controller.setFilter(value),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                for (final direct in [false, true]) ...[
                  GroupLabel(
                    label: direct ? 'Direct messages' : 'Channels',
                    action: direct
                        ? GhostIconButton(
                            tooltip: 'New direct message',
                            size: NxSize.ctrlSm,
                            onPressed: () =>
                                showPersonPicker(context, controller),
                            icon: Icons.add,
                          )
                        : null,
                  ),
                  if (!rooms.any((r) => r.direct == direct))
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: NxSpace.s8,
                        vertical: NxSpace.s6,
                      ),
                      child: Text(
                        'No conversations',
                        style: nx.text(NexusTokens.t125, color: nx.ink3),
                      ),
                    ),
                  for (final room in rooms.where((r) => r.direct == direct))
                    Padding(
                      padding: const EdgeInsets.only(bottom: NxSpace.s2),
                      child: ChannelRow(
                        key: ValueKey('channel-${room.id}'),
                        room: room,
                        selected: controller.selected == room.id,
                        onTap: () => controller.select(room.id),
                      ),
                    ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: NxSpace.s8),
            child: HereCard(
              roomName: current?.name ?? currentRoom,
              onOpen: current == null
                  ? null
                  : () => controller.select(current.id),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller, this.focus});
  final ChatController controller;
  final FocusNode? focus;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return SizedBox(
      height: NxSize.search,
      child: FocusFrame(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: NxSpace.s10),
          child: Row(
            children: [
              Icon(Icons.search, size: NxSize.icon, color: nx.ink3),
              const SizedBox(width: NxSpace.s8),
              Expanded(
                child: TextField(
                  key: const Key('chat-search'),
                  focusNode: focus,
                  maxLines: 1,
                  style: nx.text(NexusTokens.t135),
                  cursorColor: nx.accent,
                  decoration: InputDecoration.collapsed(
                    hintText: 'Search all conversations',
                    hintStyle: nx.text(NexusTokens.t135, color: nx.ink3),
                  ),
                  onSubmitted: controller.search,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
