import 'package:flutter/material.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_tokens.dart';
import '../domain/chat_client.dart';
import 'chat_atoms.dart';

/// "All", "Unreads n", "Mentions n". The count is a RichText on purpose: it is
/// part of the chip's look, not a second label a screen reader should read.
class FilterChipButton extends StatelessWidget {
  const FilterChipButton({
    super.key,
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Semantics(
      selected: selected,
      button: true,
      child: BorderedTap(
        onTap: onTap,
        radius: NexusTokens.rPill,
        background: selected ? nx.surface : null,
        borderColor: selected ? nx.line : Colors.transparent,
        shadow: selected
            ? [
                BoxShadow(
                  color: nx.shadow,
                  blurRadius: NxSpace.s2,
                  offset: const Offset(0, NxSpace.s2),
                ),
              ]
            : null,
        padding: const EdgeInsets.symmetric(
          horizontal: NxSize.chipPad - NxSpace.s2,
          vertical: NxSize.tapPadV,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: nx.text(
                NexusTokens.t125,
                weight: NexusTokens.w560,
                color: selected ? nx.ink : nx.ink2,
                height: 1,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: NxSpace.s6),
              RichText(
                text: TextSpan(
                  text: '$count',
                  style: nx.text(
                    NexusTokens.t125,
                    weight: NexusTokens.w600,
                    color: nx.accent,
                    height: 1,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class GroupLabel extends StatelessWidget {
  const GroupLabel({super.key, required this.label, this.action});
  final String label;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NxSpace.s8,
        NxSize.groupTop,
        NxSpace.s4,
        NxSpace.s4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: nx.text(
                NexusTokens.t12,
                weight: NexusTokens.w580,
                color: nx.ink3,
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// A 30 px conversation row: channel (hash or lock) or direct message.
class ChannelRow extends StatelessWidget {
  const ChannelRow({
    super.key,
    required this.room,
    required this.selected,
    required this.onTap,
  });
  final ChatRoom room;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    final unread = room.unread > 0;
    final color = selected
        ? nx.accentInk
        : unread
        ? nx.ink
        : nx.ink2;
    final radius = BorderRadius.circular(NexusTokens.rSm);
    return SizedBox(
      height: NxSize.row,
      child: Semantics(
        selected: selected,
        child: Material(
          color: selected ? nx.selectedRow() : Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            hoverColor: nx.ghostHover(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: NxSpace.s8),
              child: Row(
                children: [
                  SizedBox(
                    width: NxSize.avatarSm,
                    height: NxSize.avatarSm,
                    child: Center(
                      child: room.direct
                          ? NexusAvatar(
                              name: room.name,
                              size: NxSize.avatarSm,
                              radius: NxSize.avatarSmRadius,
                              fontSize: NexusTokens.t10,
                            )
                          : Icon(
                              room.restricted ? Icons.lock_outline : Icons.tag,
                              size: NxSize.icon,
                              color: selected ? nx.accentInk : nx.ink3,
                            ),
                    ),
                  ),
                  const SizedBox(width: NxSpace.s8),
                  Expanded(
                    child: Text(
                      room.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: nx.text(
                        NexusTokens.t13,
                        weight: selected || unread
                            ? NexusTokens.w600
                            : NexusTokens.w500,
                        color: color,
                      ),
                    ),
                  ),
                  if (unread) ...[
                    const SizedBox(width: NxSpace.s6),
                    CountPill(
                      label: '${room.unread}',
                      background: nx.accent,
                      foreground: nx.onAccent,
                    ),
                  ],
                  if (room.mentions > 0) ...[
                    const SizedBox(width: NxSpace.s4),
                    CountPill(
                      label: '@${room.mentions}',
                      background: nx.badge,
                      foreground: nx.onBadge,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
