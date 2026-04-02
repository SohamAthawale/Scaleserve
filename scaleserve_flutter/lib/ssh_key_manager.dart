import 'dart:io';

class SshKeyStatus {
  const SshKeyStatus({
    required this.privateKeyPath,
    required this.publicKeyPath,
    required this.exists,
    required this.publicKey,
  });

  final String privateKeyPath;
  final String publicKeyPath;
  final bool exists;
  final String publicKey;
}

class SshKeyManager {
  SshKeyManager({this.keyBaseName = 'scaleserve_remote_ed25519'});

  final String keyBaseName;

  String get privateKeyPath {
    final home = _homeDirectory();
    if (Platform.isWindows) {
      return '$home\\.ssh\\$keyBaseName';
    }
    return '$home/.ssh/$keyBaseName';
  }

  String get publicKeyPath => '$privateKeyPath.pub';

  Future<SshKeyStatus> status() async {
    final privateFile = File(privateKeyPath);
    final publicFile = File(publicKeyPath);
    final exists = await privateFile.exists() && await publicFile.exists();
    final publicKey = exists ? (await publicFile.readAsString()).trim() : '';

    return SshKeyStatus(
      privateKeyPath: privateKeyPath,
      publicKeyPath: publicKeyPath,
      exists: exists,
      publicKey: publicKey,
    );
  }

  Future<SshKeyStatus> ensureKeyPair() async {
    final currentStatus = await status();
    if (currentStatus.exists) {
      return currentStatus;
    }

    final privateFile = File(privateKeyPath);
    await privateFile.parent.create(recursive: true);

    final result = await Process.run('ssh-keygen', [
      '-t',
      'ed25519',
      '-f',
      privateKeyPath,
      '-N',
      '',
      '-C',
      'scaleserve-remote',
    ]);

    if (result.exitCode != 0) {
      throw StateError(
        'ssh-keygen failed with exit code ${result.exitCode}: '
        '${(result.stderr ?? '').toString().trim()}',
      );
    }

    return status();
  }

  String _homeDirectory() {
    if (Platform.isWindows) {
      final userProfile = Platform.environment['USERPROFILE'];
      if (userProfile != null && userProfile.isNotEmpty) {
        return userProfile;
      }
      final homeDrive = Platform.environment['HOMEDRIVE'] ?? '';
      final homePath = Platform.environment['HOMEPATH'] ?? '';
      final combined = '$homeDrive$homePath';
      if (combined.isNotEmpty) {
        return combined;
      }
      throw StateError('Unable to resolve Windows home directory.');
    }

    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return home;
    }
    throw StateError('Unable to resolve HOME directory.');
  }
}
