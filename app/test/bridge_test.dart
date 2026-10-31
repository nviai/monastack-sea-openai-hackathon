import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/platform/bridge/api/office.dart';
import 'package:monastack/platform/bridge/api/outbox.dart';
import 'package:monastack/platform/core_bridge.dart';

TypeMatcher<CoreError> coreError(CoreErrorKind kind) =>
    isA<CoreError>().having((e) => e.kind, 'kind', kind);

void main() {
  late OfficeCore core;
  setUpAll(() async {
    await CoreBridge.ensureInitialized();
    core = await OfficeCore.load(
      seedJson: File('assets/seed.v1.json').readAsStringSync(),
      mapJson: File('assets/map.v2.json').readAsStringSync(),
    );
  });
  tearDownAll(() => core.dispose());

  const lobby = Cell(x: 14, y: 13);
  const finance = Cell(x: 25, y: 23);

  test('generated bridge enforces seed membership asynchronously', () async {
    expect(core.mayEnter(actor: 'van', room: 'finance'), isTrue);
    expect(core.mayEnter(actor: 'an', room: 'finance'), isFalse);
    expect(core.mayEnter(actor: 'van', room: 'hr'), isFalse);
    await expectLater(
      core.findPath(actor: 'an', start: lobby, goal: finance),
      throwsA(coreError(CoreErrorKind.inaccessible)),
    );
    final route = await core.findPath(
      actor: 'van',
      start: lobby,
      goal: finance,
    );
    expect(route.first, lobby);
    expect(route.last, finance);
    expect(
      await core.findPath(
        actor: 'an',
        start: lobby,
        goal: finance,
        allowedRooms: ['lobby', 'finance'],
      ),
      isNotEmpty,
    );
    await expectLater(
      core.findPath(
        actor: 'unknown',
        start: lobby,
        goal: finance,
        allowedRooms: ['lobby', 'finance'],
      ),
      throwsA(coreError(CoreErrorKind.inaccessible)),
    );
    await expectLater(
      core.findPath(
        actor: 'van',
        start: lobby,
        goal: finance,
        allowedRooms: ['lobby'],
      ),
      throwsA(coreError(CoreErrorKind.inaccessible)),
    );
    expect(core.roomAt(cell: finance), 'finance');
  });

  test('invalid documents fail with typed errors', () async {
    await expectLater(
      OfficeCore.load(seedJson: '{}', mapJson: '{}'),
      throwsA(coreError(CoreErrorKind.invalidSeed)),
    );
    await expectLater(
      OfficeCore.load(
        seedJson: File('assets/seed.v1.json').readAsStringSync(),
        mapJson: '{"version":1}',
      ),
      throwsA(coreError(CoreErrorKind.invalidMap)),
    );
  });

  test('outbox errors keep their stable codes', () async {
    final dir = Directory.systemTemp.createTempSync('monastack-bridge-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final db = '${dir.path}/outbox.sqlite3';
    await expectLater(
      outboxMark(
        dbPath: db,
        actor: 'a_an',
        op: '0123456789abcdef',
        state: 'delivered',
      ),
      throwsA(
        coreError(CoreErrorKind.outbox)
            .having((e) => e.detail, 'detail', 'not_pending'),
      ),
    );
    expect(await outboxList(dbPath: db, actor: 'a_an'), isEmpty);
  });
}
