import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_user.dart';

class BackendAuthResult {
  const BackendAuthResult({
    required this.success,
    required this.message,
    this.user,
    this.token,
    this.mfaRequired = false,
    this.maskedEmail,
  });

  final bool success;
  final String message;
  final AppUser? user;
  final String? token;
  final bool mfaRequired;
  final String? maskedEmail;
}

class BackendAuthService {
  BackendAuthService({
    String baseUrl = 'http://localhost:8080',
    http.Client? client,
  }) : _baseUrl = baseUrl,
       _client = client ?? http.Client();

  final String _baseUrl;
  final http.Client _client;

  Future<bool> hasUsers() async {
    final response = await _get('/auth/status');
    final body = _decodeJson(response.body);
    if (response.statusCode != 200) {
      throw StateError(
        _extractMessage(body, fallback: 'Could not load auth status.'),
      );
    }
    return body['hasUsers'] == true;
  }

  Future<BackendAuthResult> bootstrapFirstUser({
    required String email,
    required String password,
    required bool mfaEnabled,
  }) async {
    final response = await _post('/auth/bootstrap', <String, Object?>{
      'email': email,
      'password': password,
      'mfaEnabled': mfaEnabled,
    });

    final body = _decodeJson(response.body);
    if (response.statusCode != 200 && response.statusCode != 201) {
      final fallbackMessage = response.statusCode == 409
          ? 'Bootstrap already completed. Sign in with your existing account.'
          : 'Could not create account.';
      return BackendAuthResult(
        success: false,
        message: _extractMessage(body, fallback: fallbackMessage),
      );
    }

    final user = _parseUser(body['user']);
    return BackendAuthResult(
      success: true,
      message: 'Bootstrap successful.',
      user: user,
      token: (body['token'] ?? '').toString(),
    );
  }

  Future<BackendAuthResult> login({
    required String email,
    required String password,
  }) async {
    final response = await _post('/auth/login', <String, Object?>{
      'email': email,
      'password': password,
    });
    final body = _decodeJson(response.body);

    if (response.statusCode != 200) {
      return BackendAuthResult(
        success: false,
        message: _extractMessage(body, fallback: 'Sign-in failed.'),
      );
    }

    final mfaRequired = body['mfaRequired'] == true;
    return BackendAuthResult(
      success: true,
      message: 'Login response received.',
      mfaRequired: mfaRequired,
      maskedEmail: (body['maskedEmail'] ?? '').toString().trim().isEmpty
          ? null
          : (body['maskedEmail'] ?? '').toString(),
      token: (body['token'] ?? '').toString().trim().isEmpty
          ? null
          : (body['token'] ?? '').toString(),
      user: _parseUser(body['user']),
    );
  }

  Future<BackendAuthResult> requestLoginMfaOtp({required String email}) async {
    final response = await _post('/auth/login/mfa/request', <String, Object?>{
      'email': email,
    });
    final body = _decodeJson(response.body);

    if (response.statusCode != 200) {
      return BackendAuthResult(
        success: false,
        message: _extractMessage(body, fallback: 'Could not send MFA OTP.'),
      );
    }

    return BackendAuthResult(
      success: true,
      message: _extractMessage(body, fallback: 'MFA OTP sent.'),
      maskedEmail: (body['maskedEmail'] ?? '').toString().trim().isEmpty
          ? null
          : (body['maskedEmail'] ?? '').toString(),
    );
  }

  Future<BackendAuthResult> verifyMfaOtp({
    required String email,
    required String otp,
  }) async {
    final response = await _post('/auth/login/mfa/verify', <String, Object?>{
      'email': email,
      'otp': otp,
    });
    final body = _decodeJson(response.body);

    if (response.statusCode != 200) {
      return BackendAuthResult(
        success: false,
        message: _extractMessage(body, fallback: 'OTP verification failed.'),
      );
    }

    return BackendAuthResult(
      success: true,
      message: 'MFA verified.',
      token: (body['token'] ?? '').toString(),
      user: _parseUser(body['user']),
    );
  }

  Future<BackendAuthResult> requestForgotPasswordOtp({
    required String email,
  }) async {
    final response = await _post(
      '/auth/forgot-password/request',
      <String, Object?>{'email': email},
    );
    final body = _decodeJson(response.body);
    if (response.statusCode != 200) {
      return BackendAuthResult(
        success: false,
        message: _extractMessage(body, fallback: 'Could not send reset OTP.'),
      );
    }
    return BackendAuthResult(
      success: true,
      message: _extractMessage(body, fallback: 'Password reset OTP sent.'),
      maskedEmail: (body['maskedEmail'] ?? '').toString().trim().isEmpty
          ? null
          : (body['maskedEmail'] ?? '').toString(),
    );
  }

  Future<BackendAuthResult> resetPassword({
    required String email,
    required String otp,
    required String newPassword,
  }) async {
    final response = await _post(
      '/auth/forgot-password/reset',
      <String, Object?>{'email': email, 'otp': otp, 'newPassword': newPassword},
    );
    final body = _decodeJson(response.body);
    if (response.statusCode != 200) {
      return BackendAuthResult(
        success: false,
        message: _extractMessage(body, fallback: 'Password reset failed.'),
      );
    }
    return BackendAuthResult(
      success: true,
      message: _extractMessage(body, fallback: 'Password reset successful.'),
    );
  }

  Future<http.Response> _get(String route) {
    return _client.get(_route(route), headers: _jsonHeaders());
  }

  Future<http.Response> _post(String route, Map<String, Object?> payload) {
    return _client.post(
      _route(route),
      headers: _jsonHeaders(),
      body: jsonEncode(payload),
    );
  }

  Uri _route(String route) {
    final normalizedBase = _baseUrl.endsWith('/')
        ? _baseUrl.substring(0, _baseUrl.length - 1)
        : _baseUrl;
    final normalizedRoute = route.startsWith('/') ? route : '/$route';
    return Uri.parse('$normalizedBase$normalizedRoute');
  }

  Map<String, String> _jsonHeaders() {
    return const <String, String>{'Content-Type': 'application/json'};
  }

  Map<String, dynamic> _decodeJson(String text) {
    if (text.trim().isEmpty) {
      return <String, dynamic>{};
    }
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return <String, dynamic>{};
  }

  String _extractMessage(
    Map<String, dynamic> body, {
    required String fallback,
  }) {
    final value = (body['message'] ?? body['detail'] ?? '').toString().trim();
    return value.isEmpty ? fallback : value;
  }

  AppUser? _parseUser(dynamic payload) {
    if (payload is! Map<String, dynamic>) {
      return null;
    }
    return AppUser(
      id: (payload['id'] ?? '').toString(),
      username: (payload['username'] ?? '').toString(),
      role: (payload['role'] ?? 'operator').toString(),
      isActive: payload['isActive'] == true,
      mfaEnabled: payload['mfaEnabled'] == true,
      activeWorkspaceId:
          (payload['activeWorkspaceId'] ?? '').toString().trim().isEmpty
          ? null
          : (payload['activeWorkspaceId'] ?? '').toString().trim(),
      email: (payload['email'] ?? '').toString().trim().isEmpty
          ? null
          : (payload['email'] ?? '').toString().trim(),
      createdAtIso: (payload['createdAtIso'] ?? '').toString(),
      updatedAtIso: (payload['updatedAtIso'] ?? '').toString(),
      lastLoginAtIso:
          (payload['lastLoginAtIso'] ?? '').toString().trim().isEmpty
          ? null
          : (payload['lastLoginAtIso'] ?? '').toString(),
    );
  }
}
