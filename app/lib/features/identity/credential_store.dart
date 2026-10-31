import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where a signed-in session's refresh token is kept between launches.
abstract class CredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// The macOS login keychain (Keychain on iOS, platform stores elsewhere).
/// The legacy file-based keychain is used on macOS so no Keychain Sharing
/// entitlement or provisioning profile is needed.
class KeychainCredentialStore implements CredentialStore {
  KeychainCredentialStore()
    : _storage = FlutterSecureStorage(
        mOptions: Platform.isMacOS
            ? const MacOsOptions(usesDataProtectionKeychain: false)
            : MacOsOptions.defaultOptions,
      );
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Forgets everything when the app exits. Used by tests.
class MemoryCredentialStore implements CredentialStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}
