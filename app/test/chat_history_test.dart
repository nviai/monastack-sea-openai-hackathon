import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/chat/presentation/legacy_history.dart';
import 'package:monastack/features/chat/presentation/legacy_outbox.dart';

import 'chat/fake_chat_client.dart';

void main() {
  testWidgets(
    'legacy history uses read-only endpoint with created cursor and clears on revocation',
    (tester) async {
      final client = FakeChatClient()
        ..history = List.generate(
          50,
          (i) => {
            'id': 'old-$i',
            'sender_name': 'An',
            'sender_actor': 'an',
            'body': 'Earlier $i',
            'created': 'time-$i',
          },
        );
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyHistory(client: client, scope: 'room:lobby'),
        ),
      );
      await tester.pumpAndSettle();
      expect(client.calls, contains('legacy:room:lobby:null'));
      expect(find.text('Earlier messages (before Matrix)'), findsOneWidget);
      client.history = [];
      await tester.tap(find.text('Load older messages'));
      await tester.pumpAndSettle();
      expect(client.calls.last, 'legacy:room:lobby:time-49');
      expect(find.text('Load older messages'), findsNothing);
      client.revoke('lobby');
      await tester.pumpAndSettle();
      expect(
        find.text('History unavailable or access denied.'),
        findsOneWidget,
      );
      expect(find.text('Earlier 0'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      client.dispose();
    },
  );
  testWidgets(
    'legacy error is retryable and queue recovery has copy but no resend',
    (tester) async {
      final client = FakeChatClient()..failLoad = true;
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyHistory(client: client, scope: 'dm:an'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Retry history'), findsOneWidget);
      client.failLoad = false;
      await tester.tap(find.text('Retry history'));
      await tester.pumpAndSettle();
      expect(find.text('No earlier messages.'), findsOneWidget);
      await tester.pumpWidget(
        const MaterialApp(
          home: LegacyOutbox(
            entries: [
              {
                'route': '/v1/messages/room%3Alobby',
                'body': {'body': 'Unsent text'},
              },
            ],
          ),
        ),
      );
      expect(find.text('Unsent text'), findsOneWidget);
      expect(find.byTooltip('Copy unsent message'), findsOneWidget);
      expect(find.text('Retry send'), findsNothing);
      expect(find.text('Send'), findsNothing);
      client.dispose();
    },
  );
}
