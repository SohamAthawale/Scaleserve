import 'dart:convert';
import 'dart:io';

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
  Future<LocalSettings> load() async {
    try {
      final file = _settingsFile();
      if (!await file.exists()) {
        return LocalSettings.defaults();
      }

      final text = await file.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return LocalSettings.fromJson(decoded);
      }
    } catch (_) {
      // Use defaults if file is missing or malformed.
    }

    return LocalSettings.defaults();
  }

  Future<void> save(LocalSettings settings) async {
    final file = _settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(settings.toJson()));
  }

  File _settingsFile() {
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
