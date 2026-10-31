import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_tokens.dart';
import '../application/chat_controller.dart';
import '../domain/chat_client.dart';
import 'chat_atoms.dart';

/// File card: saves the attachment when tapped.
class FileCard extends StatelessWidget {
  const FileCard({super.key, required this.message, required this.controller});
  final ChatMessage message;
  final ChatController controller;

  Future<void> save() async {
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
    final nx = context.nx;
    return Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: 'Save file',
        child: BorderedTap(
          onTap: save,
          background: nx.surface,
          padding: const EdgeInsets.fromLTRB(
            NxSpace.s6,
            NxSpace.s6,
            NxSpace.s10,
            NxSpace.s6,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: NxSize.fileIcon,
                height: NxSize.fileIcon,
                decoration: BoxDecoration(
                  color: nx.accentWeak,
                  borderRadius: BorderRadius.circular(NxSize.fileIconRadius),
                ),
                child: Icon(
                  Icons.insert_drive_file_outlined,
                  size: NxSize.icon,
                  color: nx.accentInk,
                ),
              ),
              const SizedBox(width: NxSpace.s10),
              Flexible(
                child: Text(
                  message.body,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: nx.text(NexusTokens.t13, weight: NexusTokens.w600),
                ),
              ),
              const SizedBox(width: NxSpace.s8),
              Icon(Icons.download_outlined, size: NxSize.icon, color: nx.ink3),
            ],
          ),
        ),
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
        return Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => setState(() {
              bytes = widget.controller.client.download(widget.message);
            }),
            child: const Text('Preview unavailable · Retry'),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const SizedBox(
          height: NxSize.previewHeight,
          child: Center(child: ChatSpinner()),
        );
      }
      return Align(
        alignment: Alignment.centerLeft,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(NexusTokens.rCtrl),
          child: Image.memory(
            snapshot.data!,
            height: NxSize.imageHeight,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Text('Image preview unavailable'),
          ),
        ),
      );
    },
  );
}
