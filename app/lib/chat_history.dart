import 'dart:async';

import 'package:flutter/material.dart';

import 'task_board.dart';

/// Online, scope-authorized history. This dialog does not cache messages to disk.
class ChatHistory extends StatefulWidget {
  const ChatHistory({super.key, required this.request, required this.scope});
  final TaskRequest request;
  final String scope;
  @override
  State<ChatHistory> createState() => _ChatHistoryState();
}

class _ChatHistoryState extends State<ChatHistory> {
  List<dynamic> messages = [];
  final List<String?> back = [];
  String? before;
  String? error;
  bool loading = false;
  bool noOlder = false;
  int generation = 0;
  Timer? timer;
  final scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    load(null);
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!loading) load(before);
    });
  }

  Future<void> load(
    String? target, {
    bool older = false,
    bool newer = false,
  }) async {
    if (loading) return;
    final requestId = ++generation;
    setState(() => loading = true);
    try {
      final path =
          '/v1/messages/${Uri.encodeComponent(widget.scope)}'
          '${target == null ? '' : '?before=${Uri.encodeQueryComponent(target)}'}';
      final result = await widget.request('GET', path) as List<dynamic>;
      if (!mounted || requestId != generation) return;
      if (result.length > 200 ||
          result.any(
            (entry) =>
                entry is! Map<String, dynamic> ||
                entry['id'] is! String ||
                entry['sender'] is! String ||
                entry['body'] is! String,
          )) {
        throw const FormatException('Invalid message page');
      }
      final priorFirst = messages.isEmpty
          ? null
          : (messages.first as Map<String, dynamic>)['id'];
      setState(() {
        if (older && result.isEmpty) {
          noOlder = true;
        } else {
          if (older) back.add(before);
          if (newer) back.removeLast();
          before = target;
          messages = result;
          noOlder =
              result.length < 200 ||
              (!older &&
                  !newer &&
                  noOlder &&
                  result.isNotEmpty &&
                  (result.first as Map<String, dynamic>)['id'] == priorFirst);
        }
        error = null;
      });
      if ((older && result.isNotEmpty) || newer) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && scroll.hasClients) scroll.jumpTo(0);
        });
      }
    } catch (_) {
      if (mounted && requestId == generation) {
        setState(() {
          messages = [];
          back.clear();
          before = null;
          noOlder = true;
          error = 'History unavailable or access denied.';
        });
      }
    } finally {
      if (mounted && requestId == generation) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 620,
      height: 560,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Conversation history',
                    style: TextStyle(fontSize: 22),
                  ),
                ),
                IconButton(
                  tooltip: 'Close history',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Text(
              'Online history · access is checked again on each page and refresh.',
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            Row(
              children: [
                TextButton(
                  onPressed: loading || noOlder || messages.isEmpty
                      ? null
                      : () => load(
                          (messages.first as Map<String, dynamic>)['id']
                              as String,
                          older: true,
                        ),
                  child: const Text('Older'),
                ),
                TextButton(
                  onPressed: loading || back.isEmpty
                      ? null
                      : () => load(back.last, newer: true),
                  child: const Text('Newer'),
                ),
                if (loading) const Text('Loading…'),
              ],
            ),
            Expanded(
              child: messages.isEmpty
                  ? const Center(
                      child: Text('No accessible messages on this page.'),
                    )
                  : ListView.builder(
                      controller: scroll,
                      itemCount: messages.length,
                      itemBuilder: (context, i) {
                        final message = messages[i] as Map<String, dynamic>;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '${message['sender']}: ${message['body']}',
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}
