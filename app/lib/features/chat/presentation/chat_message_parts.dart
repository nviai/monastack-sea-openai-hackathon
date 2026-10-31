import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_tokens.dart';
import '../application/chat_controller.dart';
import '../domain/chat_client.dart';
import 'chat_atoms.dart';
import 'chat_format.dart';

MarkdownStyleSheet markdownStyle(NexusTokens nx) {
  final body = nx.text(NexusTokens.t14, height: NexusTokens.lhBody);
  return MarkdownStyleSheet(
    p: body,
    pPadding: EdgeInsets.zero,
    a: body.copyWith(
      color: nx.accentInk,
      decoration: TextDecoration.underline,
      decorationColor: nx.accentInk,
    ),
    strong: body.copyWith(
      fontWeight: FontWeight.w600,
      fontVariations: [FontVariation.weight(NexusTokens.w600)],
    ),
    em: body.copyWith(fontStyle: FontStyle.italic),
    code: nx.monoText(NexusTokens.t125).copyWith(backgroundColor: nx.surface2),
    codeblockPadding: const EdgeInsets.symmetric(
      horizontal: NxSize.codePadH,
      vertical: NxSize.codePadV,
    ),
    codeblockDecoration: BoxDecoration(
      color: nx.surface2,
      border: Border.all(color: nx.line),
      borderRadius: BorderRadius.circular(NexusTokens.rSm),
    ),
    blockquote: body.copyWith(color: nx.ink2),
    blockquoteDecoration: BoxDecoration(
      border: Border(
        left: BorderSide(color: nx.line2, width: NxSpace.s3),
      ),
    ),
    listBullet: body,
    blockSpacing: NxSpace.s6,
  );
}

class MessageBody extends StatelessWidget {
  const MessageBody({
    super.key,
    required this.message,
    required this.controller,
  });
  final ChatMessage message;
  final ChatController controller;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return MarkdownBody(
      data: message.body,
      selectable: true,
      styleSheet: markdownStyle(nx),
      imageBuilder: (uri, title, alt) => Text(alt ?? 'Image link'),
      onTapLink: (_, href, _) async {
        final uri = Uri.tryParse(href ?? '');
        if (uri != null && ['https', 'http', 'mailto'].contains(uri.scheme)) {
          await controller.act(() async {
            if (!await launchUrl(uri)) throw StateError('Link unavailable');
          });
        }
      },
    );
  }
}

class DeletedNote extends StatelessWidget {
  const DeletedNote({super.key});
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Text(
      'Message deleted',
      style: nx.text(NexusTokens.t13, color: nx.ink3, italic: true),
    );
  }
}

/// "↳ Reply to An" above a reply.
class ReplyNote extends StatelessWidget {
  const ReplyNote({super.key, required this.sender});
  final String sender;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Padding(
      padding: const EdgeInsets.only(bottom: NxSpace.s2),
      child: Row(
        children: [
          Icon(
            Icons.subdirectory_arrow_right,
            size: NxSize.iconSm,
            color: nx.ink3,
          ),
          const SizedBox(width: NxSpace.s4),
          Flexible(
            child: Text(
              'Reply to $sender',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: nx.text(NexusTokens.t12, color: nx.ink3),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Not sent · Retry send · Copy" on the failure tint.
class FailedRow extends StatelessWidget {
  const FailedRow({super.key, required this.message, required this.onRetry});
  final ChatMessage message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    final style = nx.text(
      NexusTokens.t12,
      weight: NexusTokens.w560,
      color: nx.now,
    );
    Widget link(String label, VoidCallback onTap) => InkWell(
      onTap: onTap,
      child: Text(
        label,
        style: style.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: nx.now,
        ),
      ),
    );
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(top: NxSpace.s4),
        padding: const EdgeInsets.symmetric(
          horizontal: NxSpace.s8,
          vertical: NxSpace.s2,
        ),
        decoration: BoxDecoration(
          color: nx.failTint(),
          borderRadius: BorderRadius.circular(NexusTokens.rSm),
        ),
        child: Wrap(
          spacing: NxSpace.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Not sent', style: style),
            link('Retry send', onRetry),
            link(
              'Copy',
              () => Clipboard.setData(ClipboardData(text: message.body)),
            ),
          ],
        ),
      ),
    );
  }
}

class ReactionRow extends StatelessWidget {
  const ReactionRow({
    super.key,
    required this.message,
    required this.controller,
  });
  final ChatMessage message;
  final ChatController controller;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Padding(
      padding: const EdgeInsets.only(top: NxSpace.s6),
      child: Wrap(
        spacing: NxSpace.s4,
        runSpacing: NxSpace.s4,
        children: [
          for (final reaction in message.reactions.entries)
            BorderedTap(
              radius: NexusTokens.rPill,
              background: nx.surface,
              onTap: () => controller.act(
                () => controller.client.react(
                  message.roomId,
                  message.id,
                  reaction.key,
                ),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: NxSpace.s6,
                vertical: NxSize.tapPadV,
              ),
              child: Text(
                '${reaction.key} ${reaction.value}',
                style: nx.text(NexusTokens.t12, color: nx.ink2, height: 1),
              ),
            ),
        ],
      ),
    );
  }
}

/// "3 replies · last 13:02" with the repliers' faces; opens the thread.
class ThreadLink extends StatelessWidget {
  const ThreadLink({
    super.key,
    required this.message,
    required this.controller,
  });
  final ChatMessage message;
  final ChatController controller;
  @override
  Widget build(BuildContext context) {
    final replies = controller.client
        .messages(message.roomId)
        .where((e) => e.thread == message.id)
        .toList();
    if (replies.isEmpty) return const SizedBox.shrink();
    final nx = context.nx;
    final last = replies
        .map((e) => e.time)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final radius = BorderRadius.circular(NexusTokens.rCtrl);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: NxSpace.s6),
        child: InkWell(
          onTap: () => controller.openThread(message),
          borderRadius: radius,
          hoverColor: nx.ghostHover(),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              NxSpace.s4,
              NxSpace.s3,
              NxSpace.s8,
              NxSpace.s3,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FaceStack(names: {for (final e in replies) e.sender}.toList()),
                const SizedBox(width: NxSpace.s8),
                Flexible(
                  child: Text.rich(
                    TextSpan(
                      text: repliesLabel(replies.length),
                      style: nx.text(
                        NexusTokens.t125,
                        weight: NexusTokens.w600,
                        color: nx.accent,
                      ),
                      children: [
                        TextSpan(
                          text: ' · last ${clock(last)}',
                          style: nx.text(NexusTokens.t125, color: nx.ink3),
                        ),
                      ],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Seen by" + faces, right-aligned.
class SeenRow extends StatelessWidget {
  const SeenRow({super.key, required this.readers, required this.gutter});
  final List<String> readers;
  final double gutter;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, NxSpace.s2),
      child: Tooltip(
        message: readers.join(', '),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text('Seen by', style: nx.text(NexusTokens.t115, color: nx.ink3)),
            const SizedBox(width: NxSpace.s4),
            FaceStack(names: readers),
          ],
        ),
      ),
    );
  }
}
