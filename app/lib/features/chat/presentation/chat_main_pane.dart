import 'package:flutter/material.dart';

import '../application/chat_controller.dart';
import 'chat_timeline.dart';
import 'chat_composer.dart';
import 'legacy_history.dart';

class ChatMainPane extends StatelessWidget {
  const ChatMainPane({super.key, required this.controller});
  final ChatController controller;
  @override
  Widget build(BuildContext context) {
    final room = controller.room;
    if (room == null) {
      return const Center(child: Text('Choose a conversation to get started.'));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final heading = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    room.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 18,
                    ),
                  ),
                  Text(
                    '${room.restricted ? 'Restricted' : 'Open'}${room.topic.isEmpty ? '' : ' · ${room.topic}'}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              );
              final actions = Wrap(
                children: [
                  IconButton(
                    tooltip: 'Mark as read',
                    onPressed: () => controller.act(
                      () => controller.client.markRead(room.id),
                    ),
                    icon: const Icon(Icons.done_all),
                  ),
                  IconButton(
                    tooltip: 'Room details',
                    onPressed: () => controller.side(SidePane.details),
                    icon: const Icon(Icons.info_outline),
                  ),
                  IconButton(
                    tooltip: 'Members',
                    onPressed: () => controller.side(SidePane.members),
                    icon: const Icon(Icons.people_outline),
                  ),
                  IconButton(
                    tooltip: 'Earlier messages (before Matrix)',
                    onPressed: () async {
                      await controller.act(() async {
                        final scope = await controller.client.legacyScope(
                          room.id,
                        );
                        if (!context.mounted) return;
                        if (scope == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'No earlier conversation exists for these members.',
                              ),
                            ),
                          );
                          return;
                        }
                        await showDialog<void>(
                          context: context,
                          builder: (_) => LegacyHistory(
                            client: controller.client,
                            scope: scope,
                            room: room.id,
                          ),
                        );
                      });
                    },
                    icon: const Icon(Icons.history),
                  ),
                ],
              );
              return constraints.maxWidth > 540
                  ? Row(
                      children: [
                        Expanded(child: heading),
                        actions,
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [heading, actions],
                    );
            },
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ChatTimeline(controller: controller, room: room.id),
        ),
        if (controller.client.typing(room.id).isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${controller.client.typing(room.id).join(', ')} typing…',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ChatComposer(controller: controller, room: room.id),
      ],
    );
  }
}
