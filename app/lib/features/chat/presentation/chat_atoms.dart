import 'package:flutter/material.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_tokens.dart';

/// 28 px ghost icon button (radius 8): the toolbar button of the design.
class GhostIconButton extends StatelessWidget {
  const GhostIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.size = NxSize.ctrl,
    this.color,
  });
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
      iconSize: NxSize.icon,
      style: IconButton.styleFrom(
        fixedSize: Size.square(size),
        minimumSize: Size.square(size),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        foregroundColor: color ?? nx.ink2,
        disabledForegroundColor: nx.ink3,
        hoverColor: nx.fill,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(NexusTokens.rCtrl),
        ),
      ),
    );
  }
}

/// Square avatar tinted by a stable hue. Decorative: the name sits beside it.
class NexusAvatar extends StatelessWidget {
  const NexusAvatar({
    super.key,
    required this.name,
    this.size = NxSize.avatar,
    this.radius = NxSize.avatarRadius,
    this.fontSize = NexusTokens.t12,
    this.face = false,
  });
  final String name;
  final double size, radius, fontSize;

  /// A face in a stack: round, with a surface ring.
  final bool face;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    final initial = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // A face overlaps its neighbour, so its tint sits on a solid ground.
          color: face
              ? Color.alphaBlend(
                  nx.avatarBackground(name, face: true),
                  nx.surface,
                )
              : nx.avatarBackground(name),
          shape: face ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: face ? null : BorderRadius.circular(radius),
          border: face
              ? Border.all(color: nx.surface, width: NxSize.faceBorder)
              : null,
        ),
        child: Text(
          initial,
          style: nx.text(
            fontSize,
            weight: NexusTokens.w640,
            color: nx.hueFor(name),
            height: 1,
          ),
        ),
      ),
    );
  }
}

/// Up to [NxSize.faceLimit] overlapping faces, then "+n".
class FaceStack extends StatelessWidget {
  const FaceStack({super.key, required this.names});
  final List<String> names;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    final shown = names.take(NxSize.faceLimit).toList();
    final more = names.length - shown.length;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, name) in shown.indexed)
          Align(
            alignment: Alignment.centerRight,
            heightFactor: 1,
            widthFactor: i == 0 ? 1 : NxSize.faceStep,
            child: NexusAvatar(
              name: name,
              size: NxSize.avatarFace,
              fontSize: NexusTokens.t10,
              face: true,
            ),
          ),
        if (more > 0)
          Padding(
            padding: const EdgeInsets.only(left: NxSpace.s4),
            child: Text(
              '+$more',
              style: nx.text(NexusTokens.t115, color: nx.ink3),
            ),
          ),
      ],
    );
  }
}

/// Unread / mention count pill.
class CountPill extends StatelessWidget {
  const CountPill({
    super.key,
    required this.label,
    required this.background,
    required this.foreground,
  });
  final String label;
  final Color background, foreground;
  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: NxSize.pillMin),
    height: NxSize.pill,
    padding: const EdgeInsets.symmetric(horizontal: NxSize.pillPad),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(NxSize.pillRadius),
    ),
    child: Text(
      label,
      style: context.nx.text(
        NexusTokens.t11,
        weight: NexusTokens.w600,
        color: foreground,
        height: 1,
      ),
    ),
  );
}

/// A bordered field that shows the accent ring while a child has focus.
class FocusFrame extends StatefulWidget {
  const FocusFrame({
    super.key,
    required this.child,
    this.radius = NexusTokens.rCtrl,
    this.resting,
  });
  final Widget child;
  final double radius;

  /// Border colour at rest; defaults to the quiet line.
  final Color? resting;
  @override
  State<FocusFrame> createState() => _FocusFrameState();
}

class _FocusFrameState extends State<FocusFrame> {
  bool focused = false;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (value) => setState(() => focused = value),
      child: AnimatedContainer(
        duration: NxMotion.fast,
        decoration: BoxDecoration(
          color: nx.surface3,
          borderRadius: BorderRadius.circular(widget.radius),
          border: Border.all(
            color: focused ? nx.accent : widget.resting ?? nx.line,
          ),
          boxShadow: focused
              ? [
                  BoxShadow(
                    color: nx.focusRing(),
                    spreadRadius: NxSize.focusRing,
                  ),
                ]
              : null,
        ),
        child: widget.child,
      ),
    );
  }
}

/// A banner on the failure tint: connection lost, load failed.
class ChatBanner extends StatelessWidget {
  const ChatBanner({super.key, required this.message, this.action});
  final String message;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Container(
      width: double.infinity,
      color: nx.failTint(),
      padding: const EdgeInsets.symmetric(
        horizontal: NxSpace.s16,
        vertical: NxSpace.s6,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: nx.text(
                NexusTokens.t125,
                weight: NexusTokens.w560,
                color: nx.now,
              ),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// Centred quiet message, optionally with a spinner or an action below.
class ChatNote extends StatelessWidget {
  const ChatNote(this.message, {super.key, this.spinner = false, this.action});
  final String message;
  final bool spinner;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(NxSpace.s16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (spinner) ...[
              const ChatSpinner(),
              const SizedBox(height: NxSpace.s12),
            ],
            Text(
              message,
              textAlign: TextAlign.center,
              style: nx.text(NexusTokens.t135, color: nx.ink2),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}

class ChatSpinner extends StatelessWidget {
  const ChatSpinner({super.key});
  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: NxSize.spinnerBox,
    child: CircularProgressIndicator(strokeWidth: NxSize.spinner),
  );
}

/// A tappable with a hairline border. The border and fill sit outside the
/// tap target (inset by [NxSpace.s2]) so the target's own rectangle holds
/// only its label: edge pixels would otherwise be read as text colour.
class BorderedTap extends StatelessWidget {
  const BorderedTap({
    super.key,
    required this.onTap,
    required this.child,
    this.radius = NexusTokens.rCtrl,
    this.background,
    this.borderColor,
    this.shadow,
    this.padding = EdgeInsets.zero,
  });
  final VoidCallback? onTap;
  final Widget child;
  final double radius;
  final Color? background, borderColor;
  final List<BoxShadow>? shadow;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        border: Border.all(color: borderColor ?? nx.line),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: shadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(NxSpace.s2),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius - NxSpace.s2),
          hoverColor: nx.ghostHover(),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}
