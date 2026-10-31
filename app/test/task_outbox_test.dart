import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/features/sync/task_outbox.dart';
import 'package:monastack/shared/node_request.dart';

void main() {
  test(
    'legacy queued chat survives restart and can never be replayed',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'monastack-legacy-outbox-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/chat.sqlite3';
      final box = TaskOutbox.forPath('authority_a_an', path);
      const route = '/v1/messages/room%3Alobby';
      const payload = {
        'id': '0123456789abcdef',
        'op': '0123456789abcdef',
        'body': 'Unsent text',
      };
      await box.enqueue(route, payload);
      final restored = TaskOutbox.forPath('authority_a_an', path);
      expect((await restored.list()).single['body'], payload);
      expect(await TaskOutbox.forPath('authority_b_an', path).list(), isEmpty);
      var writes = 0;
      final delivery = TaskDelivery(
        outbox: restored,
        network: (method, path, [body]) async {
          writes++;
        },
        active: () => true,
        onChanged: (_) {},
      );
      await delivery.drain();
      expect(writes, 0);
      expect((await restored.list()).single['state'], 'rejected');
      expect(TaskOutbox.supports('POST', route), isFalse);
      await expectLater(
        delivery.request('POST', route, payload),
        throwsA(isA<OutboxFailure>()),
      );
      expect(writes, 0);
    },
  );
  test(
    'durable task changes survive restart and are delivered idempotently',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'monastack-outbox-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/queue.sqlite3';
      final queue = TaskOutbox.forPath('an', path);
      final payload = {
        'id': '0123456789abcdef',
        'name': 'Project',
        'op': 'abcdef0123456789',
      };
      var online = false;
      var calls = 0;
      Future<dynamic> node(String method, String path, [Object? body]) async {
        calls++;
        if (!online) throw const SocketException('offline');
        return null;
      }

      final delivery = TaskDelivery(
        outbox: queue,
        network: node,
        active: () => true,
        onChanged: (_) {},
      );
      await expectLater(
        delivery.request('POST', '/v1/projects', payload),
        throwsA(isA<TaskChangeQueued>()),
      );
      expect((await queue.list()).single['state'], 'pending');
      expect(await TaskOutbox.forPath('van', path).list(), isEmpty);
      online = true;
      final restarted = TaskDelivery(
        outbox: TaskOutbox.forPath('an', path),
        network: node,
        active: () => true,
        onChanged: (_) {},
      );
      await restarted.drain();
      expect(await restarted.outbox.list(), isEmpty);
      expect(calls, greaterThanOrEqualTo(2));
      await restarted.request('POST', '/v1/projects', payload);
      expect(await restarted.outbox.list(), isEmpty);
    },
  );
  test(
    'authority conflicts remain visible and require explicit discard',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'monastack-outbox-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final queue = TaskOutbox.forPath('an', '${dir.path}/queue.sqlite3');
      Future<dynamic> node(String method, String path, [Object? body]) async =>
          throw const NodeFailure(409);
      final delivery = TaskDelivery(
        outbox: queue,
        network: node,
        active: () => true,
        onChanged: (_) {},
      );
      await expectLater(
        delivery.request('POST', '/v1/tasks/0123456789abcdef/transition', {
          'op': 'abcdef0123456789',
          'to': 'done',
          'expected_version': 1,
        }),
        throwsA(isA<TaskChangeRejected>()),
      );
      final entry = (await queue.list()).single;
      expect(entry['state'], 'rejected');
      await queue.mark(entry['op'] as String, 'discarded');
      expect(await queue.list(), isEmpty);
    },
  );
  test('a rejected command stops later commands until reviewed', () async {
    final dir = await Directory.systemTemp.createTemp('monastack-outbox-test-');
    addTearDown(() => dir.delete(recursive: true));
    final queue = TaskOutbox.forPath('an', '${dir.path}/queue.sqlite3');
    var calls = 0;
    Future<dynamic> node(String method, String path, [Object? body]) async {
      calls++;
      if (calls == 1) throw const NodeFailure(409);
      return null;
    }

    final delivery = TaskDelivery(
      outbox: queue,
      network: node,
      active: () => true,
      onChanged: (_) {},
    );
    await expectLater(
      delivery.request('POST', '/v1/projects', {
        'op': 'aaaaaaaaaaaaaaaa',
        'id': 'bbbbbbbbbbbbbbbb',
        'name': 'First',
      }),
      throwsA(isA<TaskChangeRejected>()),
    );
    await expectLater(
      delivery.request('POST', '/v1/projects', {
        'op': 'cccccccccccccccc',
        'id': 'dddddddddddddddd',
        'name': 'Second',
      }),
      throwsA(isA<TaskChangeQueued>()),
    );
    expect(calls, 1);
    await queue.mark('aaaaaaaaaaaaaaaa', 'discarded');
    await delivery.drain();
    expect(calls, 2);
    expect(await queue.list(), isEmpty);
  });
}
