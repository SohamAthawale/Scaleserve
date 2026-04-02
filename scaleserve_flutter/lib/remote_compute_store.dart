import 'dart:convert';
import 'dart:io';

class RemoteDeviceProfile {
  const RemoteDeviceProfile({
    required this.dnsName,
    required this.user,
    required this.keyPath,
    required this.bootstrapKeyPath,
    required this.defaultCommand,
  });

  final String dnsName;
  final String user;
  final String keyPath;
  final String bootstrapKeyPath;
  final String defaultCommand;

  factory RemoteDeviceProfile.fromJson(Map<String, dynamic> json) {
    return RemoteDeviceProfile(
      dnsName: (json['dnsName'] ?? '').toString(),
      user: (json['user'] ?? '').toString(),
      keyPath: (json['keyPath'] ?? '').toString(),
      bootstrapKeyPath: (json['bootstrapKeyPath'] ?? '').toString(),
      defaultCommand: (json['defaultCommand'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'dnsName': dnsName,
      'user': user,
      'keyPath': keyPath,
      'bootstrapKeyPath': bootstrapKeyPath,
      'defaultCommand': defaultCommand,
    };
  }
}

class RemoteExecutionRecord {
  const RemoteExecutionRecord({
    required this.startedAtIso,
    required this.deviceDnsName,
    required this.user,
    required this.command,
    required this.exitCode,
    required this.success,
  });

  final String startedAtIso;
  final String deviceDnsName;
  final String user;
  final String command;
  final int exitCode;
  final bool success;

  factory RemoteExecutionRecord.fromJson(Map<String, dynamic> json) {
    final exitCodeRaw = json['exitCode'];
    final parsedExitCode = (exitCodeRaw is int)
        ? exitCodeRaw
        : int.tryParse(exitCodeRaw?.toString() ?? '') ?? -1;

    return RemoteExecutionRecord(
      startedAtIso: (json['startedAtIso'] ?? '').toString(),
      deviceDnsName: (json['deviceDnsName'] ?? '').toString(),
      user: (json['user'] ?? '').toString(),
      command: (json['command'] ?? '').toString(),
      exitCode: parsedExitCode,
      success: json['success'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'startedAtIso': startedAtIso,
      'deviceDnsName': deviceDnsName,
      'user': user,
      'command': command,
      'exitCode': exitCode,
      'success': success,
    };
  }
}

class RemoteComputeState {
  const RemoteComputeState({
    required this.profilesByDns,
    required this.history,
  });

  final Map<String, RemoteDeviceProfile> profilesByDns;
  final List<RemoteExecutionRecord> history;

  factory RemoteComputeState.defaults() {
    return const RemoteComputeState(
      profilesByDns: <String, RemoteDeviceProfile>{},
      history: <RemoteExecutionRecord>[],
    );
  }

  factory RemoteComputeState.fromJson(Map<String, dynamic> json) {
    final profilesJson = json['profilesByDns'];
    final historyJson = json['history'];

    final profilesByDns = <String, RemoteDeviceProfile>{};
    if (profilesJson is Map<String, dynamic>) {
      for (final entry in profilesJson.entries) {
        final value = entry.value;
        if (value is Map<String, dynamic>) {
          profilesByDns[entry.key] = RemoteDeviceProfile.fromJson(value);
        }
      }
    }

    final history = <RemoteExecutionRecord>[];
    if (historyJson is List<dynamic>) {
      for (final item in historyJson) {
        if (item is Map<String, dynamic>) {
          history.add(RemoteExecutionRecord.fromJson(item));
        }
      }
    }

    return RemoteComputeState(profilesByDns: profilesByDns, history: history);
  }

  Map<String, dynamic> toJson() {
    final profiles = <String, dynamic>{};
    for (final entry in profilesByDns.entries) {
      profiles[entry.key] = entry.value.toJson();
    }

    return {
      'profilesByDns': profiles,
      'history': history.map((record) => record.toJson()).toList(),
    };
  }
}

class RemoteComputeStore {
  Future<RemoteComputeState> load() async {
    try {
      final file = _stateFile();
      if (!await file.exists()) {
        return RemoteComputeState.defaults();
      }

      final text = await file.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return RemoteComputeState.fromJson(decoded);
      }
    } catch (_) {
      // Ignore malformed file and fallback to defaults.
    }

    return RemoteComputeState.defaults();
  }

  Future<void> save(RemoteComputeState state) async {
    final file = _stateFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(state.toJson()));
  }

  File _stateFile() {
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) {
        throw StateError('HOME environment variable is unavailable.');
      }
      return File('$home/.scaleserve/remote_compute.json');
    }

    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      final userProfile = Platform.environment['USERPROFILE'];
      final base = (appData != null && appData.isNotEmpty)
          ? appData
          : userProfile;

      if (base == null || base.isEmpty) {
        throw StateError(
          'APPDATA and USERPROFILE environment variables are unavailable.',
        );
      }

      final normalizedBase = base.endsWith(r'\') ? base : '$base\\';
      return File('${normalizedBase}ScaleServe\\remote_compute.json');
    }

    throw UnsupportedError(
      'Remote compute persistence is supported only on macOS and Windows.',
    );
  }
}
