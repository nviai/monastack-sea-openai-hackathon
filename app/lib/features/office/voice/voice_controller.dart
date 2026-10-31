import 'package:monastack/shared/office_endpoint.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'package:monastack/features/office/presence/realtime_session.dart';
import 'package:monastack/shared/node_request.dart';

/// What the voice panel shows. `unavailable` and `error` leave room chat as
/// the fallback.
enum VoicePhase { unavailable, idle, joining, joined, error }

@immutable
class VoiceState {
  const VoiceState({
    this.phase = VoicePhase.unavailable,
    this.room,
    this.microphone = false,
    this.camera = false,
    this.participants = const {},
    this.speaking = const {},
    this.hearing = const {},
    this.videos = const {},
    this.message,
  });

  final VoicePhase phase;

  /// Monastack room the voice connection belongs to.
  final String? room;

  /// Whether the local microphone is published. Always false on join.
  final bool microphone;

  /// Whether the local camera is published. Always false on join.
  final bool camera;

  /// Actor IDs of other participants, and of everyone currently speaking.
  final Set<String> participants;
  final Set<String> speaking;

  /// Actors whose audio this client is receiving.
  final Set<String> hearing;

  /// Live camera tracks by actor, including this user's own preview. Only
  /// people in the same media room are present here.
  final Map<String, lk.VideoTrack> videos;
  final String? message;

  VoiceState copyWith({
    VoicePhase? phase,
    String? room,
    bool? microphone,
    bool? camera,
    Set<String>? participants,
    Set<String>? speaking,
    Set<String>? hearing,
    Map<String, lk.VideoTrack>? videos,
    String? message,
    bool clearMessage = false,
  }) => VoiceState(
    phase: phase ?? this.phase,
    room: room ?? this.room,
    microphone: microphone ?? this.microphone,
    camera: camera ?? this.camera,
    participants: participants ?? this.participants,
    speaking: speaking ?? this.speaking,
    hearing: hearing ?? this.hearing,
    videos: videos ?? this.videos,
    message: clearMessage ? null : (message ?? this.message),
  );
}

/// Joins the voice room for the room the user is in, through the realtime
/// media control plane. Voice is opt-in per session, the microphone and the
/// camera start off on every join, and leaving or losing access ends the
/// connection.
class VoiceController extends ValueNotifier<VoiceState> {
  VoiceController({
    required this.realtime,
    required this.session,
    this.connector = _connect,
  }) : super(const VoiceState());

  final RealtimeSession realtime;

  /// Presence session the media token is bound to.
  final String Function() session;

  /// Seam for tests; connects a LiveKit room.
  final Future<VoiceConnection> Function(String url, String token) connector;

  VoiceConnection? _connection;
  String? _target;
  bool _wanted = false;
  int _attempt = 0;
  bool _disposed = false;

  bool get wanted => _wanted;

  Future<void> refreshAvailability() async {
    try {
      final status = await realtime.request(
        'GET',
        '/v1/media/status',
      ) as Map<String, dynamic>;
      final available = status['available'] == true;
      if (_disposed) return;
      if (!available) {
        if (_wanted) await _drop();
        value = const VoiceState(
          message: 'Voice server unavailable · use room chat',
        );
      } else if (value.phase == VoicePhase.unavailable) {
        value = const VoiceState(phase: VoicePhase.idle);
      }
    } catch (_) {
      if (!_disposed && value.phase != VoicePhase.joined) {
        value = const VoiceState(message: 'Voice unavailable · use room chat');
      }
    }
  }

  /// Called whenever the user's room changes.
  Future<void> follow(String room) async {
    _target = room;
    if (_wanted && value.room != room) await _sync();
  }

  Future<void> join(String room) async {
    _target = room;
    _wanted = true;
    await _sync();
  }

  Future<void> leave() async {
    _wanted = false;
    _attempt++;
    await _drop();
    if (!_disposed && value.phase != VoicePhase.unavailable) {
      value = const VoiceState(phase: VoicePhase.idle);
    }
  }

  /// A device button connects media on demand, including from the lobby.
  Future<void> toggleMicrophone(String room) async {
    if (_disposed || value.phase == VoicePhase.joining) return;
    final enabled = !value.microphone;
    if (enabled && value.phase != VoicePhase.joined) await join(room);
    if (!_disposed &&
        _wanted &&
        _target == room &&
        value.phase == VoicePhase.joined) {
      await setMicrophone(enabled);
    }
  }

