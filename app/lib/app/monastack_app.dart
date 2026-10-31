import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:monastack/features/office/communication/collaboration.dart';
import 'package:monastack/features/office/world/office_world.dart';
import 'package:monastack/features/organization/people_profiles.dart';
import 'package:monastack/features/office/data/office_core.dart';
import 'package:monastack/platform/core_bridge.dart';
import 'package:monastack/shared/brand/monastack_logo.dart';

final seedProvider = FutureProvider<Map<String, dynamic>>(
  (ref) async =>
      jsonDecode(await rootBundle.loadString('assets/seed.v1.json'))
          as Map<String, dynamic>,
);

class Monastack extends StatelessWidget {
  const Monastack({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Monastack',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff69766b),
        surface: const Color(0xfff7f5ef),
      ),
    ),
    home: const Office(),
  );
}

class Office extends ConsumerStatefulWidget {
  const Office({super.key});
  @override
  ConsumerState<Office> createState() => _OfficeState();
}

class _OfficeState extends ConsumerState<Office> {
  String actor = '';
  String? connectedActor;

  /// Company name of the signed-in workspace; the seed's name otherwise.
  String? workspaceName;
  List<String>? serverRooms;
  String room = 'lobby';
  String? notice;
  final collaborationKey = GlobalKey<CollaborationState>();
  final worldKey = GlobalKey<OfficeWorldState>();

  /// Unknown until the office map loads and reports the spawn cell; presence
  /// is not published for an unknown position.
  final position = ValueNotifier<List<int>>(const [-1, -1]);
  final remote = ValueNotifier<List<Map<String, dynamic>>>([]);
  final agentPresentation = ValueNotifier<Map<String, dynamic>>({});
  final onlineAgents = ValueNotifier<Set<String>>(const {});
  final audioLevels = ValueNotifier<Map<String, double>>(const {});
  final speaking = ValueNotifier<Set<String>>(const {});
  final faces = ValueNotifier<Map<String, Widget>>(const {});
  @override
  void dispose() {
    position.dispose();
    remote.dispose();
    agentPresentation.dispose();
    onlineAgents.dispose();
    audioLevels.dispose();
    speaking.dispose();
    faces.dispose();
    super.dispose();
  }

  void enter(Map<String, dynamic> seed, Map<String, dynamic> target) {
    if (connectedActor == null) return;
    try {
      final allowed = serverRooms?.contains(target['id']) ?? false;
      if (!allowed) {
        setState(
          () => notice =
              'Access denied to ${target['name']}. Membership is required.',
        );
        return;
      }
      worldKey.currentState?.goToRoom(target['id'] as String);
      setState(() => notice = null);
    } catch (_) {
      setState(
        () => notice =
            'Rust core unavailable. Rebuild the app; access is denied.',
      );
    }
  }

  /// Movement uses the authenticated node's current room permissions.
  Future<List<List<int>>?> findPath(List<int> start, List<int> goal) async {
    if (connectedActor == null) return null;
    final core = await ref.read(officeCoreProvider.future);
    try {
      final route = await core.findPath(
        actor: actor,
        start: Cell(x: start[0], y: start[1]),
        goal: Cell(x: goal[0], y: goal[1]),
        allowedRooms: serverRooms ?? [],
      );
      return [
        for (final cell in route) [cell.x, cell.y],
      ];
    } on CoreError catch (e) {
      if (e.kind == CoreErrorKind.inaccessible) return null;
      rethrow;
    }
  }

  /// The node supplies room access after sign-in; no preview permissions.
  Set<String> accessibleRooms(List<Map<String, dynamic>> rooms) => {
    ...?serverRooms,
  };

