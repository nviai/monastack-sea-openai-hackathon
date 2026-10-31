import 'package:monastack/features/office/world/agent_speech_layer.dart';

import 'dart:convert';

import 'package:flame/game.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'package:monastack/features/office/world/office_map.dart';
import 'package:monastack/features/office/world/office_scene.dart';
import 'package:monastack/features/office/world/world_game.dart';

/// Resolves a walkable route including both ends, or `null` when the goal is
/// blocked or requires membership. Throws when the map service is unavailable.
typedef RouteFinder = Future<List<List<int>>?> Function(
  List<int> start,
  List<int> goal,
);

/// Room containing a cell according to the Rust core; `null` for corridors.
typedef RoomLocator = String? Function(List<int> cell);

/// Room that corridor positions are reported in. Corridors are shared space
/// with the lobby's chat and access policy.
const corridorRoom = 'lobby';

class OfficeWorld extends StatefulWidget {
  const OfficeWorld({
    super.key,
    required this.seed,
    required this.remote,
    required this.actor,
    required this.findPath,
    required this.onPosition,
    required this.onError,
    this.locateRoom,
    this.accessibleRooms,
    this.onSelectActor,
    this.speaking,
    this.audioLevels,
    this.onlineAgents,
    this.agentPresentation,
    this.faces,
    this.onWorkspaceTools,
  });
  final VoidCallback? onWorkspaceTools;
  final Map<String, dynamic> seed;
  final ValueNotifier<List<Map<String, dynamic>>> remote;
  final String actor;
  final RouteFinder findPath;
  final RoomLocator? locateRoom;
  final void Function(List<int>, String) onPosition;
  final void Function(String) onError;

  /// Rooms the viewer may enter (dims the others), or `null` when unknown.
  final Set<String>? accessibleRooms;
  final void Function(String actor)? onSelectActor;

  /// Actors currently speaking in voice; drawn with a ring.
  final ValueListenable<Set<String>>? speaking;
  final ValueListenable<Map<String, double>>? audioLevels;
  final ValueListenable<Set<String>>? onlineAgents;
  final ValueListenable<Map<String, dynamic>>? agentPresentation;

  /// Live camera views by actor. Each replaces that avatar's drawn face.
  final ValueListenable<Map<String, Widget>>? faces;
  @override
  State<OfficeWorld> createState() => OfficeWorldState();
}

class OfficeWorldState extends State<OfficeWorld> {
  final focus = FocusNode();
  OfficeMap? map;
  late final WorldGame _game = WorldGame(onStep: onStep);
  double gestureZoom = 1;
  Offset? lastFocal;
  bool reduceMotion = false;
  bool systemReduceMotion = false;
  int _routeRequest = 0;

  @visibleForTesting
  WorldGame get game => _game;

  /// Whether the local avatar is still stepping along a route.
  bool get walking => _game.moving;

  /// The cell the local avatar occupies or is stepping into.
  List<int> get current => List.unmodifiable(_game.position);

  List<int> get spawn {
    final s = map?.spawn;
    return s == null ? List.of(_game.position) : [s.x, s.y];
  }

  @override
  void initState() {
    super.initState();
    widget.remote.addListener(updateRemote);
    updateRemote();
    widget.speaking?.addListener(_updateSpeaking);
    widget.onlineAgents?.addListener(_updateSpeaking);
    widget.agentPresentation?.addListener(_updateAgentNames);
    widget.faces?.addListener(_updateFaces);
    _updateFaces();
    _updateSpeaking();
    _configure();
    load();
  }

  void updateRemote() {
    _game.remote.updateSnapshot(widget.remote.value);
  }

  void _updateSpeaking() {
    _game.onlineAgents = widget.onlineAgents?.value ?? const {};
    _game.speaking = widget.speaking?.value ?? const {};
  }

