import 'package:flutter/material.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_tokens.dart';
import 'chat_atoms.dart';

/// The 44 px title bar on the chrome colour.
class ChatTitleBar extends StatelessWidget {
  const ChatTitleBar({
    super.key,
    required this.showMenu,
    required this.onMenu,
    required this.expanded,
    required this.onExpand,
    required this.onClose,
    this.onNotifications,
  });
  final bool showMenu, expanded;
  final VoidCallback onMenu, onExpand, onClose;
  final VoidCallback? onNotifications;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Container(
      height: NxSize.titleBar,
      padding: const EdgeInsets.only(left: NxSpace.s16, right: NxSpace.s12),
      decoration: BoxDecoration(
        color: nx.chrome,
        border: Border(bottom: BorderSide(color: nx.line)),
      ),
      child: Row(
        children: [
          if (showMenu) ...[
            GhostIconButton(
              tooltip: 'Conversations',
              onPressed: onMenu,
              icon: Icons.menu,
            ),
            const SizedBox(width: NxSpace.s8),
          ],
          Icon(Icons.forum_outlined, size: NxSize.icon, color: nx.ink),
          const SizedBox(width: NxSpace.s10),
          Expanded(
            child: Text(
              'Chat',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: nx.text(NexusTokens.t14, weight: NexusTokens.w640),
            ),
          ),
          if (onNotifications != null)
            GhostIconButton(
              tooltip: 'Enable desktop notifications',
              onPressed: onNotifications,
              icon: Icons.notifications_none,
            ),
          GhostIconButton(
            tooltip: expanded ? 'Restore dialog size' : 'Expand chat',
            onPressed: onExpand,
            icon: expanded ? Icons.close_fullscreen : Icons.open_in_full,
          ),
          GhostIconButton(
            tooltip: 'Close chat',
            onPressed: onClose,
            icon: Icons.close,
          ),
        ],
      ),
    );
  }
}

/// A pane header: 52 px high with a hairline below, equal in every pane.
class PaneHeader extends StatelessWidget {
  const PaneHeader({
    super.key,
    required this.children,
    this.leftPad = NxSpace.s20,
  });
  final List<Widget> children;
  final double leftPad;
  @override
  Widget build(BuildContext context) => Container(
    height: NxSize.header,
    padding: EdgeInsets.only(left: leftPad, right: NxSpace.s12),
    decoration: BoxDecoration(
      border: Border(bottom: BorderSide(color: context.nx.line)),
    ),
    child: Row(children: children),
  );
}
