import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'node_request.dart';

typedef AgentStreamFactory = AgentStream Function(String path, Object body);

/// A single cancellable request. Closing it never affects other office traffic.
abstract class AgentStream {
  Stream<Map<String, dynamic>> get events;
  void cancel();
}

class HttpAgentStream implements AgentStream {
  HttpAgentStream({
    required this.url,
    required this.body,
    required this.bearer,
    required this.refresh,
    required this.active,
    this.onClose,
  });
  final Uri url;
  final Object body;
  final Future<String> Function() bearer;
  final Future<bool> Function() refresh;
  final bool Function() active;
  final void Function()? onClose;
  final _client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  bool _cancelled = false;

  @override
  void cancel() {
    _cancelled = true;
    _client.close(force: true);
    onClose?.call();
  }

  @override
  Stream<Map<String, dynamic>> get events async* {
    final deadline = Timer(const Duration(seconds: 70), cancel);
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        if (_cancelled) return;
        if (!active()) throw const NodeFailure(401);
        final credential = await bearer();
        if (_cancelled) return;
        final request = await _client.postUrl(url);
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $credential',
        );
        request.headers.contentType = ContentType.json;
        request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
        request.write(jsonEncode(body));
        final response = await request.close().timeout(
          const Duration(seconds: 65),
        );
        if (response.statusCode == 401 && attempt == 0) {
          await response.drain<void>();
          if (await refresh()) continue;
        }
        if (response.statusCode >= 400) throw NodeFailure(response.statusCode);
        if (response.headers.contentType?.mimeType != 'text/event-stream') {
          throw const FormatException('Expected an event stream');
        }
        await for (final event in decodeAgentEvents(response)) {
          if (_cancelled) return;
          if (!active()) throw const NodeFailure(401);
          yield event;
        }
        return;
      }
    } finally {
      deadline.cancel();
      cancel();
    }
  }
}

/// Incremental UTF-8 and SSE decoding; EOF is not a successful response.
Stream<Map<String, dynamic>> decodeAgentEvents(Stream<List<int>> bytes) async* {
  var name = '';
  var data = <String>[];
  var size = 0;
  var total = 0;
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    size += line.length;
    total += line.length;
    if (size > 2 * 1024 * 1024 || total > 4 * 1024 * 1024) {
      throw const FormatException('Agent response is too large');
    }
    if (line.isEmpty) {
      if (data.isNotEmpty) {
        final value = Map<String, dynamic>.from(
          jsonDecode(data.join('\n')) as Map,
        );
        if (name == 'error') throw NodeFailure(value['status'] as int? ?? 502);
        if (name == 'delta' || name == 'done') {
          yield {'event': name, ...value};
          if (name == 'done') return;
        }
      }
      name = '';
      data = [];
      size = 0;
    } else if (line.startsWith('event:')) {
      name = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      final value = line.substring(5);
      data.add(value.startsWith(' ') ? value.substring(1) : value);
    }
  }
  throw const FormatException('Agent response was interrupted');
}