  Future<void> toggleCamera(String room) async {
    if (_disposed || value.phase == VoicePhase.joining) return;
    final enabled = !value.camera;
    if (enabled && value.phase != VoicePhase.joined) await join(room);
    if (!_disposed &&
        _wanted &&
        _target == room &&
        value.phase == VoicePhase.joined) {
      await setCamera(enabled);
    }
  }

  Future<void> setMicrophone(bool enabled) async {
    final connection = _connection;
    if (connection == null || value.phase != VoicePhase.joined) return;
    try {
      await connection.setMicrophone(enabled);
      if (!_disposed) {
        value = value.copyWith(microphone: enabled, clearMessage: true);
      }
    } catch (_) {
      if (!_disposed) {
        value = value.copyWith(
          microphone: false,
          message: 'Microphone unavailable. Check macOS privacy settings.',
        );
      }
    }
  }

  /// Publishes the camera; it replaces this user's face in the office for
  /// everyone in the same voice room.
  Future<void> setCamera(bool enabled) async {
    final connection = _connection;
    if (connection == null || value.phase != VoicePhase.joined) return;
    try {
      await connection.setCamera(enabled);
      if (!_disposed) {
        value = value.copyWith(camera: enabled, clearMessage: true);
        _update();
      }
    } catch (_) {
      if (_disposed) return;
      try {
        await connection.setCamera(false);
      } catch (_) {}
      value = value.copyWith(
        camera: false,
        message: 'Camera unavailable. Check privacy settings.',
      );
      _update();
    }
  }

  Future<void> _drop() async {
    final connection = _connection;
    _connection = null;
    await connection?.close();
  }

  Future<void> _sync() async {
    final room = _target;
    if (!_wanted || room == null || _disposed) return;
    final attempt = ++_attempt;
    await _drop();
    value = VoiceState(phase: VoicePhase.joining, room: room);
    // Presence for the new room may not be published yet; the control plane
    // requires it, so retry briefly on 409.
    for (var tries = 0; tries < 8; tries++) {
      if (attempt != _attempt || _disposed) return;
      try {
        final grant = await realtime.request('POST', '/v1/media/token', {
          'room': room,
          'session': session(),
        }) as Map<String, dynamic>;
        final url = grant['url'];
        if (parseOfficeEndpoint(url, scheme: 'ws') == null ||
            url is! String ||
            grant['token'] is! String) {
          throw const FormatException('invalid media grant');
        }
        final connection = await connector(url, grant['token'] as String);
        if (attempt != _attempt || _disposed) {
          await connection.close();
          return;
        }
        _connection = connection;
        connection.onChanged = _update;
        connection.onClosed = () => _closed(attempt);
        value = VoiceState(phase: VoicePhase.joined, room: room);
        _update();
        return;
      } on NodeFailure catch (e) {
        if (e.status == 409) {
          await Future<void>.delayed(const Duration(milliseconds: 750));
          continue;
        }
        if (attempt == _attempt && !_disposed) {
          value = VoiceState(
            phase: e.status == 503 ? VoicePhase.unavailable : VoicePhase.error,
            room: room,
            message: e.status == 403
                ? 'No voice access to this room · use room chat'
                : 'Voice unavailable · use room chat',
          );
        }
        return;
      } catch (_) {
        if (attempt == _attempt && !_disposed) {
          value = VoiceState(
            phase: VoicePhase.error,
            room: room,
            message: 'Could not connect to voice · use room chat',
          );
        }
        return;
      }
    }
    if (attempt == _attempt && !_disposed) {
      value = VoiceState(
        phase: VoicePhase.error,
        room: room,
        message: 'Enter the room to join its voice',
      );
    }
  }

  void _update() {
    final connection = _connection;
    if (connection == null || _disposed) return;
    value = value.copyWith(
      participants: connection.participants(),
      speaking: connection.speaking(),
      hearing: connection.hearing(),
      videos: connection.videos(),
    );
  }

