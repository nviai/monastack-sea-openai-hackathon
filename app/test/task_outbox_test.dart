import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/task_outbox.dart';

void main() {
  test('queued chat survives restart, deduplicates delivery and rejects revoked scope', () async {
    final dir = await Directory.systemTemp.createTemp(
      'monastack-chat-outbox-test-',
    );
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/chat.sqlite3';
    final sent = <String, String>{};
    var loseResponses = 2;
    var allowed = true;
    Future<dynamic> network(String method, String path, [Object? body]) async {
      if (!allowed) throw const NodeFailure(403);
      final data = body as Map<String, dynamic>;
      sent[data['id'] as String] = data['body'] as String;
      if (loseResponses > 0) {
        loseResponses--;
        throw const SocketException('lost response');
      }
    }

    final box = TaskOutbox.forPath('authority_a_an', path);
    final first = TaskDelivery(
      outbox: box,
      network: network,
      active: () => true,
      onChanged: (_) {},
    );
    const id = '0123456789abcdef';
    await expectLater(
      first.request('POST', '/v1/messages/room%3Alobby', {
        'id': id,
        'op': id,
        'body': 'Synthetic message',
      }),
      throwsA(isA<TaskChangeQueued>()),
    );
    expect((await box.list()).single['state'], 'pending');
    expect(await TaskOutbox.forPath('authority_b_an', path).list(), isEmpty);
    final resumed = TaskDelivery(
      outbox: TaskOutbox.forPath('authority_a_an', path),
      network: network,
      active: () => true,
      onChanged: (_) {},
    );
    await resumed.drain();
    expect(await resumed.outbox.list(), isEmpty);
    expect(sent.length, 1);
    allowed = false;
    const privateId = 'abcdef0123456789';
    await expectLater(
      resumed.request('POST', '/v1/messages/room%3Afinance', {
        'id': privateId,
        'op': privateId,
        'body': 'Synthetic private message',
      }),
      throwsA(isA<TaskChangeRejected>()),
    );
    expect((await resumed.outbox.list()).single['state'], 'rejected');
    expect(sent.length, 1);
  });
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
