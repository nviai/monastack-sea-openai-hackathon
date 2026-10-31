import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import 'meetings.dart' show formatUtc, parseUtc;
import 'task_board.dart';

class Bookings extends ConsumerStatefulWidget {
  const Bookings({super.key, required this.request});
  final TaskRequest request;
  @override
  ConsumerState<Bookings> createState() => _BookingsState();
}

class _BookingsState extends ConsumerState<Bookings> {
  List<dynamic> items = [], customers = [];
  bool loading = true, canManage = false, busy = false, again = false;
  String? error;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    load();
    timer = Timer.periodic(const Duration(seconds: 5), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (busy) {
      again = true;
      return;
    }
    busy = true;
    try {
      final result = await Future.wait([
        widget.request('GET', '/v1/bookings'),
        widget.request('GET', '/v1/customers'),
        widget.request('GET', '/v1/bookings/capabilities'),
      ]);
      if (mounted) {
        setState(() {
          items = result[0] as List<dynamic>;
          customers = result[1] as List<dynamic>;
          canManage = (result[2] as Map<String, dynamic>)['can_manage'] == true;
          loading = false;
          error = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          items = [];
          customers = [];
          canManage = false;
          loading = false;
          error = 'Customer access denied or node unavailable.';
        });
      }
    } finally {
      busy = false;
      if (mounted && again) {
        again = false;
        unawaited(load());
      }
    }
  }

  Future<void> create() async {
    if (customers.isEmpty) {
      setState(() => error = 'Create a customer first.');
      return;
    }
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _BookingForm(customers: customers),
    );
    if (data == null) return;
    try {
      await widget.request('POST', '/v1/bookings', {
        'id': const Uuid().v4(),
        'op': const Uuid().v4(),
        ...data,
      });
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm booking. Check the time, access and existing bookings before retrying.',
        );
      }
    }
  }

  Future<void> cancel(Map<String, dynamic> item) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel booking?'),
        content: Text(
          '${item['title']} · ${item['customer_name']}\nNo customer notification will be sent.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm cancellation'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await widget.request(
        'POST',
        '/v1/bookings/${Uri.encodeComponent(item['id'] as String)}/cancel',
        {'expected_version': item['version'], 'op': const Uuid().v4()},
      );
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm cancellation. Refresh and check before retrying.',
        );
      }
    }
  }

  Future<void> reschedule(Map<String, dynamic> item) async {
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _BookingForm(customers: customers, existing: item),
    );
    if (data == null) return;
    data.remove('customer');
    try {
      await widget.request(
        'POST',
        '/v1/bookings/${Uri.encodeComponent(item['id'] as String)}',
        {...data, 'expected_version': item['version'], 'op': const Uuid().v4()},
      );
      await load();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Could not confirm the change. Check access, time and existing bookings before retrying.',
        );
      }
    }
  }

  Future<void> history(Map<String, dynamic> item) async {
    try {
      final events = await widget.request(
        'GET',
        '/v1/bookings/${Uri.encodeComponent(item['id'] as String)}/history',
      ) as List<dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Booking history'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: events
                  .map((e) => Text('${e['actor']} · ${e['action']}'))
                  .toList(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not load booking history.');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 760,
      height: 600,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Customer bookings',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                ),
                IconButton(
                  onPressed: load,
                  tooltip: 'Refresh',
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Text(
              'Local records only · UTC · no invitations or external calendar',
              style: TextStyle(color: Colors.black54),
            ),
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.red)),
            if (!loading && canManage && customers.isNotEmpty)
              TextButton.icon(
                onPressed: create,
                icon: const Icon(Icons.add),
                label: const Text('Book customer'),
              ),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : items.isEmpty
                  ? const Center(child: Text('No accessible bookings.'))
                  : ListView(
                      children: items.map((value) {
                        final item = value as Map<String, dynamic>;
                        return Card(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ListTile(
                                title: Text(item['title'] as String),
                                subtitle: Text(
                                  '${item['customer_name']} · ${item['state']}\n${formatUtc(item['starts'] as int)} to ${formatUtc(item['ends'] as int)}',
                                ),
                                isThreeLine: true,
                              ),
                              Wrap(
                                children: [
                                  TextButton(
                                    onPressed: () => history(item),
                                    child: const Text('History'),
                                  ),
                                  if (canManage && item['state'] == 'scheduled')
                                    TextButton(
                                      onPressed: () => reschedule(item),
                                      child: const Text('Reschedule'),
                                    ),
                                  if (canManage && item['state'] == 'scheduled')
                                    TextButton(
                                      onPressed: () => cancel(item),
                                      child: const Text('Cancel booking'),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        );
                      }).toList(),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _BookingForm extends StatefulWidget {
  const _BookingForm({required this.customers, this.existing});
  final List<dynamic> customers;
  final Map<String, dynamic>? existing;
  @override
  State<_BookingForm> createState() => _BookingFormState();
}

class _BookingFormState extends State<_BookingForm> {
  final title = TextEditingController(),
      start = TextEditingController(),
      end = TextEditingController();
  String? customer, error;
  @override
  void initState() {
    super.initState();
    final item = widget.existing;
    if (item != null) {
      customer = item['customer'] as String;
      title.text = item['title'] as String;
      start.text = formatUtc(item['starts'] as int).replaceFirst(' UTC', '');
      end.text = formatUtc(item['ends'] as int).replaceFirst(' UTC', '');
    }
  }

  @override
  void dispose() {
    title.dispose();
    start.dispose();
    end.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.existing == null ? 'Book customer' : 'Reschedule booking',
    ),
    content: SizedBox(
      width: 450,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.existing != null)
            Text('Customer: ${widget.existing!['customer_name']}')
          else
            DropdownButtonFormField<String>(
              initialValue: customer,
              decoration: const InputDecoration(labelText: 'Customer'),
              items: widget.customers
                  .map(
                    (c) => DropdownMenuItem<String>(
                      value: c['id'] as String,
                      child: Text(c['name'] as String),
                    ),
                  )
                  .toList(),
              onChanged: (value) => setState(() => customer = value),
            ),
          TextField(
            controller: title,
            maxLength: 200,
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          TextField(
            controller: start,
            decoration: const InputDecoration(
              labelText: 'Start UTC',
              hintText: 'YYYY-MM-DD HH:MM',
            ),
          ),
          TextField(
            controller: end,
            decoration: const InputDecoration(
              labelText: 'End UTC',
              hintText: 'YYYY-MM-DD HH:MM',
            ),
          ),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.red)),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Back'),
      ),
      FilledButton(
        onPressed: () {
          final a = parseUtc(start.text), b = parseUtc(end.text);
          if (customer == null ||
              title.text.trim().isEmpty ||
              a == null ||
              b == null ||
              a < 946684800 ||
              b > 4102444800 ||
              b <= a ||
              b - a > 604800) {
            setState(
              () => error = 'Choose a customer and enter a valid UTC interval of up to seven days.',
            );
            return;
          }
          Navigator.pop(context, {
            'customer': customer!,
            'title': title.text.trim(),
            'starts': a,
            'ends': b,
          });
        },
        child: const Text('Save'),
      ),
    ],
  );
}
