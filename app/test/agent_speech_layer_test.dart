import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/office/world/agent_speech_layer.dart';
import 'package:monastack/features/office/world/world_game.dart';
import 'package:rive/rive.dart' as rive;

void main() {
  test(
    'mouth poses follow real audio amplitude and return closed at silence',
    () {
      expect(AgentSpeakingEffect.poseForLevel(0), 0);
      expect(AgentSpeakingEffect.poseForLevel(.04), 3);
      expect(AgentSpeakingEffect.poseForLevel(.12), 2);
      expect(AgentSpeakingEffect.poseForLevel(.4), 1);
    },
  );
  testWidgets(
    'speech bubbles follow the projected head and expire without crossing rooms',
    (tester) async {
      final game = WorldGame(onStep: (_) {});
      game.onGameResize(Vector2(800, 600));
      game.agentSeats = [(actor: 'mona', seat: (x: 0, y: 0))];
      final presentation = ValueNotifier<Map<String, dynamic>>({
        'mona': {
          'name': 'Mona',
          'gender': 'female',
          'text': 'Hello office',
          'at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        },
      });
      final speaking = ValueNotifier<Set<String>>({});
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentSpeechLayer(
              game: game,
              presentation: presentation,
              speaking: speaking,
              reduceMotion: true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Hello office'), findsOneWidget);
      expect(
        tester.widget<AgentAvatarFace>(find.byType(AgentAvatarFace)).gender,
        'female',
      );
      presentation.value = {
        'mona': {...presentation.value['mona'] as Map, 'gender': 'male'},
      };
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        tester.widget<AgentAvatarFace>(find.byType(AgentAvatarFace)).gender,
        'male',
      );
      presentation.value = {};
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('Hello office'), findsNothing);
      presentation.value = {
        'mona': {'name': 'Mona', 'text': 'Expired text', 'at': 1},
      };
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('Expired text'), findsNothing);
      speaking.value = {'mona'};
      await tester.pump(const Duration(milliseconds: 20));
      expect(find.text('Speaking…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      presentation.dispose();
      speaking.dispose();
    },
  );
  testWidgets('bundled Rive speaking asset loads with the native runtime', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 80, height: 80, child: AgentSpeakingEffect()),
        ),
      ),
    );
    for (
      var i = 0;
      i < 100 && find.byType(rive.RiveWidget).evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    expect(find.byType(rive.RiveWidget), findsOneWidget);
    final rendered = tester.widget<rive.RiveWidget>(
      find.byType(rive.RiveWidget),
    );
    expect(rendered.controller.artboard.name, 'Mouth');
    // ignore: deprecated_member_use
    final mouth = rendered.controller.stateMachine.number('numViseme')!;
    expect(mouth.value, 0);
    mouth.dispose();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 80,
            height: 80,
            child: AgentSpeakingEffect(level: .4),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    final changed = tester.widget<rive.RiveWidget>(
      find.byType(rive.RiveWidget),
    );
    // ignore: deprecated_member_use
    final open = changed.controller.stateMachine.number('numViseme')!;
    expect(
      open.value,
      1,
      reason: 'The actual Rive mouth receives the measured loudness',
    );
    open.dispose();
    await tester.pumpWidget(const SizedBox());
  });
}
