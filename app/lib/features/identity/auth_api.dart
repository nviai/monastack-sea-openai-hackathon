import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A refused identity request, with the node's explanation.
class AuthFailure implements Exception {
  const AuthFailure(this.status, this.message);
  final int status;
  final String message;

  /// Short text for people, by status.
  String get friendly => switch (status) {
    0 => 'The local node is not reachable.',
    401 => 'Wrong username or password.',
    403 => message.isEmpty ? 'Not allowed.' : _sentence(message),
    429 => 'Too many attempts. Try again in a few minutes.',
    502 => 'The master node is not reachable. Try again later.',
    _ => message.isEmpty ? 'Request failed ($status).' : _sentence(message),
  };

  static String _sentence(String text) =>
      '${text[0].toUpperCase()}${text.substring(1)}.';

  @override
  String toString() => 'AuthFailure($status, $message)';
}

/// The result of setup, sign-in, an invitation or a refresh.
class SignedIn {
  SignedIn.fromJson(Map<String, dynamic> json)
    : accessToken = json['access_token'] as String,
      expiresIn = json['expires_in'] as int,
      refreshToken = json['refresh_token'] as String,
      session = json['session'] as String,
      actor = json['actor'] as String,
      name = json['name'] as String,
      username = json['username'] as String,
      admin = json['admin'] as bool,
      workspaceId = (json['workspace'] as Map)['id'] as String,
      workspaceName = (json['workspace'] as Map)['name'] as String;

  final String accessToken;
  final int expiresIn;
  final String refreshToken;
  final String session;
  final String actor;
  final String name;
  final String username;
  final bool admin;
  final String workspaceId;
  final String workspaceName;
}

/// HTTP client for the node's identity endpoints (ADR 0008). Only loopback
/// nodes are used; a remote master is reached by the node, not the app.
class AuthApi {
  AuthApi({required this.port, HttpClient? client})
    : _client =
          client ??
          (HttpClient()..connectionTimeout = const Duration(seconds: 3));

  final int port;
  final HttpClient _client;

  /// How this device is labelled in the device list.
  static String get deviceName {
    final host = Platform.localHostname.replaceAll(RegExp(r'\.local$'), '');
    return host.isEmpty ? 'This Mac' : host;
  }

  static Map<String, String> get device => {
    'device': deviceName,
    'platform': Platform.operatingSystem,
  };

  Future<dynamic> call(
    String method,
    String path, {
    Object? body,
    String? bearer,
  }) async {
    final HttpClientResponse response;
    try {
      final request = await _client
          .openUrl(method, Uri.parse('http://127.0.0.1:$port$path'))
          .timeout(const Duration(seconds: 4));
      if (bearer != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      // Sign-in hashes the password on the node, and member nodes forward
      // to the master, so allow more than for ordinary reads.
      response = await request.close().timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const AuthFailure(0, 'timeout');
    } on IOException {
      throw const AuthFailure(0, 'unreachable');
    }
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode >= 400) {
      throw AuthFailure(response.statusCode, text.trim());
    }
    return text.isEmpty ? null : jsonDecode(text);
  }

  Future<Map<String, dynamic>> workspace() async =>
      await call('GET', '/v1/workspace') as Map<String, dynamic>;

  Future<SignedIn> setup({
    required String code,
    required String company,
    String? actor,
    String? name,
    required String username,
    required String password,
  }) async => SignedIn.fromJson(
    await call(
      'POST',
      '/v1/setup',
      body: {
        'code': code,
        'company': company,
        'actor': ?actor,
        'name': ?name,
        'username': username,
        'password': password,
        ...device,
      },
    ) as Map<String, dynamic>,
  );

  Future<SignedIn> login(String username, String password) async =>
      SignedIn.fromJson(
        await call(
          'POST',
          '/v1/auth/login',
          body: {'username': username, 'password': password, ...device},
        ) as Map<String, dynamic>,
      );

  Future<SignedIn> acceptInvite({
    required String code,
    String? username,
    required String password,
  }) async => SignedIn.fromJson(
    await call(
      'POST',
      '/v1/auth/invite',
      body: {
        'code': code,
        'username': ?username,
        'password': password,
        ...device,
      },
    ) as Map<String, dynamic>,
  );

  Future<SignedIn> refresh(String refreshToken) async => SignedIn.fromJson(
    await call(
      'POST',
      '/v1/auth/refresh',
      body: {'refresh_token': refreshToken},
    ) as Map<String, dynamic>,
  );

  Future<void> logout(String accessToken) =>
      call('POST', '/v1/auth/logout', bearer: accessToken);
}
