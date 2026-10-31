import 'package:flutter/material.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_tokens.dart';
import '../application/chat_controller.dart';
import '../domain/chat_client.dart';
import 'chat_atoms.dart';
import 'chat_composer.dart';
import 'chat_timeline.dart';
import 'chat_title_bar.dart';
import 'legacy_history.dart';

class ChatMainPane extends StatelessWidget {
  const ChatMainPane({super.key, required this.controller});
  final ChatController controller;

  Future<void> earlier(
    BuildContext context,
    ChatRoom room,
  ) => controller.act(() async {
    final scope = await controller.client.legacyScope(room.id);
    if (!context.mounted) return;
    if (scope == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No earlier conversation exists for these members.'),
        ),
      );
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (_) =>
          LegacyHistory(client: controller.client, scope: scope, room: room.id),
    );
  });

  @override
  Widget build(BuildContext context) {
    final room = controller.room;
    if (room == null) {
      return const ChatNote('Choose a conversation to get started.');
    }
    final typing = controller.client.typing(room.id);
    return LayoutBuilder(
      builder: (context, box) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PaneHeader(
            children: [
              Expanded(
                child: _Heading(
                  controller: controller,
                  room: room,
                  width: box.maxWidth,
                ),
              ),
              GhostIconButton(
                tooltip: 'Mark as read',
                onPressed: () =>
                    controller.act(() => controller.client.markRead(room.id)),
                icon: Icons.done_all,
              ),
              GhostIconButton(
                tooltip: 'Room details',
                onPressed: () => controller.side(SidePane.details),
                icon: Icons.info_outline,
              ),
              GhostIconButton(
                tooltip: 'Members',
                onPressed: () => controller.side(SidePane.members),
                icon: Icons.people_outline,
              ),
              GhostIconButton(
                tooltip: 'Earlier messages (before Matrix)',
                onPressed: () => earlier(context, room),
                icon: Icons.history,
              ),
            ],
          ),
          Expanded(
            child: ChatTimeline(controller: controller, room: room.id),
          ),
          if (typing.isNotEmpty) _Typing(names: typing),
          ChatComposer(
            controller: controller,
            room: room.id,
            gutter: NxSpace.s20,
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({
    required this.controller,
    required this.room,
    required this.width,
  });
  final ChatController controller;
  final ChatRoom room;
  final double width;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    final speakers = {
      for (final m in controller.client.messages(room.id)) m.sender,
    }.toList();
    final topic =
        '${room.restricted ? 'Restricted' : 'Open'}${room.topic.isEmpty ? '' : ' · ${room.topic}'}';
    return Row(
      children: [
        Icon(
          room.direct
              ? Icons.people_outline
              : room.restricted
              ? Icons.lock_outline
              : Icons.tag,
          size: NxSize.icon,
          color: nx.ink3,
        ),
        const SizedBox(width: NxSpace.s6),
        Flexible(
          flex: 2,
          child: Text(
            room.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: nx.text(NexusTokens.t15, weight: NexusTokens.w640),
          ),
        ),
        if (width >= NxSize.headerPill) ...[
          const SizedBox(width: NxSpace.s10),
          Flexible(child: _Pill(label: topic)),
        ],
        if (width >= NxSize.headerFaces && speakers.isNotEmpty) ...[
          const SizedBox(width: NxSpace.s10),
          _Faces(names: speakers),
        ],
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: NxSpace.s8,
        vertical: NxSize.pillPadV,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: nx.line),
        borderRadius: BorderRadius.circular(NexusTokens.rPill),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: nx.text(
          NexusTokens.t115,
          weight: NexusTokens.w560,
          color: nx.ink2,
          height: 1,
        ),
      ),
    );
  }
}

/// Who has spoken in the loaded history: faces and a count.
class _Faces extends StatelessWidget {
  const _Faces({required this.names});
  final List<String> names;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        NxSpace.s3,
        NxSize.tapPadV,
        NxSpace.s8,
        NxSize.tapPadV,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: nx.line),
        borderRadius: BorderRadius.circular(NexusTokens.rPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FaceStack(names: names.take(NxSize.faceLimit).toList()),
          const SizedBox(width: NxSpace.s6),
          Text(
            '${names.length}',
            style: nx.text(NexusTokens.t12, color: nx.ink2, height: 1),
          ),
        ],
      ),
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing({required this.names});
  final List<String> names;
  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NxSpace.s20,
        vertical: NxSpace.s2,
      ),
      child: Row(
        children: [
          for (var i = 0; i < NxSize.faceLimit; i++)
            Container(
              width: NxSpace.s4,
              height: NxSpace.s4,
              margin: const EdgeInsets.only(right: NxSpace.s3),
              decoration: BoxDecoration(
                color: nx.ink3.withValues(alpha: NexusTokens.alphaHint),
                shape: BoxShape.circle,
              ),
            ),
          const SizedBox(width: NxSpace.s3),
          Flexible(
            child: Text(
              '${names.join(', ')} typing…',
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
