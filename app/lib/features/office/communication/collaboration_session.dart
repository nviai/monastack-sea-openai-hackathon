part of 'collaboration.dart';

abstract class _CollaborationSession extends State<Collaboration> {
  Future<void> connect();
  Future<void> refresh();

  final token = TextEditingController();
  late final AuthSession auth = AuthSession(
    api: AuthApi(port: _nodePort()),
    store: Platform.environment['MONASTACK_CREDENTIAL_STORE'] == 'memory'
        ? MemoryCredentialStore()
        : KeychainCredentialStore(),
  );
  bool connecting = false;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  String session = const Uuid().v4();
  Timer? movementTimer;
  String? identity;
  String status = 'Disconnected';
  int online = 0;

  /// Realtime presence is a separate capability; chat keeps working when it
  /// is unavailable.
  RealtimeSession? realtime;
  bool presenceAvailable = false;
  Timer? presenceTimer;
  bool presenceBusy = false;
  List<int>? published;
  String? publishedRoom;
  DateTime publishedAt = DateTime.fromMillisecondsSinceEpoch(0);
  VoiceController? voice;

  /// Consecutive presence failures; the last snapshot is kept for a few
  /// seconds so one dropped request does not make everyone vanish.
  int presenceFailures = 0;
  int sequence = 0;
  bool busy = false;
  bool disconnecting = false;
  TaskDelivery? taskDelivery;
  MatrixChatClient? chatClient;
  ChatController? chatController;
  ChatNotifications? chatNotifications;
  String? outboxError;
  String? chatOutboxError;
  List<Map<String, dynamic>> queuedTasks = [];
  List<Map<String, dynamic>> queuedChat = [];
  final queueNotifier = ValueNotifier<List<Map<String, dynamic>>>([]);
  int _nodePort() {
    final port = int.tryParse(
      Platform.environment['MONASTACK_NODE_PORT'] ?? '47830',
    );
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('Invalid local node port');
    }
    return port;
  }

  /// Sends an authenticated request. A signed-in session renews its access
  /// token once if the node reports it expired.
  Future<dynamic> request(String method, String path, [Object? body]) async {
    if (!auth.active) throw const NodeFailure(401);
    try {
      return await _requestWithCredential(
        method,
        path,
        body,
        await auth.bearer(),
      );
    } on NodeFailure catch (e) {
      if (e.status != 401 || !auth.signedIn || !await auth.refreshNow()) {
        rethrow;
      }
      return _requestWithCredential(method, path, body, await auth.bearer());
    } on StateError {
      throw const NodeFailure(401);
    }
  }

  Future<dynamic> _requestWithCredential(
    String method,
    String path,
    Object? body,
    String credential,
  ) async {
    final req = await client
        .openUrl(
          method,
          Uri.parse('http://${auth.api.host}:${_nodePort()}$path'),
        )
        .timeout(const Duration(seconds: 3));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $credential');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    final res = await req.close().timeout(
      Duration(
        seconds: path.startsWith('/v1/agents/') && path.endsWith('/chat')
            ? 65
            : 3,
      ),
    );
    final text = await utf8.decoder
        .bind(res)
        .join()
        .timeout(const Duration(seconds: 3));
    if (res.statusCode >= 400) throw NodeFailure(res.statusCode);
    return text.isEmpty ? null : jsonDecode(text);
  }

  /// Signs in or out of collaboration as the session changes.
  void _authChanged() {
    if (!mounted) return;
    widget.onWorkspaceName?.call(auth.account?.workspaceName);
    if (auth.active && identity == null && !connecting) {
      connect();
    } else if (!auth.active && identity != null) {
      disconnect();
    }
    setState(() {});
  }

  /// Ends collaboration, then the session (sign-out) or device token.
  Future<void> signOut() async {
    await disconnect();
    if (identity == null) await auth.signOut();
  }

  /// Publishes this session's position when it changed (or every 5 s as a
  /// heartbeat) and reads visible presence. Runs every second and right after
  /// movement; a failure only affects presence, never chat.
  Future<void> refreshPresence() async {
    final presence = realtime;
    if (identity == null || presence == null || presenceBusy || disconnecting) {
      return;
    }
    presenceBusy = true;
    final requestedIdentity = identity;
    final requestedRoom = widget.room;
    final position = List<int>.of(widget.position.value);
    try {
      final now = DateTime.now();
      final moved =
          published == null ||
          published![0] != position[0] ||
          published![1] != position[1] ||
          publishedRoom != requestedRoom;
      if (position.every((c) => c >= 0) &&
          (moved || now.difference(publishedAt).inSeconds >= 5)) {
        await presence.request('POST', '/v1/presence', {
          'session': session,
          'room': requestedRoom,
          'x': position[0],
          'y': position[1],
          'seq': ++sequence,
        });
        published = position;
        publishedRoom = requestedRoom;
        publishedAt = now;
      }
      final people = await presence.request('GET', '/v1/presence') as List;
      presenceFailures = 0;
      if (mounted && identity == requestedIdentity && !disconnecting) {
        setState(() {
          presenceAvailable = true;
          online = people.length;
          widget.remote.value = people
              .cast<Map<String, dynamic>>()
              .where((p) => p['session'] != session)
              .toList();
        });
      }
    } catch (_) {
      // Presence failure leaves text chat available.
      published = null;
      if (++presenceFailures >= 3 &&
          mounted &&
          identity == requestedIdentity &&
          !disconnecting) {
        setState(() {
          presenceAvailable = false;
          online = 0;
          widget.remote.value = [];
        });
      }
    } finally {
      presenceBusy = false;
      final current = widget.position.value;
      if (mounted &&
          identity != null &&
          !disconnecting &&
          (current[0] != position[0] ||
              current[1] != position[1] ||
              widget.room != requestedRoom)) {
        positionChanged();
      }
    }
  }

  void _voiceChanged() {
    final state = voice?.value ?? const VoiceState();
    widget.speaking?.value = state.speaking;
    final faces = widget.faces;
    if (faces != null) faces.value = cameraFaces(state, faces.value);
  }

  Future<void> disconnect() async {
    if (disconnecting) return;
    disconnecting = true;
    presenceTimer?.cancel();
    movementTimer?.cancel();
    chatNotifications?.dispose();
    chatNotifications = null;
    await chatClient?.signOut();
    chatController?.dispose();
    chatController = null;
    chatClient = null;
    try {
      await taskDelivery?.waitForDrain();
    } catch (_) {}
    while ((busy || presenceBusy) && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!mounted) return;
    final closing = voice;
    voice = null;
    await closing?.leave();
    closing?.dispose();
    widget.speaking?.value = const {};
    widget.faces?.value = const {};
    try {
      await realtime?.request(
        'DELETE',
        '/v1/presence/${Uri.encodeComponent(session)}',
      );
    } catch (_) {
      /* expiry handles offline disconnects */
    }
    if (!mounted) return;
    setState(() {
      identity = null;
      realtime = null;
      presenceAvailable = false;
      published = null;
      taskDelivery = null;
      queuedTasks = [];
      queuedChat = [];
      queueNotifier.value = [];
      outboxError = null;
      chatOutboxError = null;
      disconnecting = false;
      session = const Uuid().v4();
      sequence = 0;
      widget.remote.value = [];
      token.clear();
      status = 'Disconnected';
    });
    widget.onIdentity(null);
  }

  Future<dynamic> taskRequest(
    String method,
    String path, [
    Object? body,
  ]) async {
    if (!TaskOutbox.supports(method, path)) return request(method, path, body);
    final delivery = taskDelivery;
    if (delivery == null) throw const OutboxFailure('unavailable');
    return delivery.request(method, path, body);
  }

  void positionChanged() {
    if (movementTimer?.isActive ?? false) return;
    movementTimer = Timer(const Duration(milliseconds: 120), refreshPresence);
  }

  @override
  void initState() {
    super.initState();
    widget.position.addListener(positionChanged);
    auth.addListener(_authChanged);
    auth.restore();
  }

  @override
  void didUpdateWidget(covariant Collaboration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) {
      oldWidget.position.removeListener(positionChanged);
      widget.position.addListener(positionChanged);
    }
    if (oldWidget.room != widget.room && identity != null) {
      refresh();
      refreshPresence();
      voice?.follow(widget.room);
    }
  }

  @override
  void dispose() {
    presenceTimer?.cancel();
    movementTimer?.cancel();
    voice?.dispose();
    chatNotifications?.dispose();
    chatController?.dispose();
    unawaited(chatClient?.close());
    widget.position.removeListener(positionChanged);
    auth.removeListener(_authChanged);
    auth.dispose();
    client.close(force: true);
    queueNotifier.dispose();
    token.dispose();
    super.dispose();
  }
}
