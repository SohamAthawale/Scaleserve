import 'dart:convert';

import 'package:http/http.dart' as http;

class BackendRuntimeSyncService {
  BackendRuntimeSyncService({
    String baseUrl = 'http://localhost:8080',
    String workspaceSlug = 'default',
    http.Client? client,
  }) : _baseUrl = baseUrl,
       _workspaceSlug = workspaceSlug,
       _client = client ?? http.Client();

  final String _baseUrl;
  final String _workspaceSlug;
  final http.Client _client;

  Future<void> syncSettings({required Map<String, Object?> settings}) async {
    await _post('/sync/settings', <String, Object?>{
      'workspaceSlug': _workspaceSlug,
      'settings': settings,
    });
  }

  Future<void> syncMachineSnapshot({
    required Map<String, Object?> snapshotPayload,
  }) async {
    await _post('/sync/machine-snapshot', <String, Object?>{
      'workspaceSlug': _workspaceSlug,
      ...snapshotPayload,
    });
  }

  Future<void> syncCommandLog({
    required Map<String, Object?> commandLogPayload,
  }) async {
    await _post('/sync/command-log', <String, Object?>{
      'workspaceSlug': _workspaceSlug,
      ...commandLogPayload,
    });
  }

  Future<void> syncRemoteState({
    required List<Map<String, Object?>> profiles,
    required List<Map<String, Object?>> recentRuns,
  }) async {
    await _post('/sync/remote-state', <String, Object?>{
      'workspaceSlug': _workspaceSlug,
      'profiles': profiles,
      'recentRuns': recentRuns,
    });
  }

  Future<void> _post(String route, Map<String, Object?> payload) async {
    final response = await _client.post(
      _route(route),
      headers: _jsonHeaders(),
      body: jsonEncode(payload),
    );

    if (response.statusCode == 200 || response.statusCode == 201) {
      return;
    }

    throw StateError(
      _extractMessage(
        response.body,
        fallback: 'Runtime sync failed for $route.',
      ),
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

  String _extractMessage(String responseText, {required String fallback}) {
    try {
      final decoded = jsonDecode(responseText);
      if (decoded is Map<String, dynamic>) {
        final message = (decoded['message'] ?? decoded['detail'] ?? '')
            .toString()
            .trim();
        if (message.isNotEmpty) {
          return message;
        }
      }
    } catch (_) {
      // Ignore decode failures and use fallback.
    }
    return fallback;
  }
}
