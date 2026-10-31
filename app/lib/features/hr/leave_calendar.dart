import 'dart:async';

import 'package:flutter/material.dart';

import 'package:monastack/shared/node_request.dart';

/// A scoped view of approved leave, not an entitlement or payroll calendar.
class LeaveCalendar extends StatefulWidget {
  const LeaveCalendar({super.key, required this.request, this.initialMonth});
  final NodeRequest request;
  final DateTime? initialMonth;

  @override
  State<LeaveCalendar> createState() => _LeaveCalendarState();
}

class _LeaveCalendarState extends State<LeaveCalendar> {
  late DateTime month;
  int? selectedDay;
  List<dynamic> entries = [];
  bool truncated = false;
  bool loading = true;
  String? error;
  Timer? timer;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    final now = widget.initialMonth ?? DateTime.now().toUtc();
    month = DateTime.utc(now.year.clamp(2000, 2100), now.month);
    load();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => load());
  }

  String get monthKey =>
      '${month.year.toString().padLeft(4, '0')}-${month.month.toString().padLeft(2, '0')}';

  Future<void> load() async {
    final current = ++generation;
    final key = monthKey;
    try {
      final response = await widget.request(
        'GET',
        '/v1/leave/calendar?month=$key',
      ) as Map<String, dynamic>;
      if (!mounted || current != generation) return;
      if (response['month'] != key ||
          response['items'] is! List ||
          response['truncated'] is! bool) {
        throw const FormatException('Invalid calendar response');
      }
      setState(() {
        entries = response['items'] as List<dynamic>;
        truncated = response['truncated'] as bool;
        loading = false;
        error = null;
      });
    } catch (_) {
      if (!mounted || current != generation) return;
      setState(() {
        entries = [];
        truncated = false;
        loading = false;
        error = 'Calendar unavailable or access changed.';
      });
    }
  }

  void changeMonth(int offset) {
    final next = DateTime.utc(month.year, month.month + offset);
    if (next.year < 2000 || next.year > 2100) return;
    setState(() {
      month = next;
      entries = [];
      selectedDay = null;
      truncated = false;
      loading = true;
      error = null;
    });
    load();
  }

  List<Map<String, dynamic>> onDay(int day) {
    final date = '$monthKey-${day.toString().padLeft(2, '0')}';
    return entries.whereType<Map<String, dynamic>>().where((entry) {
      final start = entry['start_date'];
      final end = entry['end_date'];
      return start is String &&
          end is String &&
          start.compareTo(date) <= 0 &&
          end.compareTo(date) >= 0;
    }).toList();
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final days = DateTime.utc(month.year, month.month + 1, 0).day;
    final leading = DateTime.utc(month.year, month.month, 1).weekday - 1;
    return Dialog(
      child: SizedBox(
        width: 760,
        height: 650,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Approved leave calendar',
                      style: TextStyle(fontSize: 22),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close calendar',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const Text(
                'Calendar days only · pending cancellations remain shown · not a leave balance or payroll record.',
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Previous month',
                    onPressed: month.year == 2000 && month.month == 1
                        ? null
                        : () => changeMonth(-1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text(
                    monthKey,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  IconButton(
                    tooltip: 'Next month',
                    onPressed: month.year == 2100 && month.month == 12
                        ? null
                        : () => changeMonth(1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              if (error != null)
                Text(error!, style: const TextStyle(color: Colors.red)),
              if (truncated)
                const Text(
                  'Showing the first 500 records; this month is incomplete.',
                  style: TextStyle(color: Colors.red),
                ),
              if (loading) const LinearProgressIndicator(),
              Row(
                children: [
                  for (final label in [
                    'Mon',
                    'Tue',
                    'Wed',
                    'Thu',
                    'Fri',
                    'Sat',
                    'Sun',
                  ])
                    Expanded(child: Center(child: Text(label))),
                ],
              ),
              SizedBox(
                height: 250,
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 7,
                    childAspectRatio: 2,
                  ),
                  itemCount: leading + days,
                  itemBuilder: (context, index) {
                    final day = index - leading + 1;
                    if (day <= 0) return const SizedBox.shrink();
                    final count = onDay(day).length;
                    return TextButton(
                      onPressed: () => setState(() => selectedDay = day),
                      child: Text('$day${count == 0 ? '' : ' · $count'}'),
                    );
                  },
                ),
              ),
              Expanded(
                child: selectedDay == null
                    ? const Center(
                        child: Text('Select a day to see accessible leave.'),
                      )
                    : ListView(
                        children: [
                          Text(
                            '$monthKey-${selectedDay!.toString().padLeft(2, '0')}',
                          ),
                          for (final entry in onDay(selectedDay!))
                            ListTile(
                              title: Text('${entry['requester']}'),
                              subtitle: Text(
                                '${entry['start_date']} to ${entry['end_date']}${entry['state'] == 'cancellation_pending' ? ' · cancellation pending' : ''}',
                              ),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
