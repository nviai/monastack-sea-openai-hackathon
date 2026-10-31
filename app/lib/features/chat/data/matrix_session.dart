import 'dart:convert';

import 'package:matrix/matrix.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:monastack/features/identity/credential_store.dart';
import 'package:monastack/shared/node_request.dart';
import 'package:monastack/shared/office_endpoint.dart';

/// The SDK database is intentionally ephemeral: tokens only persist in Keychain,
/// and revoked content cannot survive a restart in an offline disk cache.
class MatrixSession {
  MatrixSession({
    required this.request,
    required this.store,
    required this.node,
    required this.actor,
    this.httpClient,
  });
  final NodeRequest request;
  final CredentialStore store;
  final String node, actor;
  Client? client;
  final http.Client? httpClient;
  int _generation = 0;
  String get key =>
      'monastack.matrix.${Uri.encodeComponent(node)}.${Uri.encodeComponent(actor)}';

  /// Kept apart from the session so a re-login reuses the same Synapse device.
  String get deviceKey => '$key.device';

  Future<Client?> open() async {
    final generation = _generation;
    final Map config;
    try {
      config = await request('GET', '/v1/chat/config') as Map;
    } on NodeFailure catch (e) {
      // A node on code without chat has no such route: same as chat disabled.
      if (e.status == 404) return null;
      rethrow;
    }
    if (generation != _generation || config['enabled'] != true) return null;
    final home = parseOfficeEndpoint(config['homeserver_url']);
    if (home == null) throw const FormatException('Invalid chat address');
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    final database = await MatrixSdkDatabase.init(
      'monastack',
      database: db,
      sqfliteFactory: databaseFactoryFfi,
    );
    if (generation != _generation) {
      await database.close();
      return null;
    }
    final sdk = client = Client(
      'Monastack',
      database: database,
      supportedLoginTypes: {'org.matrix.login.jwt'},
      logLevel: Level.wtf,
      httpClient: httpClient,
    );
    // Encryption is deliberately off. No olm/vodozemac native runtime is loaded.
    sdk.homeserver = home;
    final stored = await store.read(key);
    Map<String, dynamic>? saved;
    if (stored != null) {
      try {
        saved = jsonDecode(stored) as Map<String, dynamic>;
        if (![
          'homeserver',
          'access_token',
          'user_id',
          'device_id',
        ].every((key) => saved![key] is String)) {
          throw const FormatException('Invalid saved chat session');
        }
      } catch (_) {
        saved = null;
        await store.delete(key);
      }
    }
    if (saved != null && saved['homeserver'] == home.toString()) {
      try {
        sdk.accessToken = saved['access_token'] as String;
        // Validate before starting sync; a revoked device must obtain a new JWT.
        final who = await sdk.getTokenOwner();
        if (who.userId != saved['user_id']) {
          await store.delete(key);
          throw StateError('Wrong chat user');
        }
        await sdk.init(
          newToken: saved['access_token'] as String,
          newUserID: who.userId,
          newDeviceID: saved['device_id'] as String,
          newHomeserver: home,
          waitForFirstSync: false,
        );
        if (generation != _generation) throw StateError('Chat session ended');
        return sdk;
      } on MatrixException catch (e) {
        if (e.errcode != 'M_UNKNOWN_TOKEN' && e.errcode != 'M_FORBIDDEN') {
          rethrow;
        }
        await store.delete(key);
      }
    }
    final session = await request('POST', '/v1/chat/session', {
      'device_name': 'Monastack macOS',
    }) as Map;
    final result = await sdk.login(
      'org.matrix.login.jwt',
      token: session['login_token'] as String,
      deviceId: await store.read(deviceKey),
      initialDeviceDisplayName: 'Monastack macOS',
    );
    if (generation != _generation || result.userId != session['user_id']) {
      await sdk.logout();
      throw StateError('Wrong chat user');
    }
    await store.write(deviceKey, result.deviceId);
    await store.write(
      key,
      jsonEncode({
        'homeserver': home.toString(),
        'access_token': result.accessToken,
        'device_id': result.deviceId,
        'user_id': result.userId,
      }),
    );
    if (generation != _generation) {
      await store.delete(key);
      throw StateError('Chat session ended');
    }
    return sdk;
  }

  Future<void> logout() async {
    _generation++;
    // Forget locally even when the homeserver is offline.
    try {
      await store.delete(key);
      await store.delete(deviceKey);
    } finally {
      try {
        await client?.logout();
      } catch (_) {
        /* device expiry/revoke handles offline */
      }
      await close();
    }
  }

  Future<void> close() async {
    _generation++;
    final sdk = client;
    client = null;
    await sdk?.dispose();
  }
}
