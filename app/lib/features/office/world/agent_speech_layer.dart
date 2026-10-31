import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:rive/rive.dart' as rive;

import 'world_game.dart';
import 'avatars.dart';

/// Screen-space bubbles track the same projected head position as avatar labels.
class AgentSpeechLayer extends StatefulWidget {
  const AgentSpeechLayer({
    super.key,
    required this.game,
    required this.presentation,
    required this.speaking,
    this.reduceMotion = false,
    this.audioLevels,
  });
  final WorldGame game;
  final ValueListenable<Map<String, dynamic>> presentation;
  final ValueListenable<Set<String>> speaking;
  final bool reduceMotion;
  final ValueListenable<Map<String, double>>? audioLevels;
  @override
  State<AgentSpeechLayer> createState() => _AgentSpeechLayerState();
}

class _AgentSpeechLayerState extends State<AgentSpeechLayer>
    with SingleTickerProviderStateMixin {
  late final Ticker ticker = createTicker((_) {
    if (mounted) setState(() {});
  });
  @override
  void initState() {
    super.initState();
    ticker.start();
  }

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final children = <Widget>[];
        for (final entry in widget.presentation.value.entries) {
          final head = widget.game.agentHeadPosition(entry.key);
          if (head == null) continue;
          final data = entry.value as Map;
          final talking = widget.speaking.value.contains(entry.key);
          final faceRect = widget.game.agentFaceRect(entry.key);
          final level = talking
              ? widget.audioLevels?.value[entry.key] ?? 0.0
              : 0.0;
          if (faceRect != null) {
            children.add(
              Positioned.fromRect(
                key: ValueKey('agent-face-${entry.key}'),
                rect: faceRect,
                child: AgentAvatarFace(
                  actor: entry.key,
                  gender: data['gender'] as String? ?? 'unspecified',
                  level: widget.reduceMotion ? 0 : level,
                  speaking: talking,
                ),
              ),
            );
          }
          final at = (data['at'] as num? ?? 0).toInt();
          final text = DateTime.now().millisecondsSinceEpoch ~/ 1000 - at <= 12
              ? data['text'] as String? ?? ''
              : '';
          if (!talking && text.isEmpty) continue;
          final width = constraints.maxWidth.clamp(0, 250).toDouble();
          final left = (head.dx - width / 2).clamp(
            0.0,
            (constraints.maxWidth - width).clamp(0.0, double.infinity),
          );
          children.add(
            Positioned(
              key: ValueKey('agent-bubble-${entry.key}'),
              left: left,
              bottom: (constraints.maxHeight - (faceRect?.top ?? head.dy) + 30)
                  .clamp(
                    12.0,
                    (constraints.maxHeight - 100).clamp(12.0, double.infinity),
                  ),
              width: width,
              child: Semantics(
                label: '${data['name']}: $text',
                liveRegion: true,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xfff5fff9),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xffb6d9c6)),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x22000000),
                        blurRadius: 10,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            text.isEmpty ? 'Speaking…' : text,
                            maxLines: 5,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xff22352e),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        return Stack(clipBehavior: Clip.hardEdge, children: children);
      },
    ),
  );
}

