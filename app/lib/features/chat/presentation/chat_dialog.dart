import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_theme.dart';
import '../../../shared/nexus_tokens.dart';
import '../application/chat_controller.dart';
import '../domain/chat_client.dart';
import 'chat_atoms.dart';
import 'chat_main_pane.dart';
import 'chat_side_pane.dart';
import 'chat_sidebar.dart';
import 'chat_title_bar.dart';

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
  double width = NxSize.dialogW, height = NxSize.dialogH;
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

  Future<void> enableDesktopNotifications(BuildContext context) async {
    final allowed = await widget.enableNotifications!();
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
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(chatControllerProvider);
    if (observed != controller) {
      observed?.removeListener(selectionChanged);
      observed = controller..addListener(selectionChanged);
      previousSelection = controller.selected;
    }
    return NexusTheme(
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => _frame(context, controller),
      ),
    );
  }

  Widget _frame(BuildContext context, ChatController controller) {
    final nx = context.nx;
    final phase = controller.client.phase;
    final screen = MediaQuery.sizeOf(context);
    const inset = NxSize.dialogInset * 2;
    final w =
        (expanded
                ? screen.width - inset
                : width.clamp(
                    NxSize.dialogMinW,
                    (screen.width - inset).clamp(
                      NxSize.dialogMinW,
                      NxSize.dialogMaxW,
                    ),
                  ))
            .toDouble();
    final h =
        (expanded
                ? screen.height - inset
                : height.clamp(
                    NxSize.dialogMinH,
                    (screen.height - inset).clamp(
                      NxSize.dialogMinH,
                      NxSize.dialogMaxH,
                    ),
                  ))
            .toDouble();
    final wide = w >= NxSize.wide;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyW, meta: true): () =>
            Navigator.pop(context),
      },
      child: Dialog(
        insetPadding: const EdgeInsets.all(NxSize.dialogInset),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: w,
          height: h,
          child: Column(
            children: [
              ChatTitleBar(
                showMenu: !wide,
                onMenu: () => setState(() => sidebar = !sidebar),
                expanded: expanded,
                onExpand: () => setState(() => expanded = !expanded),
                onClose: () => Navigator.pop(context),
                onNotifications: widget.enableNotifications == null
                    ? null
                    : () => enableDesktopNotifications(context),
              ),
              if (phase == ChatPhase.reconnecting)
                ChatBanner(
                  message:
                      'Connection lost. Reconnecting… Your drafts are kept.',
                  action: TextButton(
                    onPressed: controller.client.start,
                    child: const Text('Retry'),
                  ),
                ),
              if (controller.error != null)
                ChatBanner(
                  message: controller.error!,
                  action: controller.selected == null
                      ? null
                      : TextButton(
                          onPressed: () =>
                              controller.select(controller.selected!),
                          child: const Text('Retry conversation'),
                        ),
                ),
              Expanded(child: _body(controller, phase, wide, w)),
              if (!expanded) _resizeHandle(nx, w, h, screen),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(
    ChatController controller,
    ChatPhase phase,
    bool wide,
    double w,
  ) {
    final side = controller.pane != SidePane.none;
    final inline = wide && w >= NxSize.sideInline && side;
    return switch (phase) {
      ChatPhase.loading => const ChatNote('Connecting to chat…', spinner: true),
      ChatPhase.unavailable => const ChatNote(
        'Chat is not available on this server',
      ),
      ChatPhase.signedOut => const ChatNote('Sign in to use Chat.'),
      ChatPhase.error => ChatNote(
        'Chat could not connect. Your drafts are kept.',
        action: TextButton(
          onPressed: controller.client.start,
          child: const Text('Retry connection'),
        ),
      ),
      ChatPhase.ready || ChatPhase.reconnecting => Row(
        children: [
          if (wide)
            SizedBox(width: NxSize.sidebar, child: _sidebar(controller, true))
          else if (sidebar)
            Expanded(child: _sidebar(controller, false)),
          if (wide || !sidebar)
            Expanded(
              child: side && !inline
                  ? ChatSidePane(controller: controller)
                  : ChatMainPane(controller: controller),
            ),
          if (inline)
            SizedBox(
              width: NxSize.thread,
              child: ChatSidePane(controller: controller, inline: true),
            ),
        ],
      ),
    };
  }

  Widget _sidebar(ChatController controller, bool divider) => ChatSidebar(
    controller: controller,
    searchFocus: searchFocus,
    currentRoom: widget.currentRoom(),
    divider: divider,
  );

  Widget _resizeHandle(NexusTokens nx, double w, double h, Size screen) =>
      Align(
        alignment: Alignment.bottomRight,
        child: GestureDetector(
          onPanUpdate: (details) => setState(() {
            width = (w + details.delta.dx).clamp(
              NxSize.resizeMinW,
              screen.width - NxSize.dialogInset * 2,
            );
            height = (h + details.delta.dy).clamp(
              NxSize.resizeMinH,
              screen.height - NxSize.dialogInset * 2,
            );
          }),
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeUpLeftDownRight,
            child: Padding(
              padding: const EdgeInsets.all(NxSize.handlePad),
              child: Icon(
                Icons.drag_handle,
                size: NxSize.handleSize,
                color: nx.ink3,
              ),
            ),
          ),
        ),
      );
}