  void _updateAgentNames() {
    final updates = widget.agentPresentation?.value ?? {};
    _game.riveFaces = updates.keys.toSet();
    _game.names = {
      ..._game.names,
      for (final entry in updates.entries)
        entry.key: entry.value['name'] as String,
    };
  }

  void _updateFaces() {
    _game.faces = widget.faces?.value.keys.toSet() ?? const {};
  }

  void _configure() {
    final seed = widget.seed;
    final actors = (seed['actors'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    final rooms = (seed['rooms'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    _game
      ..self = widget.actor
      ..accessibleRooms = widget.accessibleRooms
      ..names = {for (final a in actors) a['id'] as String: a['name'] as String}
      ..roomNames = {
        for (final r in rooms) r['id'] as String: r['name'] as String,
      }
      ..restrictedRooms = {
        for (final r in rooms)
          if (r['restricted'] == true) r['id'] as String,
      };
    _updateAgentNames();
    final agents = {
      for (final a in actors)
        if (a['kind'] == 'agent') a['id'] as String,
    };
    final m = map;
    if (m != null) {
      _game.agentSeats = [
        for (final desk in m.desks)
          if (agents.contains(desk.assignee))
            (actor: desk.assignee!, seat: desk.seat),
      ];
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    systemReduceMotion = MediaQuery.disableAnimationsOf(context);
    updateMotionPreference();
  }

  void updateMotionPreference() {
    final reduced = reduceMotion || systemReduceMotion;
    _game.reducedMotion = reduced;
    _game.remote.reducedMotion = reduced;
  }

  Future<void> load() async {
    final decoded = OfficeMap.fromJson(
      jsonDecode(await rootBundle.loadString(mapAsset, cache: false))
          as Map<String, dynamic>,
    );
    if (!mounted) return;
    final scene = OfficeScene(decoded);
    setState(() => map = decoded);
    _game.setScene(scene);
    _configure();
    _game.reset([decoded.spawn.x, decoded.spawn.y]);
    widget.onPosition(spawn, _roomOf(spawn));
  }

  String _roomOf(List<int> cell) {
    try {
      return widget.locateRoom?.call(cell) ?? corridorRoom;
    } catch (_) {
      return corridorRoom;
    }
  }

  void onStep(List<int> point) {
    widget.onPosition(List.of(point), _roomOf(point));
  }

  /// Plans asynchronously; a newer request or a policy change discards the
  /// result. If the avatar stepped while planning, the route is replanned so
  /// it always starts at the current cell.
  Future<void> moveTo(List<int> destination, {bool quiet = false}) async {
    final request = ++_routeRequest;
    for (var attempt = 0; attempt < 3; attempt++) {
      final from = current;
      List<List<int>>? route;
      try {
        route = await widget.findPath(from, destination);
      } catch (_) {
        if (mounted && request == _routeRequest) {
          widget.onError('The Rust map service is unavailable.');
        }
        return;
      }
      if (!mounted || request != _routeRequest) return;
      if (route == null) {
        if (!quiet) {
          widget.onError('That destination is blocked or requires membership.');
        }
        return;
      }
      final now = current;
      if (route.isEmpty ||
          route.first[0] != now[0] ||
          route.first[1] != now[1]) {
        continue;
      }
      _game.route = route.skip(1).toList();
      focus.requestFocus();
      return;
    }
  }

  void policyChanged({required bool reset}) {
    _routeRequest++;
    _game.route = [];
    if (reset) {
      _game.reset(spawn);
      widget.onPosition(spawn, corridorRoom);
    }
  }

  Future<void> goToRoom(String room) async {
    final target = map?.roomById(room);
    if (target == null) return;
    final destination = [target.spawn.x, target.spawn.y];
    await moveTo(destination);
  }

  void centerOnMe() => _game.focusOn(current, zoomTo: 2);

  @override
  void didUpdateWidget(covariant OfficeWorld oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.speaking != widget.speaking) {
      oldWidget.speaking?.removeListener(_updateSpeaking);
      widget.speaking?.addListener(_updateSpeaking);
      _updateSpeaking();
    }
    if (oldWidget.onlineAgents != widget.onlineAgents) {
      oldWidget.onlineAgents?.removeListener(_updateSpeaking);
      widget.onlineAgents?.addListener(_updateSpeaking);
      _updateSpeaking();
    }
    if (oldWidget.agentPresentation != widget.agentPresentation) {
      oldWidget.agentPresentation?.removeListener(_updateAgentNames);
      widget.agentPresentation?.addListener(_updateAgentNames);
      _updateAgentNames();
    }
    if (oldWidget.faces != widget.faces) {
      oldWidget.faces?.removeListener(_updateFaces);
      widget.faces?.addListener(_updateFaces);
      _updateFaces();
    }
    if (oldWidget.remote != widget.remote) {
      oldWidget.remote.removeListener(updateRemote);
      widget.remote.addListener(updateRemote);
      updateRemote();
    }
    _configure();
    if (oldWidget.actor != widget.actor) {
      _routeRequest++;
      _game.reset(spawn);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onPosition(spawn, _roomOf(spawn));
      });
    }
  }

  @override
  void dispose() {
    widget.remote.removeListener(updateRemote);
    widget.agentPresentation?.removeListener(_updateAgentNames);
    widget.onlineAgents?.removeListener(_updateSpeaking);
    widget.speaking?.removeListener(_updateSpeaking);
    widget.faces?.removeListener(_updateFaces);
    focus.dispose();
    super.dispose();
  }

  KeyEventResult key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    final p = current;
    // Keys follow the floor grid: up/down along one wall, left/right along
    // the other. Blocked steps are ignored silently.
    final List<int>? next;
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.keyW) {
      next = [p[0], p[1] - 1];
    } else if (k == LogicalKeyboardKey.arrowDown ||
        k == LogicalKeyboardKey.keyS) {
      next = [p[0], p[1] + 1];
    } else if (k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.keyA) {
      next = [p[0] - 1, p[1]];
    } else if (k == LogicalKeyboardKey.arrowRight ||
        k == LogicalKeyboardKey.keyD) {
      next = [p[0] + 1, p[1]];
    } else {
      next = null;
    }
    if (next == null) return KeyEventResult.ignored;
    moveTo(next, quiet: true);
    return KeyEventResult.handled;
  }