  /// The server ended the connection: the room was rotated after an access
  /// change, or this session was removed. Rejoin if still wanted; the
  /// control plane decides whether access remains.
  void _closed(int attempt) {
    if (attempt != _attempt || _disposed) return;
    _connection = null;
    value = VoiceState(
      phase: VoicePhase.joining,
      room: value.room,
      message: 'Voice reconnecting',
    );
    if (_wanted) {
      Future<void>.delayed(const Duration(milliseconds: 500), _sync);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _attempt++;
    unawaited(_drop());
    super.dispose();
  }
}

/// A live media connection. Implemented with LiveKit; replaced in tests.
abstract class VoiceConnection {
  VoidCallback? onChanged;
  VoidCallback? onClosed;
  Set<String> participants();
  Set<String> speaking();
  Set<String> hearing();

  /// Live camera tracks by actor, the local one included.
  Map<String, lk.VideoTrack> videos();
  Future<void> setMicrophone(bool enabled);
  Future<void> setCamera(bool enabled);
  Future<void> close();
}

String _actorOf(String identity) => identity.split('.').first;

class _LiveKitConnection extends VoiceConnection {
  _LiveKitConnection(this.room) : listener = room.createListener() {
    listener
      ..on<lk.ParticipantConnectedEvent>((_) => onChanged?.call())
      ..on<lk.ParticipantDisconnectedEvent>((_) => onChanged?.call())
      ..on<lk.ActiveSpeakersChangedEvent>((_) => onChanged?.call())
      ..on<lk.TrackSubscribedEvent>((_) => onChanged?.call())
      ..on<lk.TrackUnsubscribedEvent>((_) => onChanged?.call())
      ..on<lk.TrackMutedEvent>((_) => onChanged?.call())
      ..on<lk.TrackUnmutedEvent>((_) => onChanged?.call())
      ..on<lk.LocalTrackPublishedEvent>((_) => onChanged?.call())
      ..on<lk.LocalTrackUnpublishedEvent>((_) => onChanged?.call())
      ..on<lk.RoomDisconnectedEvent>((_) {
        if (!_closing) onClosed?.call();
      });
  }

  final lk.Room room;
  final lk.EventsListener<lk.RoomEvent> listener;
  bool _closing = false;

  @override
  Set<String> participants() => {
    for (final p in room.remoteParticipants.values) _actorOf(p.identity),
  };

  @override
  Set<String> speaking() => {
    for (final p in room.activeSpeakers) _actorOf(p.identity),
  };

  @override
  Set<String> hearing() => {
    for (final p in room.remoteParticipants.values)
      if (p.audioTrackPublications.any((t) => t.subscribed))
        _actorOf(p.identity),
  };

  @override
  Map<String, lk.VideoTrack> videos() {
    final result = <String, lk.VideoTrack>{};
    final local = room.localParticipant;
    for (final p in <lk.Participant>[
      ?local,
      ...room.remoteParticipants.values,
    ]) {
      final track = p.videoTrackPublications
          .where(
            (t) =>
                t.source == lk.TrackSource.camera &&
                t.track != null &&
                !t.muted,
          )
          .firstOrNull
          ?.track;
      if (track is lk.VideoTrack) {
        result.putIfAbsent(_actorOf(p.identity), () => track);
      }
    }
    return result;
  }

  @override
  Future<void> setMicrophone(bool enabled) async {
    await room.localParticipant?.setMicrophoneEnabled(enabled);
  }

  @override
  Future<void> setCamera(bool enabled) async {
    // A small square-ish capture is enough for a face bubble and keeps the
    // load low with several people in a room.
    await room.localParticipant?.setCameraEnabled(
      enabled,
      cameraCaptureOptions: const lk.CameraCaptureOptions(
        params: lk.VideoParametersPresets.h360_43,
        maxFrameRate: 24,
      ),
    );
  }

  @override
  Future<void> close() async {
    _closing = true;
    await room.disconnect();
    await listener.dispose();
    await room.dispose();
  }
}

Future<VoiceConnection> _connect(String url, String token) async {
  final room = lk.Room(
    roomOptions: const lk.RoomOptions(adaptiveStream: false, dynacast: false),
  );
  await room
      .connect(
        url,
        token,
        connectOptions: const lk.ConnectOptions(
          autoSubscribe: true,
          // Loopback media server; no STUN/TURN traffic leaves the machine.
          rtcConfiguration: lk.RTCConfiguration(iceServers: []),
        ),
      )
      .timeout(const Duration(seconds: 15));
  return _LiveKitConnection(room);
}
