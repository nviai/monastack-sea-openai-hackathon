import 'dart:io';

import 'package:flutter/material.dart';

import 'package:monastack/features/identity/auth_api.dart';
import 'package:monastack/features/identity/auth_session.dart';

/// Signs in to the local node: with a username and password, by setting up
/// the company on a new node, with an invitation or reset code, or with a
/// local device token.
class SignInPanel extends StatefulWidget {
  const SignInPanel({
    super.key,
    required this.auth,
    required this.token,
    required this.onDeviceToken,
    required this.status,
    this.defaultCompany = '',
  });

  final AuthSession auth;

  /// Device token field and its connect action (operators and tests).
  final TextEditingController token;
  final VoidCallback onDeviceToken;
  final String status;
  final String defaultCompany;

  @override
  State<SignInPanel> createState() => _SignInPanelState();
}

enum _Mode { password, token }

class _SignInPanelState extends State<SignInPanel> {
  final username = TextEditingController();
  final password = TextEditingController();
  Map<String, dynamic>? workspace;
  String? error;
  bool busy = false;
  bool loading = true;
  late _Mode mode = Platform.environment['MONASTACK_SIGN_IN'] == 'token'
      ? _Mode.token
      : _Mode.password;

  AuthApi get api => widget.auth.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final info = await api.workspace();
      if (!mounted) return;
      setState(() => workspace = info);
    } on AuthFailure catch (e) {
      if (mounted) setState(() => error = e.friendly);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    username.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await api.login(username.text.trim(), password.text);
      password.clear();
      await widget.auth.adopt(result);
    } on AuthFailure catch (e) {
      if (mounted) setState(() => error = e.friendly);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _dialog(Widget dialog) async {
    final result = await showDialog<SignedIn>(
      context: context,
      builder: (_) => dialog,
    );
    if (result != null) await widget.auth.adopt(result);
  }

  @override
  Widget build(BuildContext context) {
    final info = workspace;
    final initialized = info?['initialized'] == true;
    const small = TextStyle(fontSize: 11, color: Colors.black54);
    if (mode == _Mode.token) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: widget.token,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Enrollment token',
              isDense: true,
            ),
          ),
          Row(
            children: [
              TextButton(
                onPressed: widget.onDeviceToken,
                child: const Text('Connect'),
              ),
              Expanded(
                child: Text(
                  widget.status,
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          TextButton(
            onPressed: () => setState(() => mode = _Mode.password),
            child: const Text('Sign in with a password instead'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.auth.notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              widget.auth.notice!,
              style: const TextStyle(fontSize: 11, color: Color(0xffb3261e)),
            ),
          ),
        if (loading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(minHeight: 2),
          )
        else if (info == null) ...[
          Text(error ?? 'The local node is not reachable.', style: small),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ] else if (!initialized) ...[
          const Text(
            'This node has no company yet.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 4),
          FilledButton.icon(
            onPressed: () => _dialog(
              SetupDialog(
                api: api,
                people: (info['people'] as List? ?? const [])
                    .cast<Map<String, dynamic>>(),
                company: widget.defaultCompany,
              ),
            ).then((_) => _load()),
            icon: const Icon(Icons.apartment, size: 18),
            label: const Text('Set up company'),
          ),
          const SizedBox(height: 2),
          const Text(
            'Needs the setup code the node printed when it started.',
            style: small,
          ),
        ] else ...[
          Text(
            'Sign in to ${(info['workspace'] as Map?)?['name'] ?? 'your company'}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          AutofillGroup(
            child: Column(
              children: [
                TextField(
                  controller: username,
                  autofillHints: const [AutofillHints.username],
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    prefixIcon: Icon(Icons.person_outline, size: 19),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _signIn(),
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    prefixIcon: Icon(Icons.lock_outline, size: 19),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              FilledButton(
                onPressed: busy ? null : _signIn,
                child: Text(busy ? 'Signing in…' : 'Sign in'),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: TextButton(
                  onPressed: () => _dialog(InviteDialog(api: api)),
                  child: const Text(
                    'I have a code',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
          if (info['role'] == 'member')
            const Text(
              'Sign-in is checked by this workspace\'s master node.',
              style: small,
            ),
        ],
        if (error != null && info != null)
          Text(
            error!,
            style: const TextStyle(fontSize: 11, color: Color(0xffb3261e)),
          ),
        TextButton(
          style: TextButton.styleFrom(padding: EdgeInsets.zero),
          onPressed: () => setState(() => mode = _Mode.token),
          child: const Text(
            'Use a device token',
            style: TextStyle(fontSize: 11),
          ),
        ),
      ],
    );
  }
}

String? _passwordProblem(String password, String confirm) {
  if (password.length < 10) return 'Use at least 10 characters.';
  if (password != confirm) return 'The passwords do not match.';
  return null;
}

final _usernamePattern = RegExp(r'^[a-z0-9._-]{3,32}$');

/// Creates the company on a new node and its first admin. The node becomes
/// the workspace's identity master.
class SetupDialog extends StatefulWidget {
  const SetupDialog({
    super.key,
    required this.api,
    required this.people,
    this.company = '',
  });
  final AuthApi api;
  final List<Map<String, dynamic>> people;
  final String company;

  @override
  State<SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends State<SetupDialog> {
  late final company = TextEditingController(text: widget.company);
  final code = TextEditingController();
  final name = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
  final confirm = TextEditingController();
  String? person;
  String? error;
  bool busy = false;

  static const _someoneNew = '';

  Future<void> _submit() async {
    final problem = company.text.trim().isEmpty
        ? 'Enter the company name.'
        : person == null
        ? 'Choose who you are.'
        : person == _someoneNew && name.text.trim().isEmpty
        ? 'Enter your name.'
        : !_usernamePattern.hasMatch(username.text.trim())
        ? 'Username: 3-32 lowercase letters, digits, dot, dash or underscore.'
        : _passwordProblem(password.text, confirm.text);
    if (problem != null) {
      setState(() => error = problem);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.setup(
        code: code.text.trim(),
        company: company.text.trim(),
        actor: person == _someoneNew ? null : person,
        name: person == _someoneNew ? name.text.trim() : null,
        username: username.text.trim(),
        password: password.text,
      );
      if (mounted) Navigator.pop(context, result);
    } on AuthFailure catch (e) {
      if (mounted) {
        setState(
          () => error = e.status == 403
              ? 'Wrong setup code. Check the node\'s console, or run `monastack-office-node setup-code`.'
              : e.friendly,
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Set up your company'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This node becomes the master: it keeps the company\'s accounts, and other nodes sign in through it.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            TextField(
              controller: code,
              decoration: const InputDecoration(
                labelText: 'Setup code',
                helperText: 'Printed by the node when it started',
              ),
            ),
            TextField(
              controller: company,
              decoration: const InputDecoration(labelText: 'Company name'),
            ),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: person,
              decoration: const InputDecoration(labelText: 'Who are you?'),
              items: [
                for (final p in widget.people)
                  DropdownMenuItem(
                    value: p['id'] as String,
                    child: Text(
                      p['name'] as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                const DropdownMenuItem(
                  value: _someoneNew,
                  child: Text(
                    'Someone new',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: (value) => setState(() => person = value),
            ),
            if (person == _someoneNew)
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Your name'),
              ),
            TextField(
              controller: username,
              decoration: const InputDecoration(labelText: 'Username'),
            ),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Password',
                helperText: 'At least 10 characters',
              ),
            ),
            TextField(
              controller: confirm,
              obscureText: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(labelText: 'Confirm password'),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error!,
                  style: const TextStyle(color: Color(0xffb3261e)),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: busy ? null : _submit,
        child: Text(busy ? 'Creating…' : 'Create company'),
      ),
    ],
  );
}

/// Redeems an invitation (choose a username and password) or a reset code
/// (choose a new password).
class InviteDialog extends StatefulWidget {
  const InviteDialog({super.key, required this.api});
  final AuthApi api;

  @override
  State<InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<InviteDialog> {
  final code = TextEditingController();
  final username = TextEditingController();
  final password = TextEditingController();
  final confirm = TextEditingController();
  String? error;
  bool busy = false;

  Future<void> _submit() async {
    final name = username.text.trim();
    final problem = code.text.trim().isEmpty
        ? 'Enter the code you were given.'
        : name.isNotEmpty && !_usernamePattern.hasMatch(name)
        ? 'Username: 3-32 lowercase letters, digits, dot, dash or underscore.'
        : _passwordProblem(password.text, confirm.text);
    if (problem != null) {
      setState(() => error = problem);
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.acceptInvite(
        code: code.text.trim(),
        username: name.isEmpty ? null : name,
        password: password.text,
      );
      if (mounted) Navigator.pop(context, result);
    } on AuthFailure catch (e) {
      if (mounted) {
        setState(
          () => error = e.status == 400 && name.isEmpty
              ? 'This is an invitation: choose a username.'
              : e.friendly,
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Use an invitation or reset code'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: code,
            decoration: const InputDecoration(labelText: 'Code'),
          ),
          TextField(
            controller: username,
            decoration: const InputDecoration(
              labelText: 'Username',
              helperText: 'For a new account; leave empty for a password reset',
            ),
          ),
          TextField(
            controller: password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'New password',
              helperText: 'At least 10 characters',
            ),
          ),
          TextField(
            controller: confirm,
            obscureText: true,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(labelText: 'Confirm password'),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error!,
                style: const TextStyle(color: Color(0xffb3261e)),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: busy ? null : _submit,
        child: Text(busy ? 'Signing in…' : 'Continue'),
      ),
    ],
  );
}
