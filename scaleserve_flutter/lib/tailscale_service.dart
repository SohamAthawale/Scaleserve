import 'dart:convert';
import 'dart:io';

class TailscaleService {
  Future<TailscaleSnapshot> fetchStatus() async {
    final jsonResult = await _runCommand(['status', '--json']);
    if (jsonResult.success) {
      try {
        final decoded = jsonDecode(jsonResult.stdout);
        if (decoded is Map<String, dynamic>) {
          return TailscaleSnapshot.fromJson(decoded);
        }
      } catch (_) {
        // Fallback handled below.
      }

      if (_looksLikeCliStartupFailure(jsonResult.stdout) ||
          _looksLikeCliStartupFailure(jsonResult.stderr)) {
        throw StateError(
          jsonResult.stderr.isNotEmpty ? jsonResult.stderr : jsonResult.stdout,
        );
      }
    }

    final plainResult = jsonResult.success
        ? jsonResult
        : await _runCommand(['status']);

    if (!plainResult.success) {
      throw StateError(
        'Could not read Tailscale status.\n'
        '${plainResult.stderr.isNotEmpty ? plainResult.stderr : plainResult.stdout}',
      );
    }

    if (_looksLikeCliStartupFailure(plainResult.stdout) ||
        _looksLikeCliStartupFailure(plainResult.stderr)) {
      throw StateError(
        plainResult.stderr.isNotEmpty ? plainResult.stderr : plainResult.stdout,
      );
    }

    return TailscaleSnapshot.fromPlainStatus(plainResult.stdout);
  }

  bool _looksLikeCliStartupFailure(String text) {
    final normalized = text.toLowerCase();
    return normalized.contains('the tailscale cli failed to start') ||
        normalized.contains('failed to load preferences');
  }

  Future<TailscaleCommandResult> connect({
    String? authKey,
    bool forceReauth = false,
    bool reset = false,
  }) {
    final args = <String>['up'];
    if (forceReauth) {
      args.add('--force-reauth');
    }
    if (reset) {
      args.add('--reset');
    }
    if (authKey != null && authKey.isNotEmpty) {
      args.addAll(['--auth-key', authKey]);
    }
    return _runCommand(args);
  }

  Future<TailscaleCommandResult> logout() {
    return _runCommand(['logout']);
  }

  Future<TailscaleCommandResult> disconnect() {
    return _runCommand(['down']);
  }

  Future<TailscaleCommandResult> _runCommand(List<String> args) async {
    Object? lastError;

    for (final executable in _candidateExecutables()) {
      try {
        final result = await Process.run(executable, args, runInShell: false);
        return TailscaleCommandResult(
          executable: executable,
          arguments: args,
          exitCode: result.exitCode,
          stdout: (result.stdout ?? '').toString().trim(),
          stderr: (result.stderr ?? '').toString().trim(),
        );
      } on ProcessException catch (error) {
        lastError = error;
      }
    }

    throw StateError(
      'Tailscale CLI was not found. Install Tailscale and ensure "tailscale" '
      'is available on PATH. Last error: $lastError',
    );
  }

  List<String> _candidateExecutables() {
    if (Platform.isMacOS) {
      return [
        'tailscale',
        '/usr/local/bin/tailscale',
        '/opt/homebrew/bin/tailscale',
        '/Applications/Tailscale.app/Contents/MacOS/Tailscale',
      ];
    }

    if (Platform.isWindows) {
      return [
        'tailscale.exe',
        r'C:\Program Files\Tailscale\tailscale.exe',
        r'C:\Program Files (x86)\Tailscale\tailscale.exe',
      ];
    }

    throw UnsupportedError(
      'This app supports only macOS and Windows for Tailscale desktop control.',
    );
  }
}

