import 'package:flutter/material.dart';

import '../application/chat_controller.dart';
import '../domain/chat_client.dart';
import 'chat_composer.dart';
import 'chat_timeline.dart';
import 'chat_message_tile.dart';

class ChatSidePane extends StatelessWidget {
  const ChatSidePane({super.key, required this.controller});
  final ChatController controller;
  @override
  Widget build(BuildContext context) {
    final room = controller.room;
    return Column(
      children: [
        ListTile(
          title: Text(switch (controller.pane) {
            SidePane.thread => 'Thread',
            SidePane.details => 'Room details',
            SidePane.members => 'Members',
            SidePane.search => 'Search results',
            SidePane.none => '',
          }, style: const TextStyle(fontWeight: FontWeight.w700)),
          trailing: IconButton(
            tooltip: 'Close side pane',
            onPressed: () => controller.side(SidePane.none),
            icon: const Icon(Icons.close),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: switch (controller.pane) {
            SidePane.thread when room != null && controller.thread != null =>
              Column(
                children: [
                  if (controller.threadState == PaneLoad.loading)
                    const LinearProgressIndicator(),
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
                    ),
                  ),
                  ChatComposer(
                    controller: controller,
                    room: room.id,
                    thread: controller.thread,
                  ),
                ],
              ),
            SidePane.details when room != null => Padding(
              padding: const EdgeInsets.all(16),
              child: ListView(
                children: [
                  Text(
                    room.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(room.topic.isEmpty ? 'No topic set.' : room.topic),
                  const SizedBox(height: 16),
                  Text(
                    room.restricted
                        ? 'Restricted conversation. Membership is required.'
                        : 'Open to authorized workspace members.',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    room.restricted
                        ? 'New members can read messages sent after joining.'
                        : 'Members can read shared channel history.',
                  ),
                ],
              ),
            ),
            SidePane.members when room != null => ChatMembers(
              key: ValueKey(room.id),
              client: controller.client,
              room: room.id,
            ),
            SidePane.search => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Full-history results for “${controller.searchTerm}”',
                  ),
                ),
                if (controller.searching) const LinearProgressIndicator(),
                Expanded(
                  child:
                      controller.searchResults.isEmpty && !controller.searching
                      ? const Center(child: Text('No matching messages.'))
                      : ListView(
                          children: [
                            for (final message in controller.searchResults)
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  TextButton(
                                    onPressed: () =>
                                        controller.select(message.roomId),
                                    child: Text(
                                      controller.client.rooms
                                              .where(
                                                (r) => r.id == message.roomId,
                                              )
                                              .firstOrNull
                                              ?.name ??
                                          'Conversation',
                                    ),
                                  ),
                                  ChatMessageTile(
                                    message: message,
                                    controller: controller,
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
                        : () => controller.search(
                            controller.searchTerm,
                            more: true,
                          ),
                    child: const Text('More results'),
                  ),
              ],
            ),
            _ => const Center(child: Text('Choose a conversation.')),
          },
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
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      if (snapshot.data!.isEmpty) {
        return const Center(child: Text('No members.'));
      }
      return ListView(
        children: [
          for (final member in snapshot.data!)
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(member.name),
            ),
        ],
      );
    },
  );
}
