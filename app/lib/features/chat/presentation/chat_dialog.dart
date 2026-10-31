import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/chat_controller.dart';
import '../domain/chat_client.dart';
import 'chat_sidebar.dart';
import 'chat_main_pane.dart';
import 'chat_side_pane.dart';

class ChatDialog extends ConsumerStatefulWidget {
  const ChatDialog({
    super.key,
    required this.currentRoom,
    this.enableNotifications,
  });
  final String Function() currentRoom;
  final Future<bool> Function()? enableNotifications;
  @override
  ConsumerState<ChatDialog> createState() => _ChatDialogState();
}

class _ChatDialogState extends ConsumerState<ChatDialog> {
  double width = 1280, height = 760;
  bool expanded = false, sidebar = false;
  final searchFocus = FocusNode();
  ChatController? observed;
  String? previousSelection;
  void selectionChanged() {
    if (observed?.selected != previousSelection) {
      previousSelection = observed?.selected;
      if (mounted && sidebar) setState(() => sidebar = false);
    }
  }

  @override
  void dispose() {
    observed?.removeListener(selectionChanged);
    searchFocus.dispose();
    super.dispose();
  }

  void focusSearch() {
    if (!sidebar) setState(() => sidebar = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) searchFocus.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(chatControllerProvider);
    if (observed != controller) {
      observed?.removeListener(selectionChanged);
      observed = controller..addListener(selectionChanged);
      previousSelection = controller.selected;
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final phase = controller.client.phase;
        final screen = MediaQuery.sizeOf(context);
        final w =
            (expanded
                    ? screen.width - 32
                    : width.clamp(280, (screen.width - 32).clamp(280, 1600)))
                .toDouble();
        final h =
            (expanded
                    ? screen.height - 32
                    : height.clamp(350, (screen.height - 32).clamp(350, 1200)))
                .toDouble();
        final wide = w >= 850;
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
                focusSearch,
            const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
                focusSearch,
            const SingleActivator(LogicalKeyboardKey.keyW, meta: true): () =>
                Navigator.pop(context),
          },
          child: Dialog(
            insetPadding: const EdgeInsets.all(16),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: w,
              height: h,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        if (!wide)
                          IconButton(
                            tooltip: 'Conversations',
                            onPressed: () => setState(() => sidebar = !sidebar),
                            icon: const Icon(Icons.menu),
                          ),
                        const Icon(Icons.forum_outlined, size: 20),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Chat',
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (widget.enableNotifications != null)
                          IconButton(
                            tooltip: 'Enable desktop notifications',
                            onPressed: () async {
                              final allowed =
                                  await widget.enableNotifications!();
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      allowed
                                          ? 'Desktop notifications enabled.'
                                          : 'Notifications are disabled in system settings.',
                                    ),
                                  ),
                                );
                              }
                            },
                            icon: const Icon(Icons.notifications_outlined),
                          ),
                        IconButton(
                          tooltip: expanded
                              ? 'Restore dialog size'
                              : 'Expand chat',
                          onPressed: () => setState(() => expanded = !expanded),
                          icon: Icon(
                            expanded ? Icons.fullscreen_exit : Icons.fullscreen,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close chat',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  if (phase == ChatPhase.reconnecting)
                    MaterialBanner(
                      content: const Text(
                        'Connection lost. Reconnecting… Your drafts are kept.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: controller.client.start,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  if (controller.error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              controller.error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                          if (controller.selected != null)
                            TextButton(
                              onPressed: () =>
                                  controller.select(controller.selected!),
                              child: const Text('Retry conversation'),
                            ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: switch (phase) {
                      ChatPhase.loading => const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 12),
                            Text('Connecting to chat…'),
                          ],
                        ),
                      ),
                      ChatPhase.unavailable => const Center(
                        child: Text('Chat is not available on this server'),
                      ),
                      ChatPhase.signedOut => const Center(
                        child: Text('Sign in to use Chat.'),
                      ),
                      ChatPhase.error => Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'Chat could not connect. Your drafts are kept.',
                            ),
                            TextButton(
                              onPressed: controller.client.start,
                              child: const Text('Retry connection'),
                            ),
                          ],
                        ),
                      ),
                      ChatPhase.ready || ChatPhase.reconnecting => Row(
                        children: [
                          if (wide || sidebar)
                            SizedBox(
                              width: wide ? 235 : w - 1,
                              child: ChatSidebar(
                                controller: controller,
                                searchFocus: searchFocus,
                                currentRoom: widget.currentRoom(),
                              ),
                            ),
                          if (wide || !sidebar)
                            Expanded(
                              child:
                                  controller.pane != SidePane.none && w < 1150
                                  ? ChatSidePane(controller: controller)
                                  : ChatMainPane(controller: controller),
                            ),
                          if (wide &&
                              w >= 1150 &&
                              controller.pane != SidePane.none) ...[
                            const VerticalDivider(width: 1),
                            SizedBox(
                              width: 360,
                              child: ChatSidePane(controller: controller),
                            ),
                          ],
                        ],
                      ),
                    },
                  ),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: GestureDetector(
                      onPanUpdate: expanded
                          ? null
                          : (details) => setState(() {
                              width = (w + details.delta.dx).clamp(
                                600,
                                screen.width - 32,
                              );
                              height = (h + details.delta.dy).clamp(
                                400,
                                screen.height - 32,
                              );
                            }),
                      child: const MouseRegion(
                        cursor: SystemMouseCursors.resizeUpLeftDownRight,
                        child: Padding(
                          padding: EdgeInsets.all(3),
                          child: Icon(Icons.drag_handle, size: 16),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
