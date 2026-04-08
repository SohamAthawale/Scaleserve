import 'dart:convert';
import 'dart:io';

import 'backend_runtime_sync_service.dart';
import 'runtime_storage_paths.dart';
import 'tailscale_service.dart';

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
    this.finishedAtIso,
    this.stdout = '',
    this.stderr = '',
    this.runType = 'remote_command',
    this.localFilePath,
    this.metadataJson,
  });

  final String startedAtIso;
  final String deviceDnsName;
  final String user;
  final String command;
  final int exitCode;
  final bool success;
  final String? finishedAtIso;
  final String stdout;
  final String stderr;
  final String runType;
  final String? localFilePath;
  final String? metadataJson;

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
      finishedAtIso: (json['finishedAtIso'] ?? '').toString().trim().isEmpty
          ? null
          : (json['finishedAtIso'] ?? '').toString(),
      stdout: (json['stdout'] ?? '').toString(),
      stderr: (json['stderr'] ?? '').toString(),
      runType: (json['runType'] ?? '').toString().trim().isEmpty
          ? 'remote_command'
          : (json['runType'] ?? '').toString().trim(),
      localFilePath: (json['localFilePath'] ?? '').toString().trim().isEmpty
          ? null
          : (json['localFilePath'] ?? '').toString().trim(),
      metadataJson: (json['metadataJson'] ?? '').toString().trim().isEmpty
          ? null
          : (json['metadataJson'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'startedAtIso': startedAtIso,
      'finishedAtIso': finishedAtIso ?? '',
      'deviceDnsName': deviceDnsName,
      'user': user,
      'command': command,
      'exitCode': exitCode,
      'success': success,
      'stdout': stdout,
      'stderr': stderr,
      'runType': runType,
      'localFilePath': localFilePath ?? '',
      'metadataJson': metadataJson ?? '',
    };
  }
}

class MachineInventoryRecord {
  const MachineInventoryRecord({
    required this.dnsName,
    required this.displayName,
    required this.ipAddress,
    required this.operatingSystem,
    required this.online,
    required this.isSelf,
    required this.tailnetName,
    required this.loginName,
    required this.backendState,
    required this.firstSeenAtIso,
    required this.lastSeenAtIso,
    this.metadataJson,
  });

  final String dnsName;
  final String displayName;
  final String ipAddress;
  final String operatingSystem;
  final bool online;
  final bool isSelf;
  final String tailnetName;
  final String loginName;
  final String backendState;
  final String firstSeenAtIso;
  final String lastSeenAtIso;
  final String? metadataJson;

