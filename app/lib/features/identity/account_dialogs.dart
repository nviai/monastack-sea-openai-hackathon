import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:monastack/features/identity/auth_session.dart';
import 'package:monastack/shared/node_request.dart';

String _ago(int seconds) {
  final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 - seconds;
  if (age < 90) return 'just now';
  if (age < 5400) return '${age ~/ 60} min ago';
  if (age < 129600) return '${age ~/ 3600} h ago';
  return '${age ~/ 86400} days ago';
}

String _problem(Object e) => e is NodeFailure
    ? switch (e.status) {
        403 => 'Not allowed.',
        409 => 'Not possible right now.',
        502 => 'The master node is not reachable.',
        _ => 'Request failed (${e.status}).',
      }
    : 'The node is not reachable.';

/// Your account: devices you are signed in on, and your password.
class AccountDialog extends StatefulWidget {
  const AccountDialog({
    super.key,
    required this.request,
    required this.account,
  });
  final NodeRequest request;
  final Account account;

  @override
  State<AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends State<AccountDialog> {
  List<Map<String, dynamic>> sessions = [];
  String? message;
  final current = TextEditingController();
  final next = TextEditingController();
  final confirm = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await widget.request('GET', '/v1/auth/sessions') as List;
      if (mounted) setState(() => sessions = rows.cast<Map<String, dynamic>>());
    } catch (e) {
      if (mounted) setState(() => message = _problem(e));
    }
  }

  Future<void> _revoke(String id) async {
    try {
      await widget.request('POST', '/v1/auth/sessions/$id/revoke');
      await _load();
    } catch (e) {
      if (mounted) setState(() => message = _problem(e));
    }
  }

  Future<void> _changePassword() async {
    if (next.text.length < 10 || next.text != confirm.text) {
      setState(
        () => message = next.text.length < 10
            ? 'Use at least 10 characters.'
            : 'The new passwords do not match.',
      );
      return;
    }
    try {
      await widget.request('POST', '/v1/auth/password', {
        'current': current.text,
        'new': next.text,
      });
      current.clear();
      next.clear();
      confirm.clear();
      setState(
        () => message = 'Password changed. Other devices were signed out.',
      );
      await _load();
    } catch (e) {
      if (mounted) {
        setState(
          () => message = e is NodeFailure && e.status == 403
              ? 'The current password is wrong.'
              : _problem(e),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.account.name),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${widget.account.username} · ${widget.account.workspaceName}'
              '${widget.account.admin ? ' · organization admin' : ''}',
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 14),
            const Text(
              'Signed-in devices',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final s in sessions)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.laptop_mac),
                title: Text(
                  '${s['device']}${s['current'] == true ? ' (this device)' : ''}',
                ),
                subtitle: Text('Active ${_ago(s['last_seen'] as int)}'),
                trailing: s['current'] == true
                    ? null
                    : TextButton(
                        onPressed: () => _revoke(s['id'] as String),
                        child: const Text('Sign out'),
                      ),
              ),
            const SizedBox(height: 14),
            const Text(
              'Change password',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            TextField(
              controller: current,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current password'),
            ),
            TextField(
              controller: next,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password'),
            ),
            TextField(
              controller: confirm,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Confirm new password',
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _changePassword,
              child: const Text('Change password'),
            ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(message!),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}

/// Shows a one-time code with copy and the instructions to use it.
Future<void> _showCode(
  BuildContext context,
  String title,
  String code,
  String instructions,
) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          code,
          key: const Key('issued-code'),
          style: const TextStyle(
            fontSize: 22,
            fontFamily: 'Menlo',
            letterSpacing: 1.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(instructions),
        const SizedBox(height: 4),
        const Text(
          'It is shown only once. Share it privately.',
          style: TextStyle(color: Colors.black54, fontSize: 12),
        ),
      ],
    ),
    actions: [
      TextButton.icon(
        onPressed: () => Clipboard.setData(ClipboardData(text: code)),
        icon: const Icon(Icons.copy, size: 16),
        label: const Text('Copy'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ],
  ),
);

/// Organization admins: people, invitations, password resets, disabling
/// accounts and every signed-in device.
class PeopleAdmin extends StatefulWidget {
  const PeopleAdmin({super.key, required this.request, required this.account});
  final NodeRequest request;
  final Account account;

  @override
  State<PeopleAdmin> createState() => _PeopleAdminState();
}

