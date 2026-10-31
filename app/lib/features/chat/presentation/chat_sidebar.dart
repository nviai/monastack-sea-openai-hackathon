import 'package:flutter/material.dart';

import '../application/chat_controller.dart';
import 'person_picker.dart';

class ChatSidebar extends StatelessWidget {
  const ChatSidebar({
    super.key,
    required this.controller,
    required this.currentRoom,
    this.searchFocus,
  });
  final ChatController controller;
  final String currentRoom;
  final FocusNode? searchFocus;
  @override
  Widget build(BuildContext context) {
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
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              key: const Key('chat-search'),
              focusNode: searchFocus,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Search all conversations',
                isDense: true,
              ),
              onSubmitted: (value) => controller.search(value),
            ),
          ),
          for (final value in ChatFilter.values)
            ListTile(
              dense: true,
              selected: controller.filter == value,
              leading: Icon(switch (value) {
                ChatFilter.all => Icons.forum_outlined,
                ChatFilter.unreads => Icons.mark_chat_unread_outlined,
                ChatFilter.mentions => Icons.alternate_email,
              }),
              title: Text(switch (value) {
                ChatFilter.all => 'All conversations',
                ChatFilter.unreads => 'Unreads',
                ChatFilter.mentions => 'Mentions',
              }),
              onTap: () => controller.setFilter(value),
            ),
          TextButton.icon(
            onPressed: () {
              final room = client.rooms
                  .where((r) => r.officeRoom == currentRoom)
                  .firstOrNull;
              if (room != null) controller.select(room.id);
            },
            icon: const Icon(Icons.near_me_outlined, size: 16),
            label: const Text("Open this room's chat"),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              children: [
                for (final direct in [false, true]) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            direct ? 'Direct messages' : 'Channels',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (direct)
                          IconButton(
                            tooltip: 'New direct message',
                            onPressed: () =>
                                showPersonPicker(context, controller),
                            icon: const Icon(Icons.add, size: 18),
                          ),
                      ],
                    ),
                  ),
                  if (!rooms.any((r) => r.direct == direct))
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No conversations'),
                    ),
                  for (final room in rooms.where((r) => r.direct == direct))
                    ListTile(
                      key: ValueKey('channel-${room.id}'),
                      dense: true,
                      selected: controller.selected == room.id,
                      leading: Icon(
                        direct
                            ? Icons.people_outline
                            : room.restricted
                            ? Icons.lock_outline
                            : Icons.tag,
                        size: 18,
                      ),
                      title: Text(
                        room.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: room.topic.isEmpty
                          ? null
                          : Text(
                              room.topic,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: room.unread > 0 || room.mentions > 0
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (room.unread > 0)
                                  Badge(label: Text('${room.unread}')),
                                if (room.unread > 0 && room.mentions > 0)
                                  const SizedBox(width: 5),
                                if (room.mentions > 0)
                                  Badge(label: Text('@${room.mentions}')),
                              ],
                            )
                          : null,
                      onTap: () => controller.select(room.id),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