  factory MachineInventoryRecord.fromJson(Map<String, dynamic> json) {
    return MachineInventoryRecord(
      dnsName: (json['dnsName'] ?? '').toString(),
      displayName: (json['displayName'] ?? '').toString(),
      ipAddress: (json['ipAddress'] ?? '').toString(),
      operatingSystem: (json['operatingSystem'] ?? '').toString(),
      online: json['online'] == true,
      isSelf: json['isSelf'] == true,
      tailnetName: (json['tailnetName'] ?? '').toString(),
      loginName: (json['loginName'] ?? '').toString(),
      backendState: (json['backendState'] ?? '').toString(),
      firstSeenAtIso: (json['firstSeenAtIso'] ?? '').toString(),
      lastSeenAtIso: (json['lastSeenAtIso'] ?? '').toString(),
      metadataJson: (json['metadataJson'] ?? '').toString().trim().isEmpty
          ? null
          : (json['metadataJson'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'dnsName': dnsName,
      'displayName': displayName,
      'ipAddress': ipAddress,
      'operatingSystem': operatingSystem,
      'online': online,
      'isSelf': isSelf,
      'tailnetName': tailnetName,
      'loginName': loginName,
      'backendState': backendState,
      'firstSeenAtIso': firstSeenAtIso,
      'lastSeenAtIso': lastSeenAtIso,
      'metadataJson': metadataJson ?? '',
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
    if (profilesJson is Map) {
      for (final entry in profilesJson.entries) {
        final value = entry.value;
        if (value is Map<String, dynamic>) {
          profilesByDns[entry.key.toString()] = RemoteDeviceProfile.fromJson(
            value,
          );
        } else if (value is Map) {
          final normalized = <String, dynamic>{};
          for (final item in value.entries) {
            normalized[item.key.toString()] = item.value;
          }
          profilesByDns[entry.key.toString()] = RemoteDeviceProfile.fromJson(
            normalized,
          );
        }
      }
    }

    final history = <RemoteExecutionRecord>[];
    if (historyJson is List<dynamic>) {
      for (final item in historyJson) {
        if (item is Map<String, dynamic>) {
          history.add(RemoteExecutionRecord.fromJson(item));
        } else if (item is Map) {
          final normalized = <String, dynamic>{};
          for (final entry in item.entries) {
            normalized[entry.key.toString()] = entry.value;
          }
          history.add(RemoteExecutionRecord.fromJson(normalized));
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
  RemoteComputeStore({BackendRuntimeSyncService? runtimeSyncService})
    : _runtimeSyncService = runtimeSyncService ?? BackendRuntimeSyncService();

  final BackendRuntimeSyncService _runtimeSyncService;

  Future<RemoteComputeState> load() async {
    final stateFile = RuntimeStoragePaths.remoteStateFile();
    if (!await stateFile.exists()) {
      await _migrateLegacyStateFileIfNeeded(stateFile);
    }

    if (!await stateFile.exists()) {
      return RemoteComputeState.defaults();
    }

    try {
      final text = await stateFile.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return RemoteComputeState.fromJson(decoded);
      }
      if (decoded is Map) {
        final normalized = <String, dynamic>{};
        for (final entry in decoded.entries) {
          normalized[entry.key.toString()] = entry.value;
        }
        return RemoteComputeState.fromJson(normalized);
      }
    } catch (_) {
      // Fall through to defaults.
    }

    return RemoteComputeState.defaults();
  }

  Future<void> save(RemoteComputeState state) async {
    final stateFile = RuntimeStoragePaths.remoteStateFile();
    await stateFile.parent.create(recursive: true);
    await stateFile.writeAsString(jsonEncode(state.toJson()), flush: true);

    try {
      await _runtimeSyncService.syncRemoteState(
        profiles: state.profilesByDns.values
            .map(
              (profile) => <String, Object?>{
                'dnsName': profile.dnsName,
                'remoteUser': profile.user,
                'keyPath': profile.keyPath,
                'bootstrapKeyPath': profile.bootstrapKeyPath,
                'defaultCommand': profile.defaultCommand,
                'updatedAtIso': DateTime.now().toUtc().toIso8601String(),
              },
            )
            .toList(growable: false),
        recentRuns: state.history
            .take(500)
            .map((record) => _remoteRunPayloadFromRecord(record))
            .toList(growable: false),
      );
    } catch (_) {
      // Keep local persistence resilient if backend sync is temporarily unavailable.
    }
  }

  Future<void> appendCommandLog({
    required String commandText,
    required String safeCommandText,
    required int exitCode,
    required String stdout,
    required String stderr,
  }) async {
    final createdAtIso = DateTime.now().toUtc().toIso8601String();

    await _appendJsonList(
      file: RuntimeStoragePaths.commandLogsFile(),
      maxItems: 500,
      item: <String, Object?>{
        'commandText': commandText,
        'safeCommandText': safeCommandText,
        'exitCode': exitCode,
        'success': exitCode == 0,
        'stdout': stdout,
        'stderr': stderr,
        'source': 'tailscale_cli',
        'createdAtIso': createdAtIso,
      },
    );

    try {
      await _runtimeSyncService.syncCommandLog(
        commandLogPayload: <String, Object?>{
          'commandText': commandText,
          'safeCommandText': safeCommandText,
          'exitCode': exitCode,
          'success': exitCode == 0,
          'stdout': stdout,
          'stderr': stderr,
          'source': 'tailscale_cli',
          'createdAtIso': createdAtIso,
        },
      );
    } catch (_) {
      // Command logging should continue even when backend sync is down.
    }
  }

  Future<void> recordMachineSnapshot({
    required TailscaleSnapshot snapshot,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final selfDns = snapshot.selfDnsName.trim();
    if (selfDns.isEmpty) {
      return;
    }

    final inventoryByDns = await _loadInventoryByDns();

    void upsertMachine({
      required String dnsName,
      required String displayName,
      required String ipAddress,
      required String operatingSystem,
      required bool online,
      required bool isSelf,
      required String metadataJson,
    }) {
      final existing = inventoryByDns[dnsName];
      final firstSeen = existing?.firstSeenAtIso ?? now;

      inventoryByDns[dnsName] = MachineInventoryRecord(
        dnsName: dnsName,
        displayName: displayName,
        ipAddress: ipAddress,
        operatingSystem: operatingSystem,
        online: online,
        isSelf: isSelf,
        tailnetName: snapshot.tailnetName,
        loginName: snapshot.loginName,
        backendState: snapshot.backendState,
        firstSeenAtIso: firstSeen,
        lastSeenAtIso: now,
        metadataJson: metadataJson,
      );
    }

    upsertMachine(
      dnsName: selfDns,
      displayName: snapshot.selfName,
      ipAddress: snapshot.selfIpAddress,
      operatingSystem: Platform.operatingSystem,
      online: snapshot.isConnected,
      isSelf: true,
      metadataJson: jsonEncode(<String, dynamic>{
        'source': 'tailscale_status',
        'kind': 'self',
        'magicDnsSuffix': snapshot.magicDnsSuffix,
      }),
    );

    for (final peer in snapshot.peers) {
      final dnsName = peer.normalizedDnsName;
      if (dnsName.isEmpty) {
        continue;
      }
      upsertMachine(
        dnsName: dnsName,
        displayName: peer.name,
        ipAddress: peer.ipAddress,
        operatingSystem: peer.os,
        online: peer.online,
        isSelf: false,
        metadataJson: jsonEncode(<String, dynamic>{
          'source': 'tailscale_status',
          'kind': 'peer',
        }),
      );
    }

    final inventoryFile = RuntimeStoragePaths.machineInventoryFile();
    await inventoryFile.parent.create(recursive: true);
    await inventoryFile.writeAsString(
      jsonEncode(
        inventoryByDns.values
            .map((record) => record.toJson())
            .toList(growable: false),
      ),
      flush: true,
    );

    try {
      await _runtimeSyncService.syncMachineSnapshot(
        snapshotPayload: <String, Object?>{
          'capturedAtIso': now,
          'selfDnsName': snapshot.selfDnsName,
          'selfName': snapshot.selfName,
          'selfIpAddress': snapshot.selfIpAddress,
          'isConnected': snapshot.isConnected,
          'tailnetName': snapshot.tailnetName,
          'loginName': snapshot.loginName,
          'backendState': snapshot.backendState,
          'magicDnsSuffix': snapshot.magicDnsSuffix,
          'peers': snapshot.peers
              .map(
                (peer) => <String, Object?>{
                  'dnsName': peer.normalizedDnsName,
                  'name': peer.name,
                  'ipAddress': peer.ipAddress,
                  'os': peer.os,
                  'online': peer.online,
                },
              )
              .toList(growable: false),
        },
      );
    } catch (_) {
      // Snapshot sync failures should not block local capture.
    }
  }

  Future<List<MachineInventoryRecord>> listMachineInventory({
    int limit = 200,
  }) async {
    final items = (await _loadInventoryByDns()).values.toList(growable: false)
      ..sort((left, right) {
        final selfOrder = (right.isSelf ? 1 : 0) - (left.isSelf ? 1 : 0);
        if (selfOrder != 0) {
          return selfOrder;
        }
        return right.lastSeenAtIso.compareTo(left.lastSeenAtIso);
      });

    if (limit < 1) {
      return const <MachineInventoryRecord>[];
    }
    return items.take(limit).toList(growable: false);
  }

  Future<Map<String, MachineInventoryRecord>> _loadInventoryByDns() async {
    final inventoryFile = RuntimeStoragePaths.machineInventoryFile();
    if (!await inventoryFile.exists()) {
      return <String, MachineInventoryRecord>{};
    }

    try {
      final text = await inventoryFile.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! List) {
        return <String, MachineInventoryRecord>{};
      }

      final map = <String, MachineInventoryRecord>{};
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          final record = MachineInventoryRecord.fromJson(item);
          if (record.dnsName.isNotEmpty) {
            map[record.dnsName] = record;
          }
          continue;
        }
        if (item is Map) {
          final normalized = <String, dynamic>{};
          for (final entry in item.entries) {
            normalized[entry.key.toString()] = entry.value;
          }
          final record = MachineInventoryRecord.fromJson(normalized);
          if (record.dnsName.isNotEmpty) {
            map[record.dnsName] = record;
          }
        }
      }
      return map;
    } catch (_) {
      return <String, MachineInventoryRecord>{};
    }
  }

  Map<String, Object?> _remoteRunPayloadFromRecord(
    RemoteExecutionRecord record,
  ) {
    return <String, Object?>{
      'startedAtIso': record.startedAtIso,
      'finishedAtIso': record.finishedAtIso,
      'deviceDnsName': record.deviceDnsName,
      'remoteUser': record.user,
      'command': record.command,
      'safeCommandText': _safeCommandFromMetadata(record.metadataJson),
      'exitCode': record.exitCode,
      'success': record.success,
      'runType': record.runType,
      'localFilePath': record.localFilePath,
      'stdout': record.stdout,
      'stderr': record.stderr,
      'metadataJson': record.metadataJson,
    };
  }

  String? _safeCommandFromMetadata(String? metadataJson) {
    final text = (metadataJson ?? '').trim();
    if (text.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        final value = (decoded['safeCommand'] ?? '').toString().trim();
        return value.isEmpty ? null : value;
      }
    } catch (_) {
      // Ignore malformed metadata.
    }
    return null;
  }

  Future<void> _appendJsonList({
    required File file,
    required int maxItems,
    required Map<String, Object?> item,
  }) async {
    List<dynamic> existing = <dynamic>[];
    if (await file.exists()) {
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          existing = decoded;
        }
      } catch (_) {
        existing = <dynamic>[];
      }
    }

    existing.insert(0, item);
    if (existing.length > maxItems) {
      existing = existing.take(maxItems).toList(growable: false);
    }

    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(existing), flush: true);
  }

  Future<void> _migrateLegacyStateFileIfNeeded(File targetFile) async {
    final legacyFile = _legacyStateFile();
    if (!await legacyFile.exists()) {
      return;
    }

    try {
      await targetFile.parent.create(recursive: true);
      await legacyFile.copy(targetFile.path);
    } catch (_) {
      // Ignore migration failures and continue with empty state.
    }
  }

  File _legacyStateFile() {
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
