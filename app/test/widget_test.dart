import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:monastack/app/monastack_app.dart';
import 'package:monastack/features/office/communication/collaboration.dart';
import 'package:monastack/features/office/data/office_core.dart';
import 'package:monastack/features/office/world/office_world.dart';
import 'package:monastack/features/organization/people_profiles.dart';

void main() {
  for (final size in [const Size(1400, 900), const Size(400, 720)]) {
    testWidgets('signed-out launch shows only login at $size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      var coreRequested = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            seedProvider.overrideWith(
              (ref) async =>
                  jsonDecode(File('assets/seed.v1.json').readAsStringSync())
                      as Map<String, dynamic>,
            ),
            officeCoreProvider.overrideWith((ref) {
              coreRequested = true;
              throw StateError('Office core must not load before sign-in');
            }),
          ],
          child: const Monastack(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Welcome to Monastack'), findsOneWidget);
      expect(find.byType(Collaboration), findsOneWidget);
      expect(find.byType(OfficeWorld), findsNothing);
      expect(find.byType(PeopleProfiles), findsNothing);
      expect(find.text('People & agents'), findsNothing);
      expect(find.text('Finance'), findsNothing);
      expect(find.text('Nguyen Van An'), findsNothing);
      expect(find.text('LOCAL PREVIEW'), findsNothing);
      expect(coreRequested, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