  String? locateRoom(List<int> cell) => ref
      .read(officeCoreProvider)
      .value
      ?.roomAt(
        cell: Cell(x: cell[0], y: cell[1]),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ref
        .watch(seedProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, s) => Center(child: Text('Could not load seed: $e')),
          data: (data) {
            final rooms = (data['rooms'] as List).cast<Map<String, dynamic>>();
            final actors = (data['actors'] as List)
                .cast<Map<String, dynamic>>();
            final collaboration = Collaboration(
              key: collaborationKey,
              room: room,
              position: position,
              remote: remote,
              actors: actors,
              rooms: rooms,
              speaking: speaking,
              audioLevels: audioLevels,
              onlineAgents: onlineAgents,
              agentPresentation: agentPresentation,
              faces: faces,
              company: (data['workspace'] as Map?)?['name'] as String? ?? '',
              onWorkspaceName: (name) {
                if (name != workspaceName && mounted) {
                  setState(() => workspaceName = name);
                }
              },
              onPermissions: (rooms) {
                if (serverRooms != null &&
                    serverRooms!.length == rooms.length &&
                    serverRooms!.every(rooms.contains)) {
                  return;
                }
                final shouldReset = !rooms.contains(room);
                worldKey.currentState?.policyChanged(reset: shouldReset);
                setState(() {
                  serverRooms = List.of(rooms);
                  if (shouldReset) {
                    room = 'lobby';
                    notice = 'Room access changed or the node is unavailable.';
                  }
                });
              },
              onIdentity: (id) {
                setState(() {
                  connectedActor = id;
                  serverRooms = id == null ? null : [];
                  actor = id ?? '';
                  room = 'lobby';
                  if (id == null) position.value = const [-1, -1];
                });
              },
            );
            if (connectedActor == null) {
              return SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: SizedBox(
                      width: 420,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Center(child: MonastackLogo(size: 56)),
                              const SizedBox(height: 16),
                              const Text(
                                'Welcome to Monastack',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 24),
                              collaboration,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }
            final selected = rooms.firstWhere((r) => r['id'] == room);
            final banner =
                notice ??
                (ref.watch(officeCoreProvider).hasError
                    ? 'Rust core unavailable. Rebuild the app; movement and room entry are denied.'
                    : null);
            return SafeArea(
              child: Row(
                children: [
                  Container(
                    width: 240,
                    padding: const EdgeInsets.fromLTRB(22, 25, 18, 18),
                    color: const Color(0xff253d38),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            MonastackLogo(size: 34),
                            SizedBox(width: 8),
                            Text(
                              'MONASTACK',
                              style: TextStyle(
                                color: Color(0xffd4e5ce),
                                letterSpacing: 3,
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Your office,\ntogether.',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 25,
                            height: 1.2,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 28),
                        const Text(
                          'WORKSPACE',
                          style: TextStyle(
                            color: Color(0xffa9c4b7),
                            fontSize: 11,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 9),
                        Text(
                          workspaceName ??
                              (data['workspace'] as Map?)?['name'] as String? ??
                              '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 26),
                        const Text(
                          'ROOMS',
                          style: TextStyle(
                            color: Color(0xffa9c4b7),
                            fontSize: 11,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: ListView(
                            children: rooms
                                .map(
                                  (r) => Material(
                                    color: Colors.transparent,
                                    child: ListTile(
                                      dense: true,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      selected: r['id'] == room,
                                      selectedTileColor: const Color(
                                        0xff46635a,
                                      ),
                                      leading: Icon(
                                        r['restricted'] == true
                                            ? Icons.lock_outline
                                            : Icons.meeting_room_outlined,
                                        color: const Color(0xffc9d9ce),
                                        size: 19,
                                      ),
                                      title: Text(
                                        r['name'] as String,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                        ),
                                      ),
                                      trailing: ValueListenableBuilder(
                                        valueListenable: remote,
                                        builder: (context, presence, _) {
                                          final count = presence
                                              .where(
                                                (p) => p['room'] == r['id'],
                                              )
                                              .length;
                                          return count == 0
                                              ? const SizedBox.shrink()
                                              : Text(
                                                  '$count',
                                                  semanticsLabel:
                                                      '$count visible',
                                                  style: const TextStyle(
                                                    color: Color(0xffc9d9ce),
                                                    fontSize: 12,
                                                  ),
                                                );
                                        },
                                      ),
                                      onTap: () => enter(data, r),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                        const Text(
                          'WORKSPACE SESSION',
                          style: TextStyle(
                            color: Color(0xffa9c4b7),
                            fontSize: 11,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 5),
                        const Text(
                          'Signed in',
                          style: TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(28, 22, 28, 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'NVIAI / OFFICE',
                                      style: TextStyle(
                                        fontSize: 11,
                                        letterSpacing: 1.6,
                                        color: Color(0xff71847a),
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      selected['name'] as String,
                                      style: const TextStyle(
                                        fontSize: 27,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (banner != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 28),
                            child: MaterialBanner(
                              content: Text(banner),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      setState(() => notice = null),
                                  child: const Text('Dismiss'),
                                ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: OfficeWorld(
                                key: worldKey,
                                onWorkspaceTools: () => collaborationKey
                                    .currentState
                                    ?.openWorkspaceTools(),
                                seed: data,
                                remote: remote,
                                actor: actor,
                                findPath: (start, goal) =>
                                    findPath(start, goal),
                                locateRoom: locateRoom,
                                speaking: speaking,
                                audioLevels: audioLevels,
                                onlineAgents: onlineAgents,
                                agentPresentation: agentPresentation,
                                faces: faces,
                                accessibleRooms: accessibleRooms(rooms),
                                onSelectActor: (id) {
                                  final profile = actors
                                      .where((a) => a['id'] == id)
                                      .firstOrNull;
                                  if (profile != null) {
                                    showActorProfile(
                                      context,
                                      profile,
                                      onChatAgent: (id) => collaborationKey
                                          .currentState
                                          ?.openAgentChat(id),
                                    );
                                  }
                                },
                                onPosition: (p, nextRoom) {
                                  position.value = p;
                                  if (nextRoom != room && mounted) {
                                    setState(() => room = nextRoom);
                                  }
                                },
                                onError: (message) {
                                  if (mounted) setState(() => notice = message);
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    width: 270,
                    padding: const EdgeInsets.all(22),
                    decoration: const BoxDecoration(
                      color: Color(0xfffcfbf7),
                      border: Border(
                        left: BorderSide(color: Color(0xffe8e8e0)),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'People & agents',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          connectedActor == null
                              ? 'Seeded profiles · connect to see online avatars'
                              : 'Seeded profiles · online avatars appear in the office',
                          style: const TextStyle(
                            color: Colors.black54,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Expanded(
                          child: PeopleProfiles(
                            actors: actors,
                            remote: remote,
                            connectedActor: connectedActor,
                            onChatAgent: (id) => collaborationKey.currentState
                                ?.openAgentChat(id),
                          ),
                        ),
                        const Divider(),
                        collaboration,
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
  );
}
