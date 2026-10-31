import 'package:flutter/material.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_theme.dart';
import '../../../shared/nexus_tokens.dart';
import '../domain/chat_client.dart';
import 'chat_atoms.dart';

class LegacyHistory extends StatefulWidget {
  const LegacyHistory({
    super.key,
    required this.client,
    required this.scope,
    this.room,
  });
  final ChatClient client;
  final String scope;
  final String? room;
  @override
  State<LegacyHistory> createState() => _LegacyHistoryState();
}

class _LegacyHistoryState extends State<LegacyHistory> {
  List<Map<String, dynamic>> messages = [];
  bool loading = true, older = true;
  String? error, before;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    widget.client.addListener(changed);
    load();
  }

  void changed() {
    final office = widget.scope.startsWith('room:')
        ? widget.scope.substring(5)
        : null;
    if ((widget.room != null &&
            !widget.client.rooms.any((r) => r.id == widget.room)) ||
        (office != null &&
            !widget.client.rooms.any((r) => r.officeRoom == office))) {
      generation++;
      setState(() {
        messages = [];
        error = 'History unavailable or access denied.';
        loading = false;
        older = false;
      });
    }
  }

  Future<void> load() async {
    final request = ++generation;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await widget.client.legacy(widget.scope, before: before);
      if (!mounted || request != generation) return;
      setState(() {
        messages.addAll(page);
        older = page.length == 50;
        if (page.isNotEmpty) before = page.last['created'].toString();
      });
    } catch (_) {
      if (mounted && request == generation) {
        setState(() {
          messages = [];
          error = 'History unavailable or access denied.';
        });
      }
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    generation++;
    widget.client.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return NexusTheme(
      child: Builder(
        builder: (context) => AlertDialog(
          title: const Text('Earlier messages (before Matrix)'),
          content: SizedBox(
            width: NxSize.legacyW,
            height: NxSize.legacyH,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Read-only history. New messages are sent in Chat.',
                  style: nx.text(NexusTokens.t125, color: nx.ink2),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: NxSpace.s8),
                    child: Text(
                      error!,
                      style: nx.text(
                        NexusTokens.t125,
                        weight: NexusTokens.w560,
                        color: nx.now,
                      ),
                    ),
                  ),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.only(top: NxSpace.s8),
                    child: LinearProgressIndicator(minHeight: NxSize.progress),
                  ),
                Expanded(
                  child: messages.isEmpty
                      ? const ChatNote('No earlier messages.')
                      : ListView(
                          children: [
                            for (final message in messages)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: NxSpace.s6,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${message['sender_name']} · ${message['created']}',
                                      style: nx.text(
                                        NexusTokens.t12,
                                        color: nx.ink3,
                                      ),
                                    ),
                                    SelectableText(
                                      message['body'] as String,
                                      style: nx.text(
                                        NexusTokens.t14,
                                        height: NexusTokens.lhBody,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                ),
                if (older || error != null)
                  TextButton(
                    onPressed: loading ? null : load,
                    child: Text(
                      error == null ? 'Load older messages' : 'Retry history',
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}
