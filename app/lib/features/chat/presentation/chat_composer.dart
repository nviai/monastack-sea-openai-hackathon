import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/nexus_metrics.dart';
import '../../../shared/nexus_tokens.dart';
import '../application/chat_controller.dart';
import 'chat_atoms.dart';

class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.room,
    this.thread,
    this.gutter = NxSpace.s16,
  });
  final ChatController controller;
  final String room;
  final String? thread;

  /// Outer margin, equal to the timeline's horizontal padding above.
  final double gutter;
  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  final text = TextEditingController();
  final focus = FocusNode();
  ChatDraft get draft => widget.controller.draft(widget.room, widget.thread);
  @override
  void initState() {
    super.initState();
    sync();
    widget.controller.addListener(sync);
  }

  void sync() {
    if (text.text != draft.text) {
      text.value = TextEditingValue(
        text: draft.text,
        selection: TextSelection.collapsed(offset: draft.text.length),
      );
    }
  }

  @override
  void didUpdateWidget(ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(sync);
      widget.controller.addListener(sync);
    }
    sync();
  }

  @override
  void dispose() {
    widget.controller.removeListener(sync);
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  Future<void> attach() async {
    try {
      final file = await openFile();
      if (file == null || !mounted) return;
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      await widget.controller.attach(
        widget.room,
        file.name,
        bytes,
        root: widget.thread,
      );
    } catch (_) {
      widget.controller.act(() async => throw StateError('File unavailable'));
    }
  }

  Future<void> mention() async {
    final person = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Mention a person'),
        children: [
          for (final p in widget.controller.client.people)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, '${p.id} '),
              child: Row(
                children: [
                  NexusAvatar(
                    name: p.name,
                    size: NxSize.avatarSm,
                    radius: NxSize.avatarSmRadius,
                    fontSize: NexusTokens.t10,
                  ),
                  const SizedBox(width: NxSpace.s10),
                  Flexible(child: Text(p.name)),
                ],
              ),
            ),
        ],
      ),
    );
    if (person == null || !mounted) return;
    final offset = text.selection.isValid
        ? text.selection.baseOffset
        : text.text.length;
    text.text = text.text.replaceRange(offset, offset, person);
    widget.controller.text(widget.room, text.text, root: widget.thread);
    focus.requestFocus();
  }

  /// Wraps the selection (or the caret) in a Markdown marker.
  void wrap(String marker) {
    final selection = text.selection;
    final start = selection.isValid ? selection.start : text.text.length;
    final end = selection.isValid ? selection.end : text.text.length;
    final inner = text.text.substring(start, end);
    text.value = TextEditingValue(
      text: text.text.replaceRange(start, end, '$marker$inner$marker'),
      selection: TextSelection.collapsed(
        offset: inner.isEmpty ? start + marker.length : end + marker.length * 2,
      ),
    );
    widget.controller.text(widget.room, text.text, root: widget.thread);
    focus.requestFocus();
  }

  void send() {
    widget.controller.send(widget.room, root: widget.thread);
    focus.requestFocus();
  }

  KeyEventResult onKey(FocusNode node, KeyEvent event, bool canPost) {
    final enter =
        event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (enter && shift) {
      final selection = text.selection;
      final start = selection.isValid ? selection.start : text.text.length;
      final end = selection.isValid ? selection.end : text.text.length;
      text.value = TextEditingValue(
        text: text.text.replaceRange(start, end, '\n'),
        selection: TextSelection.collapsed(offset: start + 1),
      );
      widget.controller.text(widget.room, text.text, root: widget.thread);
      return KeyEventResult.handled;
    }
    if (enter && !shift && text.value.composing.isCollapsed) {
      if (canPost) send();
      return KeyEventResult.handled;
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        (draft.reply != null || draft.edit != null)) {
      widget.controller.cancelMode(widget.room, root: widget.thread);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final nx = context.nx;
    final canPost = widget.controller.client.rooms.any(
      (r) => r.id == widget.room && r.canPost,
    );
    final inThread = widget.thread != null;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        widget.gutter,
        NxSpace.s6,
        widget.gutter,
        NxSize.composerBottom,
      ),
      child: FocusFrame(
        radius: NexusTokens.rCard,
        resting: nx.line2,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(
            NexusTokens.rCard - NxSize.hairline,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (draft.reply != null || draft.edit != null) _modeBar(nx),
              Focus(
                onKeyEvent: (node, event) => onKey(node, event, canPost),
                child: TextField(
                  key: ValueKey('composer-${widget.thread ?? 'main'}'),
                  controller: text,
                  focusNode: focus,
                  enabled: canPost,
                  minLines: 1,
                  maxLines: NxSize.composerMaxLines,
                  keyboardType: TextInputType.multiline,
                  style: nx.text(NexusTokens.t14, height: NexusTokens.lhBody),
                  cursorColor: nx.accent,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: NxSpace.s12,
                      vertical: NxSpace.s10,
                    ),
                    hintText: canPost
                        ? (inThread ? 'Reply in thread…' : 'Write a message')
                        : 'You cannot post in this conversation',
                    hintStyle: nx.text(
                      NexusTokens.t14,
                      color: nx.ink3,
                      height: NexusTokens.lhBody,
                    ),
                  ),
                  onChanged: (value) => widget.controller.text(
                    widget.room,
                    value,
                    root: widget.thread,
                  ),
                ),
              ),
              _toolbar(nx, canPost, inThread),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeBar(NexusTokens nx) => Container(
    padding: const EdgeInsets.only(
      left: NxSpace.s10,
      top: NxSize.composerReplyPad,
      bottom: NxSize.composerReplyPad,
      right: NxSpace.s4,
    ),
    decoration: BoxDecoration(
      color: nx.surface2,
      border: Border(bottom: BorderSide(color: nx.line)),
    ),
    child: Row(
      children: [
        Icon(
          draft.edit != null ? Icons.edit_outlined : Icons.reply,
          size: NxSize.iconSm,
          color: nx.ink3,
        ),
        const SizedBox(width: NxSpace.s8),
        Expanded(
          child: Text(
            draft.edit != null ? 'Editing message' : 'Replying to a message',
            style: nx.text(NexusTokens.t12, color: nx.ink2),
          ),
        ),
        GhostIconButton(
          tooltip: 'Cancel reply or edit',
          size: NxSize.ctrlSm,
          icon: Icons.close,
          onPressed: () =>
              widget.controller.cancelMode(widget.room, root: widget.thread),
        ),
      ],
    ),
  );

  Widget _toolbar(NexusTokens nx, bool canPost, bool inThread) => Padding(
    padding: const EdgeInsets.fromLTRB(
      NxSpace.s6,
      NxSpace.s4,
      NxSpace.s6,
      NxSpace.s6,
    ),
    child: LayoutBuilder(
      builder: (context, box) => Row(
        children: [
          GhostIconButton(
            tooltip: 'Attach file or image',
            onPressed: canPost ? attach : null,
            icon: Icons.attach_file,
          ),
          GhostIconButton(
            tooltip: 'Mention a person',
            onPressed: canPost ? mention : null,
            icon: Icons.alternate_email,
          ),
          if (!inThread) ...[
            GhostIconButton(
              tooltip: 'Bold',
              onPressed: canPost ? () => wrap('**') : null,
              icon: Icons.format_bold,
            ),
            GhostIconButton(
              tooltip: 'Code',
              onPressed: canPost ? () => wrap('`') : null,
              icon: Icons.code,
            ),
          ],
          Expanded(
            child: box.maxWidth >= NxSize.composerHint && !inThread
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: NxSpace.s8),
                    child: Text(
                      'Enter to send · Shift+Enter for a newline',
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: nx.text(NexusTokens.t115, color: nx.ink3),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          Tooltip(
            message: 'Send message',
            child: FilledButton(
              onPressed: canPost ? send : null,
              child: const Text('Send'),
            ),
          ),
        ],
      ),
    ),
  );
}
