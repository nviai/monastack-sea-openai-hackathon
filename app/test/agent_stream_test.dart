import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:monastack/shared/agent_stream.dart';
import 'package:monastack/shared/node_request.dart';

void main() {
  test('decodes fragmented UTF-8, CRLF, comments and terminal event', () async {
    final raw =
        ': heartbeat\r\n\r\nevent: delta\r\ndata: {"text":"Chào 👋"}\r\n\r\nevent: done\ndata: {"text":"Chào 👋"}\n\n';
    final events = await decodeAgentEvents(
      Stream.fromIterable(utf8.encode(raw).map((b) => [b])),
    ).toList();
    expect(events.map((e) => e['event']), ['delta', 'done']);
    expect(events.first['text'], 'Chào 👋');
  });
  test('partial EOF is an error, never a completed answer', () async {
    final stream = decodeAgentEvents(
      Stream.value(utf8.encode('event: delta\ndata: {"text":"partial"}\n\n')),
    );
    await expectLater(
      stream,
      emitsInOrder([
        {'event': 'delta', 'text': 'partial'},
        emitsError(isA<FormatException>()),
        emitsDone,
      ]),
    );
  });
  test('sanitizes terminal provider errors to typed failures', () async {
    await expectLater(
      decodeAgentEvents(
        Stream.value(utf8.encode('event: error\ndata: {"status":401}\n\n')),
      ),
      emitsError(isA<NodeFailure>().having((e) => e.status, 'status', 401)),
    );
  });
}