class TailscaleCommandResult {
  TailscaleCommandResult({
    required this.executable,
    required this.arguments,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final String executable;
  final List<String> arguments;
  final int exitCode;
  final String stdout;
  final String stderr;

  bool get success => exitCode == 0;

  String get commandString => '$executable ${arguments.join(' ')}'.trim();

  String get safeCommandString {
    final redacted = <String>[];
    for (var i = 0; i < arguments.length; i++) {
      final arg = arguments[i];
      if (arg == '--auth-key') {
        redacted.add('--auth-key');
        if (i + 1 < arguments.length) {
          redacted.add('***REDACTED***');
          i++;
        }
        continue;
      }

      if (arg.startsWith('--auth-key=')) {
        redacted.add('--auth-key=***REDACTED***');
        continue;
      }

      redacted.add(arg);
    }

    return '$executable ${redacted.join(' ')}'.trim();
  }
}

class TailscaleSnapshot {
  TailscaleSnapshot({
    required this.backendState,
    required this.isConnected,
    required this.selfName,
    required this.selfDnsName,
    required this.selfIpAddress,
    required this.loginName,
    required this.tailnetName,
    required this.magicDnsSuffix,
    required this.peers,
  });

  final String backendState;
  final bool isConnected;
  final String selfName;
  final String selfDnsName;
  final String selfIpAddress;
  final String loginName;
  final String tailnetName;
  final String magicDnsSuffix;
  final List<TailscalePeer> peers;

  factory TailscaleSnapshot.fromJson(Map<String, dynamic> json) {
    final backendState = _stringValue(
      json['BackendState'],
      fallback: 'Unknown',
    );
    final self = _mapValue(json['Self']);
    final selfIps = _listValue(self['TailscaleIPs']);
    final userProfile = _mapValue(self['UserProfile']);
    final users = _mapValue(json['User']);
    final currentTailnet = _mapValue(json['CurrentTailnet']);
    final magicDnsSuffix = _stringValue(
      json['MagicDNSSuffix'],
      fallback: 'Unknown tailnet',
    );

    final peers = <TailscalePeer>[];
    final peersJson = _mapValue(json['Peer']);
    for (final entry in peersJson.entries) {
      final peer = _mapValue(entry.value);
      final ipList = _listValue(peer['TailscaleIPs']);
      peers.add(
        TailscalePeer(
          name: _stringValue(
            peer['HostName'],
            fallback: _stringValue(peer['DNSName'], fallback: entry.key),
          ),
          dnsName: _stringValue(peer['DNSName'], fallback: 'Unknown DNS'),
          ipAddress: ipList.isNotEmpty ? ipList.first.toString() : 'Unknown IP',
          online: peer['Online'] == true,
        ),
      );
    }

    peers.sort((a, b) => a.name.compareTo(b.name));

    return TailscaleSnapshot(
      backendState: backendState,
      isConnected: backendState.toLowerCase() == 'running',
      selfName: _stringValue(
        self['HostName'],
        fallback: _stringValue(self['DNSName'], fallback: 'Unknown device'),
      ),
      selfDnsName: _stringValue(self['DNSName'], fallback: 'Unknown DNS'),
      selfIpAddress: selfIps.isNotEmpty
          ? selfIps.first.toString()
          : 'Unknown IP',
      loginName: _resolveLoginName(
        self: self,
        userProfile: userProfile,
        users: users,
      ),
      tailnetName: _stringValue(
        currentTailnet['Name'],
        fallback: magicDnsSuffix,
      ),
      magicDnsSuffix: _stringValue(
        currentTailnet['MagicDNSSuffix'],
        fallback: magicDnsSuffix,
      ),
      peers: peers,
    );
  }

  factory TailscaleSnapshot.fromPlainStatus(String status) {
    final normalized = status.toLowerCase();
    final isConnected =
        !normalized.contains('stopped') && !normalized.contains('logged out');

    return TailscaleSnapshot(
      backendState: isConnected ? 'Running' : 'Stopped',
      isConnected: isConnected,
      selfName: 'Unknown device',
      selfDnsName: 'Unknown DNS',
      selfIpAddress: 'Unknown IP',
      loginName: 'Unknown user',
      tailnetName: 'Unknown tailnet',
      magicDnsSuffix: 'Unknown tailnet',
      peers: const [],
    );
  }

  static Map<String, dynamic> _mapValue(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    return const <String, dynamic>{};
  }

  static List<dynamic> _listValue(dynamic value) {
    if (value is List<dynamic>) {
      return value;
    }
    return const <dynamic>[];
  }

  static String _stringValue(dynamic value, {required String fallback}) {
    final text = value?.toString() ?? '';
    return text.isEmpty ? fallback : text;
  }

  static String _resolveLoginName({
    required Map<String, dynamic> self,
    required Map<String, dynamic> userProfile,
    required Map<String, dynamic> users,
  }) {
    final fromProfile = _stringValue(
      userProfile['LoginName'],
      fallback: _stringValue(userProfile['DisplayName'], fallback: ''),
    );
    if (fromProfile.isNotEmpty) {
      return fromProfile;
    }

    final selfUserId = self['UserID']?.toString() ?? '';
    if (selfUserId.isNotEmpty) {
      final selfUser = _mapValue(users[selfUserId]);
      final fromSelfUser = _stringValue(
        selfUser['LoginName'],
        fallback: _stringValue(selfUser['DisplayName'], fallback: ''),
      );
      if (fromSelfUser.isNotEmpty) {
        return fromSelfUser;
      }
    }

    for (final entry in users.entries) {
      final user = _mapValue(entry.value);
      final candidate = _stringValue(
        user['LoginName'],
        fallback: _stringValue(user['DisplayName'], fallback: ''),
      );
      if (candidate.isNotEmpty) {
        return candidate;
      }
    }

    return 'Unknown';
  }
}

class TailscalePeer {
  const TailscalePeer({
    required this.name,
    required this.dnsName,
    required this.ipAddress,
    required this.online,
  });

  final String name;
  final String dnsName;
  final String ipAddress;
  final bool online;
}
