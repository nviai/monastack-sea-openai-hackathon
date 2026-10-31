String formatUtc(int seconds) =>
    '${DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true).toIso8601String().substring(0, 19).replaceFirst('T', ' ')} UTC';
int? parseUtc(String text) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2})(?::(\d{2}))?$',
  ).firstMatch(text.trim());
  if (match == null) return null;
  final values = [for (var i = 1; i <= 5; i++) int.parse(match.group(i)!)];
  final seconds = int.parse(match.group(6) ?? '0');
  final date = DateTime.utc(
    values[0],
    values[1],
    values[2],
    values[3],
    values[4],
    seconds,
  );
  if (date.year != values[0] ||
      date.month != values[1] ||
      date.day != values[2] ||
      date.hour != values[3] ||
      date.minute != values[4] ||
      date.second != seconds) {
    return null;
  }
  return date.millisecondsSinceEpoch ~/ 1000;
}