  void _tap(Offset position) {
    final actor = _game.actorAt(position);
    if (actor != null && widget.onSelectActor != null) {
      widget.onSelectActor!(actor);
      return;
    }
    moveTo(_game.cellAt(position));
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: focus,
    onKeyEvent: key,
    child: Stack(
      children: [
        Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent) {
              final factor = event.scrollDelta.dy > 0 ? 1 / 1.1 : 1.1;
              _game.zoomAt(_game.zoom * factor, event.localPosition);
            }
          },
          child: MouseRegion(
            onHover: (e) => _game.hover = e.localPosition,
            onExit: (_) => _game.hover = null,
            child: GestureDetector(
              onTapUp: (d) => _tap(d.localPosition),
              onScaleStart: (d) {
                gestureZoom = _game.zoom;
                lastFocal = d.localFocalPoint;
                _game.follow = false;
              },
              onScaleUpdate: (d) {
                final previous = lastFocal ?? d.localFocalPoint;
                _game.zoomAt(gestureZoom * d.scale, previous);
                _game.pan += d.localFocalPoint - previous;
                lastFocal = d.localFocalPoint;
              },
              onScaleEnd: (_) {
                lastFocal = null;
                _game.follow = true;
              },
              child: GameWidget(game: _game),
            ),
          ),
        ),
        if (widget.faces != null)
          Positioned.fill(
            child: FaceLayer(game: _game, faces: widget.faces!),
          ),
        if (widget.agentPresentation != null && widget.speaking != null)
          Positioned.fill(
            child: AgentSpeechLayer(
              game: _game,
              presentation: widget.agentPresentation!,
              speaking: widget.speaking!,
              audioLevels: widget.audioLevels,
              reduceMotion: reduceMotion || systemReduceMotion,
            ),
          ),
        Positioned(
          left: 10,
          right: 10,
          top: 10,
          child: Row(
            children: [
              if (widget.onWorkspaceTools != null)
                TextButton.icon(
                  onPressed: widget.onWorkspaceTools,
                  style: TextButton.styleFrom(
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .secondaryContainer,
                    foregroundColor: Theme.of(context)
                        .colorScheme
                        .onSecondaryContainer,
                  ),
                  icon: const Icon(Icons.apps, size: 18),
                  label: const Text('Workspace tools'),
                ),
              const Spacer(),
              IconButton.filledTonal(
                tooltip: systemReduceMotion
                    ? 'Motion reduced by system'
                    : (reduceMotion ? 'Enable motion' : 'Reduce motion'),
                onPressed: systemReduceMotion
                    ? null
                    : () {
                        setState(() => reduceMotion = !reduceMotion);
                        updateMotionPreference();
                      },
                icon: Icon(
                  reduceMotion || systemReduceMotion
                      ? Icons.motion_photos_on
                      : Icons.motion_photos_off,
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Center on me',
                onPressed: centerOnMe,
                icon: const Icon(Icons.my_location),
              ),
              IconButton.filledTonal(
                tooltip: 'Zoom out',
                onPressed: () => _game.zoomAt(_game.zoom / 1.25, _game.center),
                icon: const Icon(Icons.remove),
              ),
              IconButton.filledTonal(
                tooltip: 'Reset view',
                onPressed: _game.resetView,
                icon: const Icon(Icons.center_focus_strong),
              ),
              IconButton.filledTonal(
                tooltip: 'Zoom in',
                onPressed: () => _game.zoomAt(_game.zoom * 1.25, _game.center),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        Positioned(
          left: 12,
          bottom: 10,
          child: IgnorePointer(
            child: Text(
              'Click to walk · WASD/arrows · drag to pan · scroll to zoom',
              style: TextStyle(
                fontSize: 11,
                color: Colors.black.withValues(alpha: .45),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

/// Live camera bubbles placed over the canvas where each avatar's face
/// would be. Positions come from the game's last render; the layer only
/// ticks while at least one camera is shown.
class FaceLayer extends StatefulWidget {
  const FaceLayer({super.key, required this.game, required this.faces});
  final WorldGame game;
  final ValueListenable<Map<String, Widget>> faces;

  @override
  State<FaceLayer> createState() => _FaceLayerState();
}

class _FaceLayerState extends State<FaceLayer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => setState(() {}));

  @override
  void initState() {
    super.initState();
    widget.faces.addListener(_changed);
    _changed();
  }

  void _changed() {
    final active = widget.faces.value.isNotEmpty;
    if (active && !_ticker.isActive) _ticker.start();
    if (!active && _ticker.isActive) _ticker.stop();
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant FaceLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.faces != widget.faces) {
      oldWidget.faces.removeListener(_changed);
      widget.faces.addListener(_changed);
      _changed();
    }
  }

  @override
  void dispose() {
    widget.faces.removeListener(_changed);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final views = widget.faces.value;
    return IgnorePointer(
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          for (final slot in widget.game.faceSlots)
            if (views[slot.actor] case final view?)
              Positioned.fromRect(
                key: ValueKey('face-${slot.actor}'),
                rect: slot.rect,
                child: Opacity(
                  opacity: slot.behind ? .35 : 1,
                  child: DecoratedBox(
                    position: DecorationPosition.foreground,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white,
                        width: slot.diameter > 60 ? 3 : 2,
                      ),
                    ),
                    child: DecoratedBox(
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0xff2b3530),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x40000000),
                            blurRadius: 8,
                            offset: Offset(0, 3),
                          ),
                        ],
                      ),
                      child: ClipOval(child: RepaintBoundary(child: view)),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
