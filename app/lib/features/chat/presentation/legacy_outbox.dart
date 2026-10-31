import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Recovery only: no retry/replay button exists for pre-Matrix queued messages.
class LegacyOutbox extends StatelessWidget {
  const LegacyOutbox({super.key, required this.entries});
  final List<Map<String, dynamic>> entries;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Earlier messages not sent'),
    content: SizedBox(
      width: 540,
      height: 350,
      child: ListView(
        children: [
          const Text(
            'These messages were queued before Matrix. Copy text into the intended conversation to send it. They will never be sent automatically.',
          ),
          for (final entry in entries)
            ListTile(
              title: SelectableText(
                (entry['body'] as Map?)?['body'] as String? ?? '',
              ),
              subtitle: Text(
                'Not sent · ${Uri.decodeComponent((entry['route'] as String).split('/').last)}',
              ),
              trailing: IconButton(
                tooltip: 'Copy unsent message',
                onPressed: () => Clipboard.setData(
                  ClipboardData(
                    text: (entry['body'] as Map?)?['body'] as String? ?? '',
                  ),
                ),
                icon: const Icon(Icons.copy),
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
}
