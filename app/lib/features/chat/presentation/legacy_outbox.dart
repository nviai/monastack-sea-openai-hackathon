import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_theme.dart';
import '../../../shared/nexus_tokens.dart';
import 'chat_atoms.dart';

/// Recovery only: no retry/replay button exists for pre-Matrix queued messages.
class LegacyOutbox extends StatelessWidget {
  const LegacyOutbox({super.key, required this.entries});
  final List<Map<String, dynamic>> entries;
  @override
  Widget build(BuildContext context) => NexusTheme(
    child: Builder(
      builder: (context) {
        final nx = context.nx;
        return AlertDialog(
          title: const Text('Earlier messages not sent'),
          content: SizedBox(
            width: NxSize.outboxW,
            height: NxSize.outboxH,
            child: ListView(
              children: [
                Text(
                  'These messages were queued before Matrix. Copy text into the intended conversation to send it. They will never be sent automatically.',
                  style: nx.text(NexusTokens.t125, color: nx.ink2),
                ),
                for (final entry in entries)
                  Padding(
                    padding: const EdgeInsets.only(top: NxSpace.s10),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SelectableText(
                                (entry['body'] as Map?)?['body'] as String? ??
                                    '',
                                style: nx.text(
                                  NexusTokens.t14,
                                  height: NexusTokens.lhBody,
                                ),
                              ),
                              Text(
                                'Not sent · ${Uri.decodeComponent((entry['route'] as String).split('/').last)}',
                                style: nx.text(
                                  NexusTokens.t12,
                                  weight: NexusTokens.w560,
                                  color: nx.now,
                                ),
                              ),
                            ],
                          ),
                        ),
                        GhostIconButton(
                          tooltip: 'Copy unsent message',
                          onPressed: () => Clipboard.setData(
                            ClipboardData(
                              text:
                                  (entry['body'] as Map?)?['body'] as String? ??
                                  '',
                            ),
                          ),
                          icon: Icons.copy,
                        ),
                      ],
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
        );
      },
    ),
  );
}
