import 'package:flutter/material.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_tokens.dart';
import '../application/chat_controller.dart';
import '../domain/chat_client.dart';
import 'chat_atoms.dart';
import 'chat_attachments.dart';
import 'chat_format.dart';
import 'chat_message_parts.dart';
import 'chat_message_toolbar.dart';

export 'chat_attachments.dart' show AttachmentPreview;

class ChatMessageTile extends StatefulWidget {
  const ChatMessageTile({
    super.key,
    required this.message,
    required this.controller,
    this.thread,
    this.previous,
    this.gutter = NxSpace.s20,
  });
  final ChatMessage message;
  final ChatController controller;
  final String? thread;

  /// The message just above this one, when it can share an avatar.
  final ChatMessage? previous;
  final double gutter;
  @override
  State<ChatMessageTile> createState() => _ChatMessageTileState();
}

class _ChatMessageTileState extends State<ChatMessageTile> {
  bool hovered = false, focused = false, menuOpen = false;

  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    final m = widget.message;
    final controller = widget.controller;
    final grouped = continuesGroup(m, widget.previous);
    final active = hovered || focused || menuOpen;
    final pending = controller.pending
        .where((p) => p.transaction == m.transactionId)
        .firstOrNull;
    final replyTo = m.replyTo == null
        ? null
        : controller.client
                  .messages(m.roomId)
                  .where((e) => e.id == m.replyTo)
                  .firstOrNull
                  ?.sender ??
              'a message';
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (value) => setState(() => focused = value),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                Container(
                  color: active ? nx.messageHover() : null,
                  padding: EdgeInsets.fromLTRB(
                    widget.gutter,
                    grouped ? 0 : NxSpace.s6,
                    widget.gutter,
                    NxSpace.s6,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: NxSize.avatar,
                        child: grouped
                            ? _Stamp(time: m.time, show: active)
                            : NexusAvatar(name: m.sender),
                      ),
                      const SizedBox(width: NxSpace.s10),
                      Expanded(
                        child: _content(
                          context,
                          nx,
                          m,
                          pending,
                          grouped,
                          replyTo,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!m.deleted && m.delivery == Delivery.sent)
                  MessageToolbar(
                    message: m,
                    controller: controller,
                    thread: widget.thread,
                    visible: active,
                    gutter: widget.gutter,
                    onMenuOpen: () => setState(() => menuOpen = true),
                    onMenuClosed: () => setState(() => menuOpen = false),
                  ),
              ],
            ),
            if (m.readers.isNotEmpty)
              SeenRow(readers: m.readers, gutter: widget.gutter),
          ],
        ),
      ),
    );
  }

  Widget _flags(NexusTokens nx, ChatMessage m) => Text.rich(
    TextSpan(
      children: [
        if (m.edited) const TextSpan(text: ' · edited'),
        if (m.delivery == Delivery.sending) const TextSpan(text: ' · sending'),
      ],
    ),
    style: nx.text(NexusTokens.t12, color: nx.ink3),
  );

  Widget _content(
    BuildContext context,
    NexusTokens nx,
    ChatMessage m,
    PendingMessage? pending,
    bool grouped,
    String? replyTo,
  ) {
    final controller = widget.controller;
    final hasFlags = m.edited || m.delivery == Delivery.sending;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!grouped)
          Row(
            children: [
              Flexible(
                child: Text(
                  m.sender,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: nx.text(NexusTokens.t135, weight: NexusTokens.w600),
                ),
              ),
              const SizedBox(width: NxSpace.s6),
              Text(
                clock(m.time),
                style: nx.text(NexusTokens.t12, color: nx.ink3, tabular: true),
              ),
              if (hasFlags) _flags(nx, m),
            ],
          ),
        if (replyTo != null) ReplyNote(sender: replyTo),
        if (m.deleted)
          const DeletedNote()
        else if (m.attachment != null) ...[
          if (m.image) AttachmentPreview(message: m, controller: controller),
          FileCard(message: m, controller: controller),
        ] else
          MessageBody(message: m, controller: controller),
        if (grouped && hasFlags) _flags(nx, m),
        if (pending?.bytes != null && pending!.delivery == Delivery.sending)
          Padding(
            padding: const EdgeInsets.only(top: NxSpace.s6),
            child: LinearProgressIndicator(
              value: pending.progress,
              minHeight: NxSize.progress,
            ),
          ),
        if (m.delivery == Delivery.failed && pending != null)
          FailedRow(message: m, onRetry: () => controller.retry(pending)),
        if (!m.deleted && m.reactions.isNotEmpty)
          ReactionRow(message: m, controller: controller),
        if (!m.deleted && widget.thread == null)
          ThreadLink(message: m, controller: controller),
      ],
    );
  }
}

/// The time shown in the avatar column of a grouped follow-up, on hover.
class _Stamp extends StatelessWidget {
  const _Stamp({required this.time, required this.show});
  final DateTime time;
  final bool show;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Padding(
      padding: const EdgeInsets.only(top: NxSpace.s3),
      child: show
          ? Text(
              clock(time),
              textAlign: TextAlign.right,
              style: nx.text(NexusTokens.t11, color: nx.ink3, tabular: true),
            )
          : const SizedBox.shrink(),
    );
  }
}
