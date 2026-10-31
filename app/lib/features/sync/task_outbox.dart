import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';

import 'package:monastack/platform/native_library.dart';
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

/// SQLite work runs in an isolate; task and chat queues use separate files.
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

  Future<List<Map<String, dynamic>>> _run(Map<String, dynamic> command) async {
    final data = jsonEncode({'db_path': path, 'actor': actor, ...command});
    final lib = nativeLibraryPath();
    final result = await Isolate.run(() => _callNative(lib, data));
    final decoded = jsonDecode(result) as Map<String, dynamic>;
    if (decoded['ok'] != true) {
      throw OutboxFailure(decoded['error'] as String? ?? 'storage_error');
    }
    return (decoded['entries'] as List).cast<Map<String, dynamic>>();
  }

  Future<void> enqueue(String route, Map<String, dynamic> body) async {
    await _run({
      'action': 'enqueue',
      'route': route,
      'op': body['op'],
      'body': body,
    });
  }

  Future<List<Map<String, dynamic>>> list() => _run({'action': 'list'});
  Future<void> mark(String op, String state, {String? reason}) async {
    await _run({'action': 'mark', 'op': op, 'state': state, 'reason': reason});
  }

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

String _callNative(String library, String request) {
  final lib = DynamicLibrary.open(library);
  final call = lib
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Utf8>),
        Pointer<Utf8> Function(Pointer<Utf8>)
      >('monastack_outbox_v1');
  final free = lib
      .lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)
      >('monastack_free_v1');
  final input = request.toNativeUtf8();
  try {
    final result = call(input);
    if (result == nullptr) throw const OutboxFailure('native_error');
    try {
      return result.toDartString();
    } finally {
      free(result);
    }
  } finally {
    malloc.free(input);
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
