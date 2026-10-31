import 'package:flutter/material.dart';

import '../application/chat_controller.dart';
import 'chat_message_tile.dart';

class ChatTimeline extends StatefulWidget {
  const ChatTimeline({
    super.key,
    required this.controller,
    required this.room,
    this.thread,
  });
  final ChatController controller;
  final String room;
  final String? thread;
  @override
  State<ChatTimeline> createState() => _ChatTimelineState();
}

class _ChatTimelineState extends State<ChatTimeline> {
  final scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    scroll.addListener(page);
  }

  void page() {
    if (scroll.hasClients &&
        scroll.position.extentAfter < 100 &&
        widget.controller.client.hasOlder(widget.room)) {
      widget.controller.older(widget.room);
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.controller.timeline(
      widget.room,
      root: widget.thread,
    );
    if (widget.controller.loading && widget.thread == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (messages.isEmpty) {
      return const Center(
        child: Text('No messages yet. Start the conversation.'),
      );
    }
    return ListView.builder(
      key: ValueKey('timeline-${widget.thread ?? widget.room}'),
      controller: scroll,
      reverse: true,
      itemCount: messages.length + 1,
      itemBuilder: (context, index) {
        if (index == messages.length) {
          return Center(
            child: widget.controller.loadingRooms.contains(widget.room)
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(),
                  )
                : widget.controller.client.hasOlder(widget.room)
                ? TextButton(
                    onPressed: () => widget.controller.older(widget.room),
                    child: const Text('Load older messages'),
                  )
                : const SizedBox(height: 12),
          );
        }
        final message = messages[index];
        return ChatMessageTile(
          key: ValueKey(message.id),
          message: message,
          controller: widget.controller,
          thread: widget.thread,
        );
      },
    );
  }
}
