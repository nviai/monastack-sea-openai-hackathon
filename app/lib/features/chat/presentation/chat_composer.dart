import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/chat_controller.dart';

class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.room,
    this.thread,
  });
  final ChatController controller;
  final String room;
  final String? thread;
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
              child: Text(p.name),
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

  void send() {
    widget.controller.send(widget.room, root: widget.thread);
    focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final canPost = widget.controller.client.rooms.any(
      (r) => r.id == widget.room && r.canPost,
    );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (draft.reply != null || draft.edit != null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    draft.edit != null
                        ? 'Editing message'
                        : 'Replying to a message',
                  ),
                ),
                IconButton(
                  tooltip: 'Cancel reply or edit',
                  onPressed: () => widget.controller.cancelMode(
                    widget.room,
                    root: widget.thread,
                  ),
                  icon: const Icon(Icons.close, size: 16),
                ),
              ],
            ),
          Focus(
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.enter &&
                  HardwareKeyboard.instance.isShiftPressed) {
                final selection = text.selection;
                final start = selection.isValid
                    ? selection.start
                    : text.text.length;
                final end = selection.isValid
                    ? selection.end
                    : text.text.length;
                text.value = TextEditingValue(
                  text: text.text.replaceRange(start, end, '\n'),
                  selection: TextSelection.collapsed(offset: start + 1),
                );
                widget.controller.text(
                  widget.room,
                  text.text,
                  root: widget.thread,
                );
                return KeyEventResult.handled;
              }
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.enter &&
                  !HardwareKeyboard.instance.isShiftPressed &&
                  text.value.composing.isCollapsed) {
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
            },
            child: TextField(
              key: ValueKey('composer-${widget.thread ?? 'main'}'),
              controller: text,
              focusNode: focus,
              enabled: canPost,
              minLines: 2,
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: canPost
                    ? 'Write a message'
                    : 'You cannot post in this conversation',
              ),
              onChanged: (value) => widget.controller.text(
                widget.room,
                value,
                root: widget.thread,
              ),
            ),
          ),
          Row(
            children: [
              IconButton(
                tooltip: 'Attach file or image',
                onPressed: canPost ? attach : null,
                icon: const Icon(Icons.attach_file),
              ),
              IconButton(
                tooltip: 'Mention a person',
                onPressed: canPost ? mention : null,
                icon: const Icon(Icons.alternate_email),
              ),
              const Expanded(
                child: Text(
                  'Enter to send · Shift+Enter for a newline',
                  style: TextStyle(fontSize: 11),
                ),
              ),
              IconButton(
                tooltip: 'Send message',
                onPressed: canPost ? send : null,
                icon: const Icon(Icons.send_outlined),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
