part of 'collaboration.dart';

abstract class _CollaborationConnection extends _CollaborationSession {
  @override
  Future<void> connect() async {
    if (connecting) return;
    connecting = true;
    try {
      final me = await request('GET', '/v1/me') as Map<String, dynamic>;
      realtime = RealtimeSession(
        client: client,
        issue: () async {
          final ticket = await request(
            'POST',
            '/v1/realtime/ticket',
            const <String, dynamic>{},
          );
          unawaited(refresh());
          return ticket;
        },
      );
      if (!mounted) return;
      setState(() {
        identity = me['actor'] as String;
        status = 'Connecting';
      });
      widget.onIdentity(identity);
      final who = identity!;
      final authority = me['authority_id'] as String?;
      if (authority == null ||
          !RegExp(r'^[a-f0-9-]{36}$').hasMatch(authority)) {
        setState(
          () => outboxError = 'Node identity unavailable; task writes disabled',
        );
      }
      final capturedSession = session;
      try {
        if (authority == null ||
            !RegExp(r'^[a-f0-9-]{36}$').hasMatch(authority)) {
          throw const OutboxFailure('invalid_authority');
        }
        final queue = await TaskOutbox.open('${authority}_$who');
        if (!mounted || identity != who || session != capturedSession) return;
        taskDelivery = TaskDelivery(
          outbox: queue,
          network: request,
          active: () =>
              mounted &&
              identity == who &&
              session == capturedSession &&
              !disconnecting,
          onChanged: (items) {
            if (mounted) {
              queueNotifier.value = items;
              setState(() {
                queuedTasks = items;
                outboxError = null;
              });
            }
          },
        );
        await taskDelivery!.updateView();
      } catch (_) {
        if (mounted) setState(() => outboxError = 'Task queue unavailable');
      }
      try {
        if (authority == null ||
            !RegExp(r'^[a-f0-9-]{36}$').hasMatch(authority)) {
          throw const OutboxFailure('invalid_authority');
        }
        final queue = await TaskOutbox.open('${authority}_$who', chat: true);
        final entries = await queue.list();
        if (mounted && identity == who && session == capturedSession) {
          setState(() => queuedChat = entries);
        }
      } catch (_) {
        if (mounted) {
          setState(
            () =>
                chatOutboxError = 'Earlier unsent messages could not be read.',
          );
        }
      }
      if (!mounted ||
          disconnecting ||
          identity != who ||
          session != capturedSession) {
        return;
      }
      final matrix = MatrixChatClient(
        MatrixSession(
          request: request,
          store: auth.store,
          node: '${auth.api.host}:${_nodePort()}',
          actor: who,
        ),
      );
      chatClient = matrix;
      chatController = ChatController(matrix);
      chatNotifications = ChatNotifications(matrix, MacChatNotifications());
      unawaited(matrix.start());
      presenceTimer?.cancel();
      presenceTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => refreshPresence(),
      );
      voice?.dispose();
      voice = VoiceController(realtime: realtime!, session: () => session)
        ..addListener(_voiceChanged);
      await refresh();
      await refreshPresence();
    } catch (_) {
      if (mounted) setState(() => status = 'Connection failed');
      // A wrong device token is simply refused; a signed-in session stays
      // and can retry.
      if (auth.usingDeviceToken) await auth.signOut();
    } finally {
      connecting = false;
    }
  }

  @override
  Future<void> refresh() async {
    if (identity == null || busy || disconnecting) return;
    busy = true;
    final who = identity;
    try {
      final rooms = (await request('GET', '/v1/rooms') as List).cast<String>();
      if (!mounted || identity != who) return;
      widget.onPermissions(rooms);
      unawaited(voice?.refreshAvailability());
      // Chat availability must not revoke otherwise valid office/voice access.
      unawaited(chatClient?.refreshRooms().catchError((_) {}));
      final delivery = taskDelivery;
      if (delivery != null) await delivery.drain();
      if (mounted) setState(() => status = 'Connected');
    } catch (_) {
      if (mounted && identity == who) {
        widget.onPermissions([]);
        setState(() => status = 'Offline or access denied');
      }
    } finally {
      busy = false;
    }
  }
}
