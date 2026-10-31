import 'dart:convert';
import 'dart:io';

import 'package:monastack/shared/node_request.dart';

/// Presence calls to the realtime capability. The bearer credential stays
/// with the authority; this service only receives short-lived tickets, which
/// are refreshed before expiry and once more after a 401 (for example after
/// an access change advanced the authority's epoch).
class RealtimeSession {
  RealtimeSession({required this.client, required this.issue});

  final HttpClient client;

  /// Requests a ticket from the authority: `POST /v1/realtime/ticket`.
  final Future<dynamic> Function() issue;

  String? _ticket;
  Uri? _base;
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);

  /// Only loopback HTTP is accepted, matching the local topology.
  static Uri? parseBase(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'http' ||
        uri.host != '127.0.0.1' ||
        !uri.hasPort ||
        uri.path.isNotEmpty) {
      return null;
    }
    return uri;
  }

  Future<void> _refresh() async {
    final issued = await issue() as Map<String, dynamic>;
    final base = parseBase(issued['realtime_url']);
    final ticket = issued['ticket'];
    final seconds = issued['expires_in'];
    if (base == null || ticket is! String || seconds is! int) {
      throw const FormatException('invalid realtime ticket');
    }
    _base = base;
    _ticket = ticket;
    // Refresh well before expiry to tolerate clock skew and slow requests.
    _expires = DateTime.now().add(Duration(seconds: seconds ~/ 2));
  }

  Future<dynamic> request(String method, String path, [Object? body]) async {
    if (_ticket == null || DateTime.now().isAfter(_expires)) await _refresh();
    try {
      return await _send(method, path, body);
    } on NodeFailure catch (e) {
      if (e.status != 401) rethrow;
      await _refresh();
      return _send(method, path, body);
    } on IOException {
      // A pooled keep-alive connection can be closed by the server between
      // requests. Reads are safe to repeat; writes are repeated by the next
      // heartbeat with a new sequence number instead.
      if (method != 'GET') rethrow;
      return _send(method, path, body);
    }
  }

  Future<dynamic> _send(String method, String path, Object? body) async {
    final req = await client
        .openUrl(method, _base!.replace(path: path))
        .timeout(const Duration(seconds: 3));
    req.headers.set(HttpHeaders.authorizationHeader, 'Ticket $_ticket');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close().timeout(const Duration(seconds: 3));
    final text = await utf8.decoder
        .bind(res)
        .join()
        .timeout(const Duration(seconds: 3));
    if (res.statusCode >= 400) throw NodeFailure(res.statusCode);
    return text.isEmpty ? null : jsonDecode(text);
  }
}
