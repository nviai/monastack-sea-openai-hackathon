import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'package:monastack/shared/node_request.dart';

class Whiteboard extends ConsumerStatefulWidget {
  const Whiteboard({super.key, required this.request, required this.rooms});
  final NodeRequest request;
  final List<Map<String, dynamic>> rooms;
  @override
  ConsumerState<Whiteboard> createState() => _WhiteboardState();
}

class _WhiteboardState extends ConsumerState<Whiteboard> {
  String scope = 'workspace';
  List<dynamic> notes = [];
  String? error;
  Timer? timer;
  int serial = 0;
  final boardKey = GlobalKey();
  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    final current = scope, requestNumber = ++serial;
    try {
      final result = await widget.request(
        'GET',
        '/v1/whiteboard/notes?scope=${Uri.encodeQueryComponent(current)}',
      ) as List<dynamic>;
      if (mounted && current == scope && requestNumber == serial) {
        setState(() {
          notes = result;
          error = null;
        });
      }
    } catch (_) {
      if (mounted && current == scope && requestNumber == serial) {
        setState(() {
          notes = [];
          error = 'Board unavailable or room access denied.';
        });
      }
    }
  }

  Future<void> edit([Map<String, dynamic>? note]) async {
    final originalScope = scope;
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _NoteForm(note: note),
    );
    if (data == null || originalScope != scope) return;
    try {
      if (note == null) {
        await widget.request('POST', '/v1/whiteboard/notes', {
          'id': const Uuid().v4(),
          'op': const Uuid().v4(),
          'scope': scope,
          ...data,
        });
      } else {
        await widget.request(
          'POST',
          '/v1/whiteboard/notes/${Uri.encodeComponent(note['id'] as String)}',
          {
            'op': const Uuid().v4(),
            'expected_version': note['version'],
            'delete': false,
            ...data,
          },
        );
      }
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm the change. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> move(Map<String, dynamic> note, int x, int y) async {
    try {
      await widget.request(
        'POST',
        '/v1/whiteboard/notes/${Uri.encodeComponent(note['id'] as String)}',
        {
          'text': note['text'],
          'x': x,
          'y': y,
          'delete': false,
          'expected_version': note['version'],
          'op': const Uuid().v4(),
        },
      );
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not confirm the move. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> remove(Map<String, dynamic> note) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete note?'),
        content: const Text(
          'The note is removed from the board; its audit history remains.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await widget.request(
        'POST',
        '/v1/whiteboard/notes/${Uri.encodeComponent(note['id'] as String)}',
        {
          'delete': true,
          'expected_version': note['version'],
          'op': const Uuid().v4(),
        },
      );
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'Could not confirm deletion. Refresh and check before retrying.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 820,
      height: 650,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Whiteboard',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  onPressed: load,
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Text(
              'Shared notes refresh every five seconds. Room access applies; content is stored on the node.',
              style: TextStyle(color: Colors.black54),
            ),
            Row(
              children: [
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: scope,
                    items: [
                      const DropdownMenuItem(
                        value: 'workspace',
                        child: Text('Workspace'),
                      ),
                      ...widget.rooms.map(
                        (r) => DropdownMenuItem(
                          value: 'room:${r['id']}',
                          child: Text('${r['name']} room'),
                        ),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null && value != scope) {
                        setState(() {
                          scope = value;
                          notes = [];
                          error = null;
                        });
                        load();
                      }
                    },
                  ),
                ),
                TextButton.icon(
                  onPressed: () => edit(),
                  icon: const Icon(Icons.add),
                  label: const Text('Note'),
                ),
              ],
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const cardWidth = 145.0, cardHeight = 85.0;
                  final width = (constraints.maxWidth - cardWidth).clamp(
                        1.0,
                        double.infinity,
                      ),
                      height = (constraints.maxHeight - cardHeight).clamp(
                        1.0,
                        double.infinity,
                      );
                  return Container(
                    key: boardKey,
                    decoration: BoxDecoration(
                      color: const Color(0xffe8eee9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Stack(
                      clipBehavior: Clip.hardEdge,
                      children: notes.map((v) {
                        final note = v as Map<String, dynamic>;
                        Widget card() => Material(
                          color: const Color(0xffffefb8),
                          borderRadius: BorderRadius.circular(8),
                          elevation: 2,
                          child: SizedBox(
                            width: cardWidth,
                            height: cardHeight,
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                note['text'] as String,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        );
                        return Positioned(
                          left: width * (note['x'] as int) / 1000,
                          top: height * (note['y'] as int) / 1000,
                          child: Draggable<String>(
                            data: note['id'] as String,
                            feedback: card(),
                            childWhenDragging: Opacity(
                              opacity: .4,
                              child: card(),
                            ),
                            onDragEnd: (details) {
                              final box =
                                  boardKey.currentContext?.findRenderObject()
                                      as RenderBox?;
                              if (box == null) return;
                              final local = box.globalToLocal(details.offset);
                              move(
                                note,
                                ((local.dx / width) * 1000).round().clamp(
                                  0,
                                  1000,
                                ),
                                ((local.dy / height) * 1000).round().clamp(
                                  0,
                                  1000,
                                ),
                              );
                            },
                            child: card(),
                          ),
                        );
                      }).toList(),
                    ),
                  );
                },
              ),
            ),
            const Text(
              'Drag notes to move them, or use the edit controls below.',
            ),
            SizedBox(
              height: 105,
              child: ListView(
                children: notes.map((v) {
                  final note = v as Map<String, dynamic>;
                  return ListTile(
                    dense: true,
                    title: Text(
                      note['text'] as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text('${note['x']}, ${note['y']}'),
                    trailing: Wrap(
                      children: [
                        TextButton(
                          onPressed: () => edit(note),
                          child: const Text('Edit note'),
                        ),
                        TextButton(
                          onPressed: () => remove(note),
                          child: const Text('Delete note'),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _NoteForm extends StatefulWidget {
  const _NoteForm({this.note});
  final Map<String, dynamic>? note;
  @override
  State<_NoteForm> createState() => _NoteFormState();
}

class _NoteFormState extends State<_NoteForm> {
  late final TextEditingController text, x, y;
  String? error;
  @override
  void initState() {
    super.initState();
    text = TextEditingController(text: widget.note?['text'] as String?);
    x = TextEditingController(text: '${widget.note?['x'] ?? 100}');
    y = TextEditingController(text: '${widget.note?['y'] ?? 100}');
  }

  @override
  void dispose() {
    text.dispose();
    x.dispose();
    y.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.note == null ? 'New note' : 'Edit note'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: text,
            maxLength: 500,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Note text'),
          ),
          TextField(
            controller: x,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Horizontal position (0–1000)',
            ),
          ),
          TextField(
            controller: y,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Vertical position (0–1000)',
            ),
          ),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          final xx = int.tryParse(x.text), yy = int.tryParse(y.text);
          if (text.text.trim().isEmpty ||
              xx == null ||
              yy == null ||
              xx < 0 ||
              xx > 1000 ||
              yy < 0 ||
              yy > 1000) {
            setState(
              () => error = 'Enter note text and positions from 0 to 1000.',
            );
            return;
          }
          Navigator.pop(context, {'text': text.text.trim(), 'x': xx, 'y': yy});
        },
        child: const Text('Save'),
      ),
    ],
  );
}
