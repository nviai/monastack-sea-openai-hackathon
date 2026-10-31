import 'package:matrix/matrix.dart';

import '../domain/chat_client.dart';

ChatMessage matrixMessage(Event event, Timeline? timeline) {
  final shown = timeline == null ? event : event.getDisplayEvent(timeline);
  final reactions = <String, int>{};
  if (timeline != null) {
    for (final reaction in event.aggregatedEvents(timeline, 'm.annotation')) {
      if (reaction.redacted || reaction.status == EventStatus.error) continue;
      final key = (reaction.content['m.relates_to'] as Map?)?['key'];
      if (key is String) reactions.update(key, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  final relation = event.content['m.relates_to'] as Map?;
  final reply = relation?['m.in_reply_to'] as Map?;
  final media = shown.content['url'];
  return ChatMessage(
    id: event.eventId,
    roomId: event.room.id,
    sender: event.senderFromMemoryOrFallback.calcDisplayname(),
    body: shown.body,
    time: event.originServerTs,
    own: event.senderId == event.room.client.userID,
    canDelete: event.canRedact,
    edited: shown.eventId != event.eventId,
    deleted: event.redacted,
    transactionId: event.transactionId,
    thread: event.relationshipType == 'm.thread'
        ? event.relationshipEventId
        : null,
    replyTo: reply?['event_id'] as String?,
    attachment: media is String ? media : null,
    image: shown.messageType == 'm.image',
    mentioned:
        (shown.content['m.mentions'] as Map?)?['room'] == true ||
        (((shown.content['m.mentions'] as Map?)?['user_ids'] as List?)
                ?.contains(event.room.client.userID) ??
            false),
    reactions: reactions,
    readers: [
      for (final r in event.receipts)
        if (r.user.id != event.senderId &&
            r.user.id != event.room.client.userID)
          r.user.id,
    ],
  );
}
