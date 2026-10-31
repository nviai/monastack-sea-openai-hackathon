import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'package:monastack/platform/bridge/api/outbox.dart';
import 'package:monastack/platform/core_bridge.dart';
import 'package:monastack/shared/node_request.dart';

/// A task command was durably queued but has not yet been acknowledged.
class TaskChangeQueued implements Exception {
  const TaskChangeQueued();
}

/// The authority rejected a command; it must be reviewed and discarded or recreated.
class TaskChangeRejected implements Exception {
  const TaskChangeRejected();
}

class OutboxFailure implements Exception {
  const OutboxFailure(this.code);
  final String code;
}

/// SQLite work runs on Rust worker threads through the bridge; task and chat
/// queues use separate files.
/// Neither stores tokens or cached project snapshots.
class TaskOutbox {
  TaskOutbox.forPath(this.actor, this.path);
  final String actor;
  final String path;
  static Future<TaskOutbox> open(String actor, {bool chat = false}) async {
    late final Directory dir;
    if (Platform.environment['MONASTACK_TEST_ISOLATED_OUTBOX'] == '1') {
      final temp = await getTemporaryDirectory();
      await temp.create(recursive: true);
      final scope = Platform.environment['MONASTACK_TEST_OUTBOX_SCOPE'];
      if (scope != null && RegExp(r'^[a-f0-9]{32}$').hasMatch(scope)) {
        dir = Directory('${temp.path}/monastack-app-test-$scope');
        await dir.create(recursive: true);
      } else {
        dir = await temp.createTemp('monastack-app-test-');
      }
    } else {
      dir = await getApplicationSupportDirectory();
    }
    final queue = TaskOutbox.forPath(
      actor,
      '${dir.path}/${chat ? 'chat' : 'task'}-outbox-v1.sqlite3',
    );
    await queue.list();
    return queue;
  }

  Future<T> _call<T>(Future<T> Function() call) async {
    try {
      await CoreBridge.ensureInitialized();
      return await call();
    } on CoreError catch (e) {
      throw OutboxFailure(
        e.kind == CoreErrorKind.outbox ? e.detail : 'native_error',
      );
    } on OutboxFailure {
      rethrow;
    } catch (_) {
      throw const OutboxFailure('native_error');
    }
  }

  Future<void> enqueue(String route, Map<String, dynamic> body) => _call(
    () => outboxEnqueue(
      dbPath: path,
      actor: actor,
      op: body['op'] as String? ?? '',
      route: route,
      bodyJson: jsonEncode(body),
    ),
  );

  Future<List<Map<String, dynamic>>> list() async {
    final entries = await _call(() => outboxList(dbPath: path, actor: actor));
    return [
      for (final e in entries)
        {
          'op': e.op,
          'route': e.route,
          'body': jsonDecode(e.bodyJson),
          'state': e.state,
          'reason': e.reason,
        },
    ];
  }

  Future<void> mark(String op, String state, {String? reason}) => _call(
    () => outboxMark(
      dbPath: path,
      actor: actor,
      op: op,
      state: state,
      reason: reason,
    ),
  );

  static bool supports(String method, String path) {
    if (method != 'POST') return false;
    final p = path.split('/');
    if (p.length == 4 && p[1] == 'v1' && p[2] == 'messages') {
      return RegExp(r'^(room|dm)%3A[A-Za-z0-9_-]{1,80}$').hasMatch(p[3]);
    }
    if (p.length == 3 && p[1] == 'v1' && p[2] == 'projects') return true;
    if (p.length == 5 &&
        p[1] == 'v1' &&
        p[2] == 'projects' &&
        p[4] == 'tasks') {
      return true;
    }
    return p.length == 5 &&
        p[1] == 'v1' &&
        p[2] == 'tasks' &&
        const {'transition', 'assign', 'comments'}.contains(p[4]);
  }
}

class TaskDelivery {
  TaskDelivery({
    required this.outbox,
    required this.network,
    required this.active,
    required this.onChanged,
  });
  final TaskOutbox outbox;
  final NodeRequest network;
  final bool Function() active;
  final void Function(List<Map<String, dynamic>>) onChanged;
  Future<void>? _inFlight;
  Future<void> waitForDrain() async {
    final pending = _inFlight;
    if (pending != null) {
      await pending;
    }
  }

  Future<void> updateView() async {
    final items = await outbox.list();
    if (active()) onChanged(items);
  }

  Future<void> drain() {
    final existing = _inFlight;
    if (existing != null) return existing;
    late final Future<void> flight;
    flight = _drain().whenComplete(() {
      if (identical(_inFlight, flight)) _inFlight = null;
    });
    _inFlight = flight;
    return flight;
  }

  Future<void> _drain() async {
    final entries = await outbox.list();
    for (final item in entries) {
      if (!active()) break;
      // Preserve command order: an unresolved rejection blocks later changes.
      if (item['state'] == 'rejected') break;
      if (item['state'] != 'pending') continue;
      final op = item['op'] as String;
      try {
        await network('POST', item['route'] as String, item['body']);
        await outbox.mark(op, 'delivered');
      } on NodeFailure catch (e) {
        if (e.status == 400 ||
            e.status == 403 ||
            e.status == 404 ||
            e.status == 409 ||
            e.status == 413 ||
            e.status == 422) {
          await outbox.mark(
            op,
            'rejected',
            reason: 'Server rejected (${e.status}); review and recreate.',
          );
          break;
        }
        break;
      } catch (_) {
        break;
      }
    }
    await updateView();
  }

  Future<dynamic> request(String method, String path, [Object? body]) async {
    if (!TaskOutbox.supports(method, path)) return network(method, path, body);
    if (!active()) throw const OutboxFailure('not_connected');
    if (body is! Map<String, dynamic> || body['op'] is! String) {
      throw const OutboxFailure('invalid_command');
    }
    await outbox.enqueue(path, body);
    await drain();
    var items = await outbox.list();
    if (items.any((e) => e['op'] == body['op'] && e['state'] == 'pending') &&
        active()) {
      await drain();
      items = await outbox.list();
    }
    if (active()) onChanged(items);
    final matching = items.where((e) => e['op'] == body['op']).toList();
    if (matching.isEmpty) return null;
    if (matching.first['state'] == 'rejected') throw const TaskChangeRejected();
    throw const TaskChangeQueued();
  }
}
