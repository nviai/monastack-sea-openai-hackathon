import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../application/chat_controller.dart';
import '../domain/chat_client.dart';

class ChatMessageTile extends StatelessWidget {
  const ChatMessageTile({
    super.key,
    required this.message,
    required this.controller,
    this.thread,
  });
  final ChatMessage message;
  final ChatController controller;
  final String? thread;
  Future<void> save(BuildContext context) async {
    await controller.act(() async {
      final destination = await getSaveLocation(
        suggestedName: message.body.split('/').last,
      );
      if (destination == null) return;
      final bytes = await controller.client.download(message);
      // download checks membership again before returning the bytes.
      await XFile.fromData(bytes, name: message.body).saveTo(destination.path);
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = message;
    final pending = controller.pending
        .where((p) => p.transaction == m.transactionId)
        .firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                child: Text(
                  m.sender.characters.firstOrNull ?? '?',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  m.sender,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${m.time.hour.toString().padLeft(2, '0')}:${m.time.minute.toString().padLeft(2, '0')}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              if (m.edited)
                const Text(' · edited', style: TextStyle(fontSize: 11)),
              if (m.delivery != Delivery.sent)
                Text(
                  m.delivery == Delivery.failed ? ' · not sent' : ' · sending',
                  style: TextStyle(
                    fontSize: 11,
                    color: m.delivery == Delivery.failed
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
                ),
              const Spacer(),
              if (!m.deleted && m.delivery == Delivery.sent)
                PopupMenuButton<String>(
                  tooltip: 'Message actions',
                  onSelected: (value) {
                    switch (value) {
                      case 'copy':
                        Clipboard.setData(ClipboardData(text: m.body));
                      case 'reply':
                        controller.mode(m.roomId, m, root: thread);
                      case 'thread':
                        controller.openThread(m);
                      case 'react':
                        controller.act(
                          () => controller.client.react(m.roomId, m.id, '👍'),
                        );
                      case 'edit':
                        controller.mode(m.roomId, m, edit: true, root: thread);
                      case 'delete':
                        controller.act(
                          () => controller.client.redact(m.roomId, m.id),
                        );
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'copy',
                      child: Text('Copy text'),
                    ),
                    const PopupMenuItem(value: 'reply', child: Text('Reply')),
                    const PopupMenuItem(
                      value: 'thread',
                      child: Text('Open thread'),
                    ),
                    const PopupMenuItem(
                      value: 'react',
                      child: Text('React 👍'),
                    ),
                    if (m.own && m.attachment == null)
                      const PopupMenuItem(
                        value: 'edit',
                        child: Text('Edit message'),
                      ),
                    if (m.canDelete)
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Delete message'),
                      ),
                  ],
                ),
            ],
          ),
          if (m.replyTo != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                '↳ Reply to ${controller.client.messages(m.roomId).where((e) => e.id == m.replyTo).firstOrNull?.sender ?? 'a message'}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          if (m.deleted)
            const Text(
              'Message deleted',
              style: TextStyle(fontStyle: FontStyle.italic),
            )
          else if (m.attachment != null) ...[
            if (m.image) AttachmentPreview(message: m, controller: controller),
            TextButton.icon(
              onPressed: () => save(context),
              icon: const Icon(Icons.download_outlined),
              label: Text(m.body, overflow: TextOverflow.ellipsis),
            ),
          ] else
            MarkdownBody(
              data: m.body,
              selectable: true,
              imageBuilder: (uri, title, alt) => Text(alt ?? 'Image link'),
              onTapLink: (_, href, _) async {
                final uri = Uri.tryParse(href ?? '');
                if (uri != null &&
                    ['https', 'http', 'mailto'].contains(uri.scheme)) {
                  await controller.act(() async {
                    if (!await launchUrl(uri)) {
                      throw StateError('Link unavailable');
                    }
                  });
                }
              },
            ),
          if (pending?.bytes != null && pending!.delivery == Delivery.sending)
            LinearProgressIndicator(value: pending.progress),
          if (m.delivery == Delivery.failed && pending != null)
            TextButton.icon(
              onPressed: () => controller.retry(pending),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry send'),
            ),
          if (!m.deleted && m.reactions.isNotEmpty)
            Wrap(
              spacing: 6,
              children: [
                for (final reaction in m.reactions.entries)
                  ActionChip(
                    label: Text('${reaction.key} ${reaction.value}'),
                    onPressed: () => controller.act(
                      () =>
                          controller.client.react(m.roomId, m.id, reaction.key),
                    ),
                  ),
              ],
            ),
          if (m.readers.isNotEmpty)
            Text(
              'Read by ${m.readers.length}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
    );
  }
}

class AttachmentPreview extends StatefulWidget {
  const AttachmentPreview({
    super.key,
    required this.message,
    required this.controller,
  });
  final ChatMessage message;
  final ChatController controller;
  @override
  State<AttachmentPreview> createState() => _AttachmentPreviewState();
}

class _AttachmentPreviewState extends State<AttachmentPreview> {
  late Future<Uint8List> bytes = widget.controller.client.download(
    widget.message,
  );
  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: bytes,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return TextButton(
          onPressed: () => setState(() {
            bytes = widget.controller.client.download(widget.message);
          }),
          child: const Text('Preview unavailable · Retry'),
        );
      }
      if (!snapshot.hasData) {
        return const SizedBox(
          height: 80,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return Image.memory(
        snapshot.data!,
        height: 160,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const Text('Image preview unavailable'),
      );
    },
  );
}