class _PeopleAdminState extends State<PeopleAdmin> {
  List<Map<String, dynamic>> people = [];
  List<Map<String, dynamic>> sessions = [];
  String? message;
  final newName = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.request(
        'GET',
        '/v1/admin/people',
      ) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        people = (data['people'] as List).cast<Map<String, dynamic>>();
        sessions = (data['sessions'] as List).cast<Map<String, dynamic>>();
      });
    } catch (e) {
      if (mounted) setState(() => message = _problem(e));
    }
  }

  Future<void> _invite({String? actor, String? name}) async {
    try {
      final issued = await widget.request('POST', '/v1/admin/invites', {
        'actor': ?actor,
        'name': ?name,
      }) as Map<String, dynamic>;
      await _load();
      if (!mounted) return;
      final reset = issued['purpose'] == 'reset';
      await _showCode(
        context,
        reset ? 'Password reset code' : 'Invitation code',
        issued['code'] as String,
        reset
            ? 'They choose "I have a code" on the sign-in screen and set a new password. All their devices are signed out. Valid for 7 days.'
            : 'They choose "I have a code" on the sign-in screen, then pick a username and password. Valid for 7 days.',
      );
    } catch (e) {
      if (mounted) setState(() => message = _problem(e));
    }
  }

  Future<void> _setDisabled(String actor, bool disabled) async {
    try {
      await widget.request('POST', '/v1/admin/people/$actor/state', {
        'disabled': disabled,
      });
      await _load();
    } catch (e) {
      if (mounted) setState(() => message = _problem(e));
    }
  }

  Future<void> _revoke(String id) async {
    try {
      await widget.request('POST', '/v1/auth/sessions/$id/revoke');
      await _load();
    } catch (e) {
      if (mounted) setState(() => message = _problem(e));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('People & invitations'),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final p in people)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${p['name']}${p['admin'] == true ? ' · admin' : ''}',
                ),
                subtitle: Text(
                  p['username'] == null
                      ? (p['invite_pending'] == true
                            ? 'Invitation pending'
                            : 'No account')
                      : '${p['username']} · ${p['sessions']} device(s)'
                            '${p['disabled'] == true ? ' · disabled' : ''}',
                ),
                trailing: Wrap(
                  spacing: 4,
                  children: [
                    TextButton(
                      onPressed: () => _invite(actor: p['id'] as String),
                      child: Text(
                        p['username'] == null ? 'Invite' : 'Reset password',
                      ),
                    ),
                    if (p['username'] != null &&
                        p['id'] != widget.account.actor)
                      TextButton(
                        onPressed: () => _setDisabled(
                          p['id'] as String,
                          p['disabled'] != true,
                        ),
                        child: Text(
                          p['disabled'] == true ? 'Enable' : 'Disable',
                        ),
                      ),
                  ],
                ),
              ),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: newName,
                    decoration: const InputDecoration(
                      labelText: 'Add someone new (full name)',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () {
                    final name = newName.text.trim();
                    if (name.isEmpty) return;
                    newName.clear();
                    _invite(name: name);
                  },
                  child: const Text('Add & invite'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            const Text(
              'Signed-in devices',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            for (final s in sessions)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.devices_outlined),
                title: Text('${s['name']} · ${s['device']}'),
                subtitle: Text('Active ${_ago(s['last_seen'] as int)}'),
                trailing: s['current'] == true
                    ? const Text('This device')
                    : TextButton(
                        onPressed: () => _revoke(s['id'] as String),
                        child: const Text('Sign out'),
                      ),
              ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(message!),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}

/// Organization admins: the company name and the nodes that follow this
/// master for sign-in.
class CompanyAdmin extends StatefulWidget {
  const CompanyAdmin({super.key, required this.request, required this.account});
  final NodeRequest request;
  final Account account;

  @override
  State<CompanyAdmin> createState() => _CompanyAdminState();
}

class _CompanyAdminState extends State<CompanyAdmin> {
  late final name = TextEditingController(text: widget.account.workspaceName);
  final nodeName = TextEditingController();
  List<Map<String, dynamic>> nodes = [];
  String? message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await widget.request('GET', '/v1/admin/nodes') as List;
      if (mounted) setState(() => nodes = rows.cast<Map<String, dynamic>>());
    } catch (e) {
      if (mounted) setState(() => message = _problem(e));
    }
  }

  Future<void> _rename() async {
    try {
      await widget.request('POST', '/v1/admin/workspace', {
        'name': name.text.trim(),
      });
      if (mounted) {
        setState(() => message = 'Saved. It shows after the next sign-in.');
      }
    } catch (e) {
      if (mounted) setState(() => message = _problem(e));
    }
  }

  Future<void> _addNode() async {
    final label = nodeName.text.trim();
    if (label.isEmpty) return;
    try {
      final issued = await widget.request('POST', '/v1/admin/nodes', {
        'name': label,
      }) as Map<String, dynamic>;
      nodeName.clear();
      await _load();
      if (!mounted) return;
      await _showCode(
        context,
        'Join code for $label',
        issued['code'] as String,
        'On the other node, with its database set in MONASTACK_DB, run:\n'
            'monastack-office-node join http://127.0.0.1:<master port>\n'
            'and paste the code. Valid for one hour. For another machine, '
            'forward the master port over SSH first.',
      );
    } catch (e) {
      if (mounted) setState(() => message = _problem(e));
    }
  }

  Future<void> _revokeNode(String id) async {
    try {
      await widget.request('POST', '/v1/admin/nodes/$id/revoke');
      await _load();
    } catch (e) {
      if (mounted) setState(() => message = _problem(e));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Company & nodes'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Company name',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(onPressed: _rename, child: const Text('Save')),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Member nodes',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const Text(
              'Member nodes check sign-ins with this node\'s key and pull people and revocations every few seconds. Their chat and records stay on that node.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            for (final n in nodes)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dns_outlined),
                title: Text(n['name'] as String),
                subtitle: Text(
                  n['revoked'] == true
                      ? 'Revoked'
                      : n['joined'] == null
                      ? 'Waiting to join'
                      : n['last_sync'] == null
                      ? 'Joined'
                      : 'Last sync ${_ago(n['last_sync'] as int)}',
                ),
                trailing: n['revoked'] == true
                    ? null
                    : TextButton(
                        onPressed: () => _revokeNode(n['id'] as String),
                        child: const Text('Revoke'),
                      ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: nodeName,
                    decoration: const InputDecoration(
                      labelText: 'New node name',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _addNode,
                  child: const Text('Create join code'),
                ),
              ],
            ),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(message!),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
