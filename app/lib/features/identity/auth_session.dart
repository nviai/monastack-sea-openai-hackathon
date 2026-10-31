import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:monastack/features/identity/auth_api.dart';
import 'package:monastack/features/identity/credential_store.dart';

/// Who is using the app.
@immutable
class Account {
  const Account({
    required this.actor,
    required this.name,
    required this.username,
    required this.admin,
    required this.session,
    required this.workspaceId,
    required this.workspaceName,
  });

  factory Account.of(SignedIn s) => Account(
    actor: s.actor,
    name: s.name,
    username: s.username,
    admin: s.admin,
    session: s.session,
    workspaceId: s.workspaceId,
    workspaceName: s.workspaceName,
  );

  final String actor;
  final String name;
  final String username;
  final bool admin;
  final String session;
  final String workspaceId;
  final String workspaceName;
}

/// Holds this device's sign-in. Access tokens are short-lived and renewed
/// with a rotating refresh token, which is kept in the keychain so the app
/// signs in again on the next launch. A local device token (from
/// `office-node enroll`) is supported for operators and tests and is never
/// stored.
class AuthSession extends ChangeNotifier {
  AuthSession({
    required this.api,
    required this.store,
    this.now = DateTime.now,
  });

  final AuthApi api;
  final CredentialStore store;
  final DateTime Function() now;

  Account? _account;
  String? _access;
  DateTime _accessExpires = DateTime.fromMillisecondsSinceEpoch(0);
  String? _refresh;
  String? _deviceToken;
  Future<bool>? _refreshing;

  /// Why the last session ended, for the sign-in screen.
  String? notice;

  Account? get account => _account;
  bool get signedIn => _account != null;
  bool get usingDeviceToken => _deviceToken != null;
  bool get active => signedIn || usingDeviceToken;

  String get _storeKey => 'monastack.session.${api.host}:${api.port}';

  /// Signs in again with the stored refresh token, if any. Returns whether a
  /// session is active afterwards.
  Future<bool> restore() async {
    final String? stored;
    try {
      stored = await store.read(_storeKey);
    } catch (_) {
      return false;
    }
    if (stored == null) return false;
    try {
      final saved = jsonDecode(stored) as Map<String, dynamic>;
      _refresh = saved['refresh_token'] as String;
    } catch (_) {
      await _forget();
      return false;
    }
    return refreshNow();
  }

  /// Adopts the result of setup, sign-in or an invitation.
  Future<void> adopt(SignedIn result) async {
    _deviceToken = null;
    notice = null;
    await _apply(result);
  }

  void useDeviceToken(String token) {
    _clear();
    _deviceToken = token;
    notifyListeners();
  }

  /// The bearer credential for the next request, renewing the access token
  /// shortly before it expires.
  Future<String> bearer() async {
    final device = _deviceToken;
    if (device != null) return device;
    if (_access == null) throw StateError('not signed in');
    if (now().isAfter(_accessExpires.subtract(const Duration(seconds: 60)))) {
      await refreshNow();
    }
    final access = _access;
    if (access == null) throw StateError('session ended');
    return access;
  }

  /// Renews the access token. Concurrent callers share one request, because
  /// presenting a refresh token twice ends the session on the node.
  Future<bool> refreshNow() =>
      _refreshing ??= _refreshOnce().whenComplete(() => _refreshing = null);

  Future<bool> _refreshOnce() async {
    final refresh = _refresh;
    if (refresh == null) return false;
    try {
      await _apply(await api.refresh(refresh));
      return true;
    } on AuthFailure catch (e) {
      if (e.status == 401 || e.status == 403) {
        // The session was revoked, expired or the account disabled.
        await _forget();
        _clear();
        notice = 'Your session ended. Sign in again.';
        notifyListeners();
      }
      return false;
    }
  }

  /// Ends the session on the node (best effort) and forgets it here.
  Future<void> signOut() async {
    final access = _access;
    if (access != null) {
      try {
        await api.logout(access);
      } catch (_) {
        // The keychain entry is removed regardless; the node session
        // expires with its refresh token or can be revoked from a device list.
      }
    }
    await _forget();
    _clear();
    notice = null;
    notifyListeners();
  }

  Future<void> _apply(SignedIn result) async {
    _access = result.accessToken;
    _accessExpires = now().add(Duration(seconds: result.expiresIn));
    _refresh = result.refreshToken;
    _account = Account.of(result);
    try {
      await store.write(
        _storeKey,
        jsonEncode({
          'refresh_token': result.refreshToken,
          'workspace': result.workspaceId,
          'username': result.username,
        }),
      );
    } catch (_) {
      notice = 'Could not save the sign-in to the keychain; you will need to sign in again next time.';
    }
    notifyListeners();
  }

  Future<void> _forget() async {
    try {
      await store.delete(_storeKey);
    } catch (_) {}
  }

  void _clear() {
    _account = null;
    _access = null;
    _refresh = null;
    _deviceToken = null;
    _accessExpires = DateTime.fromMillisecondsSinceEpoch(0);
  }
}
