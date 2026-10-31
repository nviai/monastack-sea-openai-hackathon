import 'package:flutter/material.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_tokens.dart';
import '../application/chat_controller.dart';
import 'chat_atoms.dart';
import 'chat_format.dart';
import 'chat_message_tile.dart';

class ChatTimeline extends StatefulWidget {
  const ChatTimeline({
    super.key,
    required this.controller,
    required this.room,
    this.thread,
    this.gutter = NxSpace.s20,
  });
  final ChatController controller;
  final String room;
  final String? thread;

  /// Horizontal padding shared with the composer below.
  final double gutter;
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
        scroll.position.extentAfter < NxSize.pagingExtent &&
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
      return const Center(child: ChatSpinner());
    }
    if (messages.isEmpty) {
      return const ChatNote('No messages yet. Start the conversation.');
    }
    final now = DateTime.now();
    return ListView.builder(
      key: ValueKey('timeline-${widget.thread ?? widget.room}'),
      controller: scroll,
      reverse: true,
      padding: const EdgeInsets.symmetric(vertical: NxSpace.s6),
      itemCount: messages.length + 1,
      itemBuilder: (context, index) {
        if (index == messages.length) return _older();
        final message = messages[index];
        final older = index + 1 < messages.length ? messages[index + 1] : null;
        final newDay = older == null || !sameDay(older.time, message.time);
        final isRoot = widget.thread != null && message.id == widget.thread;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (newDay)
              LabelRule(
                label: dayLabel(message.time, now),
                gutter: widget.gutter,
              ),
            ChatMessageTile(
              key: ValueKey(message.id),
              message: message,
              controller: widget.controller,
              thread: widget.thread,
              previous: newDay ? null : older,
              gutter: widget.gutter,
            ),
            if (isRoot && messages.length > 1)
              LabelRule(
                label: repliesLabel(messages.length - 1),
                gutter: widget.gutter,
                leading: false,
              ),
          ],
        );
      },
    );
  }

  Widget _older() {
    final controller = widget.controller;
    final nx = context.nx;
    if (controller.loadingRooms.contains(widget.room)) {
      return const Padding(
        padding: EdgeInsets.all(NxSpace.s16),
        child: Center(child: ChatSpinner()),
      );
    }
    if (!controller.client.hasOlder(widget.room)) {
      return const SizedBox(height: NxSpace.s12);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: NxSpace.s6),
      child: Center(
        child: BorderedTap(
          onTap: () => controller.older(widget.room),
          radius: NexusTokens.rPill,
          background: nx.surface2,
          padding: const EdgeInsets.symmetric(
            horizontal: NxSpace.s10,
            vertical: NxSize.tapPadV,
          ),
          child: Text(
            'Load older messages',
            style: nx.text(
              NexusTokens.t12,
              weight: NexusTokens.w560,
              color: nx.ink2,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

/// A labelled hairline: "Today" (rules both sides) or "3 replies" (rule after).
class LabelRule extends StatelessWidget {
  const LabelRule({
    super.key,
    required this.label,
    required this.gutter,
    this.leading = true,
  });
  final String label;
  final double gutter;
  final bool leading;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    final rule = Expanded(
      child: Container(height: NxSize.hairline, color: nx.line),
    );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: gutter, vertical: NxSpace.s8),
      child: Row(
        children: [
          if (leading) ...[rule, const SizedBox(width: NxSpace.s10)],
          Text(
            label,
            style: nx.text(
              NexusTokens.t12,
              weight: NexusTokens.w560,
              color: nx.ink3,
            ),
          ),
          const SizedBox(width: NxSpace.s10),
          rule,
        ],
      ),
    );
  }
}