/// The mouth is a real Rive state machine, driven by LiveKit's received audio level.
/// This is amplitude-driven articulation, not phoneme recognition.
class AgentAvatarFace extends StatelessWidget {
  const AgentAvatarFace({
    super.key,
    required this.actor,
    required this.level,
    required this.speaking,
    this.gender = 'unspecified',
  });
  final String gender;
  final String actor;
  final double level;
  final bool speaking;
  @override
  Widget build(BuildContext context) {
    final style = AvatarStyle.of(actor);
    return Semantics(
      label: gender == 'female'
          ? 'Female agent avatar'
          : gender == 'male'
          ? 'Male agent avatar'
          : 'Agent avatar',
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: style.skin,
          border: Border.all(
            color: speaking ? const Color(0xff2f9e6f) : Colors.white,
            width: 2,
          ),
          boxShadow: const [BoxShadow(color: Color(0x26000000), blurRadius: 5)],
        ),
        child: ClipOval(
          child: LayoutBuilder(
            builder: (context, box) => Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(painter: _AgentHead(style, actor, gender)),
                ),
                Positioned(
                  left: box.maxWidth * .22,
                  top: box.maxHeight * .56,
                  width: box.maxWidth * .56,
                  height: box.maxHeight * .4,
                  child: gender == 'male'
                      ? ColorFiltered(
                          colorFilter: const ColorFilter.matrix([
                            .55,
                            .45,
                            0,
                            0,
                            0,
                            .15,
                            .75,
                            .10,
                            0,
                            0,
                            .10,
                            .75,
                            .15,
                            0,
                            0,
                            0,
                            0,
                            0,
                            1,
                            0,
                          ]),
                          child: AgentSpeakingEffect(level: level),
                        )
                      : AgentSpeakingEffect(level: level),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Original vector head; coordinates share a 100-unit canvas with the Rive mouth.
/// Broad shapes remain readable at office scale; fine detail appears on zoom.
class _AgentHead extends CustomPainter {
  const _AgentHead(this.style, this.actor, this.gender);
  final String gender;
  final AvatarStyle style;
  final String actor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);
    final skinShadow = Color.lerp(style.skin, const Color(0xff915442), .22)!;
    final skinLight = Color.lerp(style.skin, const Color(0xfffff2dd), .25)!;
    final hairLight = Color.lerp(style.hair, const Color(0xffd9b697), .22)!;
    final ink = Color.lerp(style.hair, const Color(0xff17262a), .5)!;
    final fill = Paint();
    final female = gender == 'female';
    final male = gender == 'male';

    // A warm lit forehead and softly shaded jaw, using the body's skin palette.
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 100, 100),
      fill
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [skinLight, style.skin, skinShadow],
          stops: const [0, .62, 1],
        ).createShader(const Rect.fromLTWH(0, 0, 100, 100)),
    );
    fill.shader = null;
    canvas.drawOval(
      const Rect.fromLTWH(20, 79, 60, 18),
      fill..color = skinLight.withValues(alpha: .12),
    );

