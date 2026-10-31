import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_tokens.dart';
import '../application/chat_controller.dart';
import '../domain/chat_client.dart';
import 'chat_atoms.dart';

const _quickReaction = '👍';

/// The hover toolbar: react, reply, thread, more. Floats at the tile's top
/// right; it takes no pointer events while hidden.
class MessageToolbar extends StatelessWidget {
  const MessageToolbar({
    super.key,
    required this.message,
    required this.controller,
    required this.thread,
    required this.visible,
    required this.onMenuOpen,
    required this.onMenuClosed,
    required this.gutter,
  });
  final ChatMessage message;
  final ChatController controller;
  final String? thread;
  final bool visible;
  final VoidCallback onMenuOpen, onMenuClosed;
  final double gutter;

  void _select(String value) {
    final m = message;
    switch (value) {
      case 'copy':
        Clipboard.setData(ClipboardData(text: m.body));
      case 'reply':
        controller.mode(m.roomId, m, root: thread);
      case 'thread':
        controller.openThread(m);
      case 'react':
        controller.act(
          () => controller.client.react(m.roomId, m.id, _quickReaction),
        );
      case 'edit':
        controller.mode(m.roomId, m, edit: true, root: thread);
      case 'delete':
        controller.act(() => controller.client.redact(m.roomId, m.id));
    }
    onMenuClosed();
  }

  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    final m = message;
    return Positioned(
      top: NxSize.toolbarTop,
      right: gutter,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: NxMotion.fast,
          child: Container(
            padding: const EdgeInsets.all(NxSpace.s2),
            decoration: BoxDecoration(
              color: nx.elevated,
              border: Border.all(color: nx.line),
              borderRadius: BorderRadius.circular(NexusTokens.rCtrl),
              boxShadow: [
                BoxShadow(
                  color: nx.shadow,
                  blurRadius: NxSpace.s4,
                  offset: const Offset(0, NxSpace.s2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GhostIconButton(
                  tooltip: 'React with $_quickReaction',
                  size: NxSize.toolbarBtn,
                  icon: Icons.add_reaction_outlined,
                  onPressed: () => _select('react'),
                ),
                GhostIconButton(
                  tooltip: 'Reply',
                  size: NxSize.toolbarBtn,
                  icon: Icons.reply,
                  onPressed: () => _select('reply'),
                ),
                if (thread == null)
                  GhostIconButton(
                    tooltip: 'Reply in thread',
                    size: NxSize.toolbarBtn,
                    icon: Icons.forum_outlined,
                    onPressed: () => _select('thread'),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'Message actions',
                  padding: EdgeInsets.zero,
                  iconSize: NxSize.icon,
                  icon: Icon(Icons.more_horiz, color: nx.ink2),
                  style: IconButton.styleFrom(
                    fixedSize: const Size.square(NxSize.toolbarBtn),
                    minimumSize: const Size.square(NxSize.toolbarBtn),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    hoverColor: nx.fill,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(NexusTokens.rCtrl),
                    ),
                  ),
                  onOpened: onMenuOpen,
                  onCanceled: onMenuClosed,
                  onSelected: _select,
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'copy',
                      child: Text('Copy text'),
                    ),
                    const PopupMenuItem(value: 'reply', child: Text('Reply')),
                    const PopupMenuItem(
                      value: 'thread',
                      child: Text('Open thread'),
                    ),
                    const PopupMenuItem(
                      value: 'react',
                      child: Text('React $_quickReaction'),
                    ),
                    if (m.own && m.attachment == null)
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('Edit message'),
                      ),
                    if (m.canDelete)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete message'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
