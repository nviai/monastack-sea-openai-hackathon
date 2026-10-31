import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_tokens.dart';
import 'chat_atoms.dart';

/// "You're in `room` · Open chat": the dashed card at the sidebar bottom.
class HereCard extends StatelessWidget {
  const HereCard({super.key, required this.roomName, required this.onOpen});
  final String roomName;
  final VoidCallback? onOpen;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    final note = nx.text(NexusTokens.t125, color: nx.ink2);
    return CustomPaint(
      painter: _DashedBorder(color: nx.line2, radius: NxSize.hereRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NxSpace.s10,
          vertical: NxSpace.s8,
        ),
        child: Row(
          children: [
            Icon(Icons.place_outlined, size: NxSize.icon, color: nx.ink2),
            const SizedBox(width: NxSpace.s8),
            Expanded(
              child: Text.rich(
                TextSpan(
                  text: "You're in ",
                  style: note,
                  children: [
                    TextSpan(
                      text: roomName,
                      style: nx.text(
                        NexusTokens.t125,
                        weight: NexusTokens.w600,
                      ),
                    ),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: NxSpace.s8),
            _OpenButton(onOpen: onOpen),
          ],
        ),
      ),
    );
  }
}

class _OpenButton extends StatelessWidget {
  const _OpenButton({required this.onOpen});
  final VoidCallback? onOpen;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return BorderedTap(
      onTap: onOpen,
      radius: NxSize.hereButtonRadius,
      borderColor: nx.line2,
      padding: const EdgeInsets.symmetric(
        horizontal: NxSpace.s6,
        vertical: NxSize.tapPadV,
      ),
      child: Text(
        'Open chat',
        style: nx.text(
          NexusTokens.t12,
          weight: NexusTokens.w560,
          color: onOpen == null ? nx.ink3 : nx.accent,
          height: 1,
        ),
      ),
    );
  }
}

class _DashedBorder extends CustomPainter {
  const _DashedBorder({required this.color, required this.radius});
  final Color color;
  final double radius;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = NxSize.dashWidth;
    final outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
      );
    for (final PathMetric metric in outline.computeMetrics()) {
      for (
        var at = 0.0;
        at < metric.length;
        at += NxSize.dashLength + NxSize.dashGap
      ) {
        canvas.drawPath(metric.extractPath(at, at + NxSize.dashLength), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorder old) =>
      old.color != color || old.radius != radius;
}