    // Preset silhouettes are deliberately readable at office zoom: a long bob versus short, tapered sides.
    if (female) {
      final longHair = Path()
        ..moveTo(-4, 48)
        ..cubicTo(-8, 9, 10, -5, 43, -5)
        ..cubicTo(77, -9, 108, 6, 105, 44)
        ..lineTo(106, 103)
        ..lineTo(78, 103)
        ..quadraticBezierTo(88, 79, 84, 38)
        ..quadraticBezierTo(73, 35, 65, 21)
        ..quadraticBezierTo(47, 37, 20, 33)
        ..quadraticBezierTo(10, 76, 25, 103)
        ..lineTo(-5, 103)
        ..close();
      canvas.drawPath(longHair, fill..color = style.hair);
      for (final x in [9.0, 91.0]) {
        canvas.drawPath(
          Path()
            ..moveTo(x, 42)
            ..quadraticBezierTo(x - 3, 76, x + 1, 94),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeCap = StrokeCap.round
            ..color = hairLight.withValues(alpha: .5),
        );
      }
      // A small gold ear detail separates the face from the long hair.
      for (final x in [18.0, 82.0]) {
        canvas.drawCircle(
          Offset(x, 65),
          2.2,
          fill..color = const Color(0xffd6ab58),
        );
      }
    } else {
      final hair = Path()
        ..moveTo(-4, 36)
        ..cubicTo(-7, 10, 10, -5, 39, -5)
        ..cubicTo(70, -13, 103, 2, 105, 30)
        ..lineTo(96, male ? 45 : 58)
        ..quadraticBezierTo(88, 40, 89, 27)
        ..quadraticBezierTo(75, 30, 65, 17)
        ..cubicTo(51, 33, 30, 35, 15, 30)
        ..quadraticBezierTo(14, 37, 7, male ? 45 : 57)
        ..close();
      canvas.drawPath(hair, fill..color = style.hair);
    }
    final sweep = Path()
      ..moveTo(11, 20)
      ..cubicTo(26, 6, 52, 4, 70, 10)
      ..cubicTo(51, 10, 38, 25, 17, 25)
      ..quadraticBezierTo(13, 24, 11, 20);
    canvas.drawPath(sweep, fill..color = hairLight);

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    // Distinct brows are a more legible expression than tiny moving details.
    for (final x in [33.0, 67.0]) {
      canvas.drawPath(
        Path()
          ..moveTo(x - 7, 35.5)
          ..quadraticBezierTo(x, 32.5, x + 7, 35),
        stroke
          ..color = style.hair
          ..strokeWidth = female ? 1.7 : 2.6,
      );
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, 43), width: 13, height: 10),
        fill..color = const Color(0xfffff8ed),
      );
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x + .5, 43), width: 7, height: 9),
        fill..color = ink,
      );
      canvas.drawCircle(Offset(x - .8, 41), 1.3, fill..color = Colors.white);
      canvas.drawPath(
        Path()
          ..moveTo(x - 6, 41)
          ..quadraticBezierTo(x, 36.5, x + 6, 41),
        stroke
          ..color = ink
          ..strokeWidth = 1.5,
      );
    }

    if (female) {
      final lash = Paint()
        ..color = ink
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 1.3;
      canvas.drawLine(const Offset(27, 40), const Offset(24, 37), lash);
      canvas.drawLine(const Offset(73, 40), const Offset(76, 37), lash);
    }

    // Nose and blush use related skin tones rather than a separate face patch.
    canvas.drawPath(
      Path()
        ..moveTo(49, 48)
        ..quadraticBezierTo(46, 56, 51, 56),
      stroke
        ..color = skinShadow
        ..strokeWidth = 1.8,
    );
    for (final x in [23.0, 77.0]) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset(x, 56), width: 13, height: 6),
        fill..color = const Color(0xffc66f61).withValues(alpha: .17),
      );
    }

    // Small deterministic freckles provide identity at larger sizes only.
    if (size.shortestSide >= 56 &&
        actor.codeUnits.fold<int>(0, (a, b) => a + b).isEven) {
      for (final x in [23.0, 28.0, 72.0, 77.0]) {
        canvas.drawCircle(
          Offset(x, x == 28 || x == 72 ? 55 : 53.5),
          .8,
          fill..color = skinShadow,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AgentHead oldDelegate) =>
      oldDelegate.style.skin != style.skin ||
      oldDelegate.style.hair != style.hair ||
      oldDelegate.actor != actor ||
      oldDelegate.gender != gender;
}

class AgentSpeakingEffect extends StatefulWidget {
  const AgentSpeakingEffect({super.key, this.level = 0});
  final double level;

  /// The bundled Mouth artboard uses 0 = closed, 3 = small, 2 = medium, 1 = wide.
  static double poseForLevel(double level) => level < .015
      ? 0
      : level < .08
      ? 3
      : level < .18
      ? 2
      : 1;
  @override
  State<AgentSpeakingEffect> createState() => _AgentSpeakingEffectState();
}

class _AgentSpeakingEffectState extends State<AgentSpeakingEffect> {
  late final loader = rive.FileLoader.fromAsset(
    'assets/animations/agent-mouth.riv',
    riveFactory: rive.Factory.flutter,
  );
  rive.RiveWidgetController? controller;
  rive.NumberInput? mouth;
  @override
  void dispose() {
    mouth?.dispose();
    loader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => rive.RiveWidgetBuilder(
    fileLoader: loader,
    // Only this isolated mouth artboard is used. The prerecorded demo/audio timeline is never instantiated.
    artboardSelector: rive.ArtboardSelector.byName('Mouth'),
    builder: (context, state) {
      if (state is rive.RiveLoaded) {
        if (!identical(controller, state.controller)) {
          mouth?.dispose();
          controller = state.controller;
          // The licensed example exposes a legacy numeric input rather than data binding.
          // ignore: deprecated_member_use
          mouth = state.controller.stateMachine.number('numViseme');
        }
        final pose = AgentSpeakingEffect.poseForLevel(widget.level);
        if (mouth?.value != pose) mouth?.value = pose;
        return Transform.scale(
          scale: 1.8,
          child: rive.RiveWidget(
            controller: state.controller,
            fit: rive.Fit.contain,
          ),
        );
      }
      return const Center(
        child: SizedBox(
          width: 10,
          height: 2,
          child: ColoredBox(color: Color(0xff903f56)),
        ),
      );
    },
  );
}
