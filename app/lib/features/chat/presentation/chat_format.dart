import '../domain/chat_client.dart';

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _groupGap = Duration(minutes: 5);

String clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// "Today", "Yesterday" or "Mon 12 Oct".
String dayLabel(DateTime t, DateTime now) {
  if (sameDay(t, now)) return 'Today';
  if (sameDay(t, now.subtract(const Duration(days: 1)))) return 'Yesterday';
  return '${_weekdays[t.weekday - 1]} ${t.day} ${_months[t.month - 1]}';
}

/// A follow-up from the same person within five minutes shares one avatar.
bool continuesGroup(ChatMessage message, ChatMessage? previous) =>
    previous != null &&
    previous.sender == message.sender &&
    sameDay(previous.time, message.time) &&
    message.time.difference(previous.time).abs() < _groupGap &&
    message.replyTo == null &&
    previous.delivery == Delivery.sent &&
    message.delivery == Delivery.sent;

String repliesLabel(int n) => n == 1 ? '1 reply' : '$n replies';
