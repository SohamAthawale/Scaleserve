import 'dart:convert';
import 'dart:io';

import 'backend_runtime_sync_service.dart';
import 'runtime_storage_paths.dart';

class LocalSettings {
  const LocalSettings({
    required this.savedAuthKey,
    required this.autoConnectOnLaunch,
  });

  final String? savedAuthKey;
  final bool autoConnectOnLaunch;

  factory LocalSettings.defaults() {
    return const LocalSettings(savedAuthKey: null, autoConnectOnLaunch: false);
  }

  factory LocalSettings.fromJson(Map<String, dynamic> json) {
    final savedAuthKey = (json['savedAuthKey'] ?? '').toString().trim();
    final autoConnectRaw = json['autoConnectOnLaunch'];

    return LocalSettings(
      savedAuthKey: savedAuthKey.isEmpty ? null : savedAuthKey,
      autoConnectOnLaunch: autoConnectRaw == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'savedAuthKey': savedAuthKey ?? '',
      'autoConnectOnLaunch': autoConnectOnLaunch,
    };
  }
}

class LocalSettingsStore {
  LocalSettingsStore({BackendRuntimeSyncService? runtimeSyncService})
    : _runtimeSyncService = runtimeSyncService ?? BackendRuntimeSyncService();

  final BackendRuntimeSyncService _runtimeSyncService;

  Future<LocalSettings> load() async {
    final settingsFile = RuntimeStoragePaths.localSettingsFile();

    if (!await settingsFile.exists()) {
      await _migrateLegacySettingsFileIfNeeded(settingsFile);
    }

    if (!await settingsFile.exists()) {
      return LocalSettings.defaults();
    }

    try {
      final text = await settingsFile.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return LocalSettings.fromJson(decoded);
      }
      if (decoded is Map) {
        final normalized = <String, dynamic>{};
        for (final entry in decoded.entries) {
          normalized[entry.key.toString()] = entry.value;
        }
        return LocalSettings.fromJson(normalized);
      }
    } catch (_) {
      // Fall through to defaults on malformed or inaccessible file.
    }

    return LocalSettings.defaults();
  }

  Future<void> save(LocalSettings settings) async {
    final settingsFile = RuntimeStoragePaths.localSettingsFile();
    await settingsFile.parent.create(recursive: true);
    await settingsFile.writeAsString(
      jsonEncode(settings.toJson()),
      flush: true,
    );

    try {
      await _runtimeSyncService.syncSettings(
        settings: <String, Object?>{
          'savedAuthKey': settings.savedAuthKey ?? '',
          'autoConnectOnLaunch': settings.autoConnectOnLaunch ? '1' : '0',
        },
      );
    } catch (_) {
      // Keep local persistence as source of availability when backend sync fails.
    }
  }

  Future<void> _migrateLegacySettingsFileIfNeeded(File targetFile) async {
    final legacyFile = _legacySettingsFile();
    if (!await legacyFile.exists()) {
      return;
    }

    try {
      final text = await legacyFile.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        return;
      }

      final normalized = <String, dynamic>{};
      for (final entry in decoded.entries) {
        normalized[entry.key.toString()] = entry.value;
      }
      final migrated = LocalSettings.fromJson(normalized);
      await targetFile.parent.create(recursive: true);
      await targetFile.writeAsString(
        jsonEncode(migrated.toJson()),
        flush: true,
      );
    } catch (_) {
      // Ignore malformed legacy file.
    }
  }

  File _legacySettingsFile() {
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) {
        throw StateError('HOME environment variable is unavailable.');
      }
      return File('$home/.scaleserve/settings.json');
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
      return File('${normalizedBase}ScaleServe\\settings.json');
    }

    throw UnsupportedError(
      'Local settings persistence is supported only on macOS and Windows.',
    );
  }
}
