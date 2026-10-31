import 'dart:async';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import 'package:monastack/shared/node_request.dart';

/// Local-node administration; all authority and changes are checked by the node.
class RoomMembership extends StatefulWidget {
  const RoomMembership({
    super.key,
    required this.request,
    required this.rooms,
    required this.actors,
  });
  final NodeRequest request;
  final List<Map<String, dynamic>> rooms;
  final List<Map<String, dynamic>> actors;
  @override
  State<RoomMembership> createState() => _RoomMembershipState();
}

class _RoomMembershipState extends State<RoomMembership> {
  String? room, selectedActor, error;
  List<String> members = [];
  List<dynamic> history = [];
  bool canManage = false, loading = false, writing = false;
  int generation = 0;
  int version = 0;
  final accessEpoch = ValueNotifier<int>(0);
  Timer? timer;
  String? pendingRoom, pendingActor, pendingAction, pendingOp;
  int? pendingVersion;

  String actorName(String id) {
    for (final actor in widget.actors) {
      if (actor['id'] == id && actor['name'] is String) {
        return actor['name'] as String;
      }
    }
    return id;
  }

  String roomName(String id) {
    for (final candidate in widget.rooms) {
      if (candidate['id'] == id && candidate['name'] is String) {
        return candidate['name'] as String;
      }
    }
    return id;
  }

  @override
  void initState() {
    super.initState();
    final restricted = widget.rooms
        .where((item) => item['restricted'] == true)
        .toList();
    if (restricted.isNotEmpty) room = restricted.first['id'] as String;
    load();
    timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!loading) load();
    });
  }

  Future<void> load() async {
    final current = ++generation;
    final selected = room;
    setState(() => loading = true);
    try {
      final caps = await widget.request(
        'GET',
        '/v1/room-admin/capabilities',
      ) as Map<String, dynamic>;
      if (caps['can_manage'] != true) {
        if (!mounted || current != generation) return;
        accessEpoch.value++;
        setState(() {
          canManage = false;
          members = [];
          history = [];
          error = 'Room administration access denied.';
        });
        return;
      }
      if (selected == null) {
        if (!mounted || current != generation) return;
        setState(() {
          canManage = true;
          members = [];
          history = [];
          error = null;
        });
        return;
      }
      final encoded = Uri.encodeComponent(selected);
      final result = await Future.wait([
        widget.request('GET', '/v1/room-admin/$encoded/members'),
        widget.request('GET', '/v1/room-admin/$encoded/history'),
      ]);
      if (!mounted || current != generation || room != selected) return;
      final snapshot = result[0] as Map<String, dynamic>;
      final list = (snapshot['members'] as List).cast<String>();
      final newVersion = snapshot['version'] as int;
      if (newVersion < 0) throw const FormatException('Invalid version');
      final events = result[1] as List<dynamic>;
      if (canManage && version != newVersion) accessEpoch.value++;
      setState(() {
        canManage = true;
        version = newVersion;
        members = list;
        history = events;
        error = null;
      });
    } catch (_) {
      if (!mounted || current != generation) return;
      accessEpoch.value++;
      setState(() {
        canManage = false;
        members = [];
        history = [];
        error = 'Room administration unavailable or access denied.';
      });
    } finally {
      if (mounted && current == generation) setState(() => loading = false);
    }
  }

  Future<void> change(String action) async {
    final chosenRoom = room, chosenActor = selectedActor;
    if (!canManage || writing || chosenRoom == null || chosenActor == null) {
      return;
    }
    final epoch = accessEpoch.value, chosenVersion = version;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ValueListenableBuilder<int>(
        valueListenable: accessEpoch,
        builder: (context, current, _) => current != epoch
            ? AlertDialog(
                title: const Text('Room administration access changed'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Close'),
                  ),
                ],
              )
            : AlertDialog(
                title: Text(
                  '${action == 'grant' ? 'Grant' : 'Revoke'} room access?',
                ),
                content: Text(
                  '${actorName(chosenActor)} ($chosenActor) · ${roomName(chosenRoom)} ($chosenRoom)\nThis is an explicit, audited membership change.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Confirm'),
                  ),
                ],
              ),
      ),
    );
    if (confirmed != true ||
        !mounted ||
        epoch != accessEpoch.value ||
        !canManage ||
        room != chosenRoom) {
      return;
    }
    if (pendingRoom != chosenRoom ||
        pendingActor != chosenActor ||
        pendingAction != action ||
        pendingVersion != chosenVersion) {
      pendingRoom = chosenRoom;
      pendingActor = chosenActor;
      pendingAction = action;
      pendingVersion = chosenVersion;
      pendingOp = const Uuid().v4();
    }
    setState(() => writing = true);
    try {
      await widget.request(
        'POST',
        '/v1/room-admin/${Uri.encodeComponent(chosenRoom)}/members',
        {
          'actor': chosenActor,
          'action': action,
          'op': pendingOp,
          'expected_version': chosenVersion,
        },
      );
      pendingOp = pendingRoom = pendingActor = pendingAction = null;
      pendingVersion = null;
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm the change. Refresh and check before retrying.',
        );
      }
    } finally {
      if (mounted) setState(() => writing = false);
    }
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    accessEpoch.value++;
    accessEpoch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 720,
      height: 620,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Room membership',
                    style: TextStyle(fontSize: 22),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh room membership',
                  onPressed: load,
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: 'Close room membership',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Text(
              'Administrator changes are explicit and audited. Administrator status does not itself grant access to room contents.',
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            if (loading) const LinearProgressIndicator(),
            if (canManage) ...[
              DropdownButton<String>(
                isExpanded: true,
                value: room,
                hint: const Text('Restricted room'),
                items: widget.rooms
                    .where((item) => item['restricted'] == true)
                    .map(
                      (item) => DropdownMenuItem(
                        value: item['id'] as String,
                        child: Text(item['name'] as String),
                      ),
                    )
                    .toList(),
                onChanged: writing
                    ? null
                    : (value) {
                        setState(() {
                          room = value;
                          version = 0;
                          members = [];
                          history = [];
                          selectedActor = null;
                        });
                        load();
                      },
              ),
              DropdownButton<String>(
                isExpanded: true,
                value: selectedActor,
                hint: const Text('Choose a human'),
                items: widget.actors
                    .where((item) => item['kind'] == 'human')
                    .map(
                      (item) => DropdownMenuItem(
                        value: item['id'] as String,
                        child: Text(item['name'] as String),
                      ),
                    )
                    .toList(),
                onChanged: writing
                    ? null
                    : (value) => setState(() => selectedActor = value),
              ),
              Row(
                children: [
                  TextButton(
                    onPressed:
                        selectedActor == null ||
                            members.contains(selectedActor) ||
                            writing
                        ? null
                        : () => change('grant'),
                    child: const Text('Grant access'),
                  ),
                  TextButton(
                    onPressed:
                        selectedActor == null ||
                            !members.contains(selectedActor) ||
                            writing
                        ? null
                        : () => change('revoke'),
                    child: const Text('Revoke access'),
                  ),
                ],
              ),
              Text(
                'Current members: ${members.isEmpty ? 'none' : members.map(actorName).join(', ')}',
              ),
              const SizedBox(height: 8),
              const Text('Recent membership changes (latest 200)'),
              Expanded(
                child: ListView.builder(
                  itemCount: history.length,
                  itemBuilder: (context, index) {
                    final event = history[index] as Map<String, dynamic>;
                    return Text(
                      '${event['actor']} · ${event['action']} · ${event['subject']}',
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
