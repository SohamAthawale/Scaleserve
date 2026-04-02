import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'local_settings_store.dart';
import 'remote_compute_store.dart';
import 'ssh_key_manager.dart';
import 'tailscale_service.dart';

void main() {
  runApp(const ScaleServeApp());
}

class ScaleServeApp extends StatelessWidget {
  const ScaleServeApp({
    super.key,
    this.service,
    this.startAutoRefresh = true,
    this.fetchOnStartup = true,
  });

  final TailscaleService? service;
  final bool startAutoRefresh;
  final bool fetchOnStartup;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ScaleServe Tailscale Controller',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0B7285)),
        useMaterial3: true,
      ),
      home: TailscaleDashboardPage(
        service: service ?? TailscaleService(),
        startAutoRefresh: startAutoRefresh,
        fetchOnStartup: fetchOnStartup,
      ),
    );
  }
}

class TailscaleDashboardPage extends StatefulWidget {
  const TailscaleDashboardPage({
    super.key,
    required this.service,
    required this.startAutoRefresh,
    required this.fetchOnStartup,
  });

  final TailscaleService service;
  final bool startAutoRefresh;
  final bool fetchOnStartup;

  @override
  State<TailscaleDashboardPage> createState() => _TailscaleDashboardPageState();
}

class _TailscaleDashboardPageState extends State<TailscaleDashboardPage> {
  static const List<String> _commonLinuxSshUsers = <String>[
    'opc',
    'ubuntu',
    'ec2-user',
    'debian',
    'centos',
    'fedora',
    'root',
  ];

  final LocalSettingsStore _settingsStore = LocalSettingsStore();
  final RemoteComputeStore _remoteComputeStore = RemoteComputeStore();
  final SshKeyManager _sshKeyManager = SshKeyManager();

  final TextEditingController _authKeyController = TextEditingController();
  final TextEditingController _remoteUserController = TextEditingController();
  final TextEditingController _remoteKeyPathController =
      TextEditingController();
  final TextEditingController _bootstrapKeyPathController =
      TextEditingController();
  final TextEditingController _localStreamFilePathController =
      TextEditingController();
  final TextEditingController _remoteStdinCommandController =
      TextEditingController(text: 'python3 -');
  final TextEditingController _remoteCommandController =
      TextEditingController();

  TailscaleSnapshot? _snapshot;
  String _infoMessage = 'Checking Tailscale status...';
  String _latestCommandOutput = '';
  String _remoteLiveOutput = 'No remote command run yet.';
  String _sshKeyStatusText = 'Checking SSH key setup...';
  String _sshPublicKey = '';
  DateTime? _lastUpdated;

  bool _loadingStatus = true;
  bool _runningAction = false;
  bool _runningRemoteCommand = false;
  bool _generatingSshKey = false;
  bool _detectingRemoteUser = false;
  bool _rememberAuthKey = false;
  bool _autoConnectOnLaunch = false;
  bool _setupEnableTailscaleSsh = true;
  bool _hasStoredKey = false;

  String? _selectedRemoteDeviceDns;
  Map<String, RemoteDeviceProfile> _remoteProfilesByDns =
      <String, RemoteDeviceProfile>{};
  List<RemoteExecutionRecord> _remoteExecutionHistory =
      <RemoteExecutionRecord>[];

  Timer? _refreshTimer;

  bool get _isBusy => _loadingStatus || _runningAction;

  @override
  void initState() {
    super.initState();
    _initializePage();

    if (widget.startAutoRefresh) {
      _refreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
        if (!_runningAction) {
          _refreshStatus(showLoader: false);
        }
      });
    }
  }

  Future<void> _initializePage() async {
    await _loadSettings();
    await _loadRemoteComputeState();
    await _loadSshKeyState();

    if (widget.fetchOnStartup) {
      await _refreshStatus(showLoader: true);
    } else if (mounted) {
      setState(() {
        _loadingStatus = false;
        _infoMessage = 'Ready.';
      });
    }

    if (_autoConnectOnLaunch) {
      final key = _authKeyController.text.trim();
      final connected = _snapshot?.isConnected ?? false;

      if (key.isNotEmpty && !connected) {
        await _runAction(
          successMessage: 'Auto-connected using saved auth key.',
          action: () => widget.service.connect(authKey: key),
        );
      }
    }
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await _settingsStore.load();
      if (!mounted) {
        return;
      }

      final key = settings.savedAuthKey ?? '';
      setState(() {
        _authKeyController.text = key;
        _rememberAuthKey = key.isNotEmpty;
        _autoConnectOnLaunch = settings.autoConnectOnLaunch;
        _hasStoredKey = key.isNotEmpty;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _hasStoredKey = false;
      });
    }
  }

  Future<void> _saveKeyPreferences() async {
    final key = _authKeyController.text.trim();
    final savedKey = _rememberAuthKey && key.isNotEmpty ? key : null;

    await _settingsStore.save(
      LocalSettings(
        savedAuthKey: savedKey,
        autoConnectOnLaunch: _autoConnectOnLaunch,
      ),
    );

    if (!mounted) {
      return;
    }
    setState(() {
      _hasStoredKey = savedKey != null;
      _infoMessage = _hasStoredKey
          ? 'Saved auth key preferences.'
          : 'Cleared saved auth key.';
    });
  }

  Future<void> _clearSavedKey() async {
    await _settingsStore.save(
      LocalSettings(
        savedAuthKey: null,
        autoConnectOnLaunch: _autoConnectOnLaunch,
      ),
    );

    if (!mounted) {
      return;
    }
    setState(() {
      _hasStoredKey = false;
      _rememberAuthKey = false;
      _authKeyController.clear();
      _infoMessage = 'Saved auth key removed.';
    });
  }

  Future<void> _loadRemoteComputeState() async {
    try {
      final state = await _remoteComputeStore.load();
      if (!mounted) {
        return;
      }
      setState(() {
        _remoteProfilesByDns = Map<String, RemoteDeviceProfile>.from(
          state.profilesByDns,
        );
        _remoteExecutionHistory = List<RemoteExecutionRecord>.from(
          state.history,
        );
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _remoteProfilesByDns = <String, RemoteDeviceProfile>{};
        _remoteExecutionHistory = <RemoteExecutionRecord>[];
      });
    }
  }

  Future<void> _saveRemoteComputeState() async {
    await _remoteComputeStore.save(
      RemoteComputeState(
        profilesByDns: _remoteProfilesByDns,
        history: _remoteExecutionHistory,
      ),
    );
  }

  void _ensureRemoteSelectionForSnapshot(TailscaleSnapshot snapshot) {
    final peers = snapshot.peers;
    if (peers.isEmpty) {
      if (_selectedRemoteDeviceDns != null && mounted) {
        setState(() {
          _selectedRemoteDeviceDns = null;
        });
      }
      return;
    }

    final selected = _selectedRemoteDeviceDns;
    final hasSelected =
        selected != null &&
        peers.any((peer) => peer.normalizedDnsName == selected);
    if (hasSelected) {
      return;
    }

    _selectRemoteDevice(peers.first.normalizedDnsName);
  }

  void _selectRemoteDevice(String? dnsName) {
    if (!mounted) {
      return;
    }

    if (dnsName == null || dnsName.isEmpty) {
      setState(() {
        _selectedRemoteDeviceDns = null;
      });
      return;
    }

    final profile =
        _remoteProfilesByDns[dnsName] ?? _remoteProfilesByDns['$dnsName.'];
    final peer = _peerByDnsName(dnsName);
    final defaultUser = _defaultSshUserForPeer(peer);
    final profileKeyPath = profile?.keyPath ?? '';
    final profileBootstrapKeyPath = profile?.bootstrapKeyPath ?? '';
    final currentKeyPath = _remoteKeyPathController.text.trim();
    final currentBootstrapKeyPath = _bootstrapKeyPathController.text.trim();
    final fallbackKeyPath = profileKeyPath.isNotEmpty
        ? profileKeyPath
        : (currentKeyPath.isNotEmpty
              ? currentKeyPath
              : _sshKeyManager.privateKeyPath);
    final fallbackBootstrapKeyPath = profileBootstrapKeyPath.isNotEmpty
        ? profileBootstrapKeyPath
        : currentBootstrapKeyPath;

    setState(() {
      _selectedRemoteDeviceDns = dnsName;
      _remoteUserController.text = profile?.user ?? defaultUser;
      _remoteKeyPathController.text = fallbackKeyPath;
      _bootstrapKeyPathController.text = fallbackBootstrapKeyPath;
      _remoteCommandController.text = profile?.defaultCommand ?? '';
    });
  }

  Future<void> _saveRemoteProfile({required bool showMessage}) async {
    final dnsName = _selectedRemoteDeviceDns;
    if (dnsName == null || dnsName.isEmpty) {
      if (!showMessage || !mounted) {
        return;
      }
      setState(() {
        _infoMessage = 'Select a remote device before saving profile.';
      });
      return;
    }

    final user = _remoteUserController.text.trim();
    if (user.isEmpty) {
      if (!showMessage || !mounted) {
        return;
      }
      setState(() {
        _infoMessage = 'Remote user is required to save profile.';
      });
      return;
    }

    _remoteProfilesByDns[dnsName] = RemoteDeviceProfile(
      dnsName: dnsName,
      user: user,
      keyPath: _remoteKeyPathController.text.trim(),
      bootstrapKeyPath: _bootstrapKeyPathController.text.trim(),
      defaultCommand: _remoteCommandController.text.trim(),
    );

    await _saveRemoteComputeState();

    if (!showMessage || !mounted) {
      return;
    }
    setState(() {
      _infoMessage = 'Saved remote profile for $dnsName.';
    });
  }

  Future<void> _clearRemoteHistory() async {
    _remoteExecutionHistory = <RemoteExecutionRecord>[];
    await _saveRemoteComputeState();
    if (!mounted) {
      return;
    }
    setState(() {
      _infoMessage = 'Remote execution history cleared.';
    });
  }

  Future<void> _loadSshKeyState() async {
    try {
      final status = await _sshKeyManager.status();
      if (!mounted) {
        return;
      }
      setState(() {
        _sshPublicKey = status.publicKey;
        _sshKeyStatusText = status.exists
            ? 'SSH key ready at ${status.privateKeyPath}'
            : 'No SSH key found yet. Generate one for easier onboarding.';
        if (_remoteKeyPathController.text.trim().isEmpty && status.exists) {
          _remoteKeyPathController.text = status.privateKeyPath;
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _sshKeyStatusText = 'Unable to inspect SSH keys: $error';
      });
    }
  }

  Future<void> _generateSshKeyPair() async {
    setState(() {
      _generatingSshKey = true;
      _infoMessage = 'Generating SSH key pair...';
    });

    try {
      final status = await _sshKeyManager.ensureKeyPair();
      if (!mounted) {
        return;
      }
      setState(() {
        _generatingSshKey = false;
        _sshPublicKey = status.publicKey;
        _sshKeyStatusText = 'SSH key ready at ${status.privateKeyPath}';
        if (_remoteKeyPathController.text.trim().isEmpty) {
          _remoteKeyPathController.text = status.privateKeyPath;
        }
        _infoMessage = 'SSH key generated successfully.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _generatingSshKey = false;
        _infoMessage = 'Failed to generate SSH key: $error';
      });
    }
  }

  String _linuxAuthorizedKeySetupCommand() {
    if (_sshPublicKey.isEmpty) {
      return '';
    }

    final escaped = _sshPublicKey.replaceAll("'", "'\"'\"'");
    return 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys '
        '&& chmod 600 ~/.ssh/authorized_keys && '
        '(grep -qxF \'$escaped\' ~/.ssh/authorized_keys || '
        'printf \'%s\\n\' \'$escaped\' >> ~/.ssh/authorized_keys)';
  }

  Future<void> _copyLinuxSshBootstrapCommand() async {
    final command = _linuxAuthorizedKeySetupCommand();
    if (command.isEmpty) {
      setState(() {
        _infoMessage = 'Generate or load an SSH key first.';
      });
      return;
    }

    await _copyToClipboard(
      text: command,
      successMessage: 'Copied Linux SSH bootstrap command.',
    );
  }

  Future<void> _copyPublicKey() async {
    if (_sshPublicKey.isEmpty) {
      setState(() {
        _infoMessage = 'No SSH public key found. Generate one first.';
      });
      return;
    }

    await _copyToClipboard(
      text: _sshPublicKey,
      successMessage: 'Copied SSH public key.',
    );
  }

  Future<void> _installPublicKeyOnRemote() async {
    final dnsName = _selectedRemoteDeviceDns;
    final user = _remoteUserController.text.trim();
    final bootstrapKeyPath = _bootstrapKeyPathController.text.trim();

    if (_sshPublicKey.isEmpty) {
      await _loadSshKeyState();
    }

    if (_sshPublicKey.isEmpty) {
      setState(() {
        _infoMessage = 'Generate or load your ScaleServe SSH key first.';
      });
      return;
    }

    if (dnsName == null || dnsName.isEmpty) {
      setState(() {
        _infoMessage = 'Select a remote device first.';
      });
      return;
    }

    if (user.isEmpty) {
      setState(() {
        _infoMessage = 'Remote SSH user is required for bootstrap.';
      });
      return;
    }

    final bootstrapCommand = _linuxAuthorizedKeySetupCommand();
    final args = <String>[
      '-o',
      'BatchMode=yes',
      '-o',
      'NumberOfPasswordPrompts=0',
      '-o',
      'ConnectTimeout=8',
      '-o',
      'StrictHostKeyChecking=accept-new',
      if (bootstrapKeyPath.isNotEmpty) ...[
        '-i',
        bootstrapKeyPath,
        '-o',
        'IdentitiesOnly=yes',
      ],
      '$user@$dnsName',
      bootstrapCommand,
    ];

    final safeCommand = StringBuffer('ssh ');
    if (bootstrapKeyPath.isNotEmpty) {
      safeCommand.write('-i $bootstrapKeyPath -o IdentitiesOnly=yes ');
    }
    safeCommand.write(
      '-o BatchMode=yes -o StrictHostKeyChecking=accept-new $user@$dnsName '
      '"<install-public-key-command>"',
    );

    setState(() {
      _runningRemoteCommand = true;
      _remoteLiveOutput = 'Command: ${safeCommand.toString()}\n';
      _infoMessage = 'Installing ScaleServe public key on $dnsName...';
    });

    try {
      final result = await Process.run('ssh', args, runInShell: false);
      final exitCode = result.exitCode;
      final stdout = (result.stdout ?? '').toString().trim();
      final stderr = (result.stderr ?? '').toString().trim();

      final summary = StringBuffer()
        ..writeln('Command: ${safeCommand.toString()}')
        ..writeln('Exit code: $exitCode')
        ..writeln('');
      if (stdout.isNotEmpty) {
        summary
          ..writeln('STDOUT:')
          ..writeln(stdout)
          ..writeln('');
      }
      if (stderr.isNotEmpty) {
        summary
          ..writeln('STDERR:')
          ..writeln(stderr);
      }

      if (!mounted) {
        return;
      }

      final ensureScaleServeKeyPath = _remoteKeyPathController.text.trim();
      setState(() {
        _runningRemoteCommand = false;
        _remoteLiveOutput = summary.toString().trim();
        if (exitCode == 0 && ensureScaleServeKeyPath.isEmpty) {
          _remoteKeyPathController.text = _sshKeyManager.privateKeyPath;
        }
        _infoMessage = exitCode == 0
            ? 'Public key installed on $dnsName. Now click Test SSH Access.'
            : 'Failed to install key on $dnsName (exit $exitCode).';
      });

      if (exitCode == 0) {
        await _saveRemoteProfile(showMessage: false);
      }
    } on ProcessException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _runningRemoteCommand = false;
        _remoteLiveOutput += '\nERROR: ${error.message}';
        _infoMessage = 'Could not start SSH bootstrap: ${error.message}';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _runningRemoteCommand = false;
        _remoteLiveOutput += '\nERROR: $error';
        _infoMessage = 'SSH bootstrap failed: $error';
      });
    }
  }

  Future<void> _testSshAccess() async {
    final dnsName = _selectedRemoteDeviceDns;
    final user = _remoteUserController.text.trim();
    final keyPath = _remoteKeyPathController.text.trim();

    if (dnsName == null || dnsName.isEmpty) {
      setState(() {
        _infoMessage = 'Select a remote device first.';
      });
      return;
    }
    if (user.isEmpty) {
      setState(() {
        _infoMessage = 'Remote SSH user is required.';
      });
      return;
    }

    final args = <String>[
      '-o',
      'BatchMode=yes',
      '-o',
      'StrictHostKeyChecking=accept-new',
      if (keyPath.isNotEmpty) ...['-i', keyPath, '-o', 'IdentitiesOnly=yes'],
      '$user@$dnsName',
      'echo scaleserve-ssh-ok',
    ];

    setState(() {
      _runningRemoteCommand = true;
      _remoteLiveOutput = 'Command: ssh ${args.join(' ')}\n';
      _infoMessage = 'Testing SSH access to $dnsName...';
    });

    try {
      final result = await Process.run('ssh', args, runInShell: false);
      final exitCode = result.exitCode;
      final stdout = (result.stdout ?? '').toString().trim();
      final stderr = (result.stderr ?? '').toString().trim();

      final summary = StringBuffer()
        ..writeln('Command: ssh ${args.join(' ')}')
        ..writeln('Exit code: $exitCode')
        ..writeln('');
      if (stdout.isNotEmpty) {
        summary
          ..writeln('STDOUT:')
          ..writeln(stdout)
          ..writeln('');
      }
      if (stderr.isNotEmpty) {
        summary
          ..writeln('STDERR:')
          ..writeln(stderr);
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _runningRemoteCommand = false;
        _remoteLiveOutput = summary.toString().trim();
        _infoMessage = exitCode == 0
            ? 'SSH access test passed for $dnsName.'
            : 'SSH access test failed for $dnsName.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _runningRemoteCommand = false;
        _remoteLiveOutput += '\nERROR: $error';
        _infoMessage = 'SSH access test failed: $error';
      });
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _authKeyController.dispose();
    _remoteUserController.dispose();
    _remoteKeyPathController.dispose();
    _bootstrapKeyPathController.dispose();
    _localStreamFilePathController.dispose();
    _remoteStdinCommandController.dispose();
    _remoteCommandController.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus({required bool showLoader}) async {
    if (showLoader) {
      setState(() {
        _loadingStatus = true;
      });
    }

    try {
      final snapshot = await widget.service.fetchStatus();
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        _lastUpdated = DateTime.now();
        _infoMessage = 'Status refreshed successfully.';
      });
      _ensureRemoteSelectionForSnapshot(snapshot);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _infoMessage = 'Unable to fetch status: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingStatus = false;
        });
      }
    }
  }

  Future<void> _runAction({
    required String successMessage,
    required Future<TailscaleCommandResult> Function() action,
  }) async {
    setState(() {
      _runningAction = true;
      _infoMessage = 'Running command...';
    });

    try {
      final result = await action();
      if (!mounted) {
        return;
      }

      setState(() {
        _latestCommandOutput = _formatCommandResult(result);
        _infoMessage = result.success
            ? successMessage
            : 'Command failed (exit ${result.exitCode}).';
      });

      await _refreshStatus(showLoader: false);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _infoMessage = 'Command error: $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _runningAction = false;
        });
      }
    }
  }

  String _formatCommandResult(TailscaleCommandResult result) {
    final buffer = StringBuffer()
      ..writeln('Command: ${result.safeCommandString}')
      ..writeln('Exit code: ${result.exitCode}')
      ..writeln('');

    if (result.stdout.isNotEmpty) {
      buffer
        ..writeln('STDOUT:')
        ..writeln(result.stdout)
        ..writeln('');
    }

    if (result.stderr.isNotEmpty) {
      buffer
        ..writeln('STDERR:')
        ..writeln(result.stderr);
    }

    return buffer.toString().trim();
  }

  String _effectiveAuthKeyForCommand() {
    final key = _authKeyController.text.trim();
    return key.isEmpty ? 'tskey-REPLACE_ME' : key;
  }

  String _macJoinCommand() {
    final key = _effectiveAuthKeyForCommand();
    return 'sudo /Applications/Tailscale.app/Contents/MacOS/Tailscale up '
        '--reset --ssh --auth-key=$key --hostname="\$(scutil --get ComputerName)"';
  }

  String _windowsJoinCommand() {
    final key = _effectiveAuthKeyForCommand();
    return '& "C:\\Program Files\\Tailscale\\tailscale.exe" up --reset --ssh '
        '--auth-key=$key --hostname=\$env:COMPUTERNAME';
  }

  String _linuxJoinCommand() {
    final key = _effectiveAuthKeyForCommand();
    return 'sudo tailscale up --reset --ssh --auth-key=$key '
        '--hostname="\$(hostname)"';
  }

  Future<void> _copyToClipboard({
    required String text,
    required String successMessage,
  }) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(successMessage)));
  }

  String _defaultSshUserTemplate() {
    final user =
        Platform.environment['USER'] ?? Platform.environment['USERNAME'];
    if (user == null || user.isEmpty) {
      return '<remote-user>';
    }
    return user;
  }

  TailscalePeer? _peerByDnsName(String dnsName) {
    final peers = _snapshot?.peers ?? const <TailscalePeer>[];
    for (final peer in peers) {
      if (peer.normalizedDnsName == dnsName) {
        return peer;
      }
    }
    return null;
  }

  String _defaultSshUserForPeer(TailscalePeer? peer) {
    if (peer == null) {
      return _defaultSshUserTemplate();
    }

    final os = peer.os.toLowerCase();
    if (os.contains('linux')) {
      return 'opc';
    }
    if (os.contains('windows')) {
      return 'Administrator';
    }

    return _defaultSshUserTemplate();
  }

  List<String> _candidateUsersForDetection(TailscalePeer? peer) {
    final unique = <String>{};
    final typed = _remoteUserController.text.trim();
    if (typed.isNotEmpty) {
      unique.add(typed);
    }

    if (peer != null) {
      final os = peer.os.toLowerCase();
      if (os.contains('linux')) {
        unique.addAll(_commonLinuxSshUsers);
      } else if (os.contains('windows')) {
        unique.addAll(const <String>['Administrator', 'admin']);
      }
    }

    final fallback = _defaultSshUserTemplate();
    if (fallback.isNotEmpty && fallback != '<remote-user>') {
      unique.add(fallback);
    }

    return unique.toList(growable: false);
  }

  Future<void> _detectRemoteSshUser() async {
    final dnsName = _selectedRemoteDeviceDns;
    final keyPath = _remoteKeyPathController.text.trim();

    if (dnsName == null || dnsName.isEmpty) {
      setState(() {
        _infoMessage = 'Select a remote device first.';
      });
      return;
    }

    final peer = _peerByDnsName(dnsName);
    final candidates = _candidateUsersForDetection(peer);
    if (candidates.isEmpty) {
      setState(() {
        _infoMessage = 'Enter a user first to start SSH detection.';
      });
      return;
    }

    setState(() {
      _detectingRemoteUser = true;
      _remoteLiveOutput =
          'Detecting SSH user for $dnsName...\n'
          'Will try: ${candidates.join(', ')}\n';
      _infoMessage = 'Detecting SSH user for $dnsName...';
    });

    String? detectedUser;
    final output = StringBuffer(_remoteLiveOutput);

    for (final candidate in candidates) {
      final args = <String>[
        '-o',
        'BatchMode=yes',
        '-o',
        'NumberOfPasswordPrompts=0',
        '-o',
        'ConnectTimeout=6',
        '-o',
        'StrictHostKeyChecking=accept-new',
        if (keyPath.isNotEmpty) ...['-i', keyPath, '-o', 'IdentitiesOnly=yes'],
        '$candidate@$dnsName',
        'echo scaleserve-ssh-ok',
      ];

      output.writeln('');
      output.writeln('Trying: ssh ${args.join(' ')}');

      try {
        final result = await Process.run('ssh', args, runInShell: false);
        final exitCode = result.exitCode;
        final stdout = (result.stdout ?? '').toString().trim();
        final stderr = (result.stderr ?? '').toString().trim();

        output.writeln('Exit code: $exitCode');
        if (stderr.isNotEmpty) {
          final firstLine = stderr.split('\n').first.trim();
          output.writeln('Result: $firstLine');
        }

        if (exitCode == 0 &&
            (stdout.contains('scaleserve-ssh-ok') || stderr.isEmpty)) {
          detectedUser = candidate;
          output.writeln('Detected working SSH user: $candidate');
          break;
        }
      } on ProcessException catch (error) {
        output.writeln('Process error: ${error.message}');
      } catch (error) {
        output.writeln('Error: $error');
      }

      if (mounted) {
        setState(() {
          _remoteLiveOutput = output.toString().trim();
        });
      }
    }

    if (!mounted) {
      return;
    }

    if (detectedUser != null) {
      setState(() {
        _detectingRemoteUser = false;
        _remoteUserController.text = detectedUser!;
        _remoteLiveOutput = output.toString().trim();
        _infoMessage = 'Detected SSH user "$detectedUser" for $dnsName.';
      });
      await _saveRemoteProfile(showMessage: false);
      return;
    }

    setState(() {
      _detectingRemoteUser = false;
      _remoteLiveOutput = output.toString().trim();
      _infoMessage =
          'Could not detect SSH user automatically. Run Linux SSH setup once '
          'on the target machine, then retry Test SSH Access.';
    });
  }

  String _sshCommandTemplate(TailscalePeer peer) {
    final user = _defaultSshUserTemplate();
    return 'ssh $user@${peer.normalizedDnsName}';
  }

  Future<void> _runRemoteCommand() async {
    final dnsName = _selectedRemoteDeviceDns;
    final user = _remoteUserController.text.trim();
    final keyPath = _remoteKeyPathController.text.trim();
    final remoteCommand = _remoteCommandController.text.trim();

    if (dnsName == null || dnsName.isEmpty) {
      setState(() {
        _infoMessage = 'Select a remote device first.';
      });
      return;
    }

    if (user.isEmpty) {
      setState(() {
        _infoMessage = 'Remote user is required.';
      });
      return;
    }

    if (remoteCommand.isEmpty) {
      setState(() {
        _infoMessage = 'Enter a command to run on the remote device.';
      });
      return;
    }

    await _saveRemoteProfile(showMessage: false);

    final target = '$user@$dnsName';
    final sshArgs = <String>[
      if (keyPath.isNotEmpty) ...['-i', keyPath, '-o', 'IdentitiesOnly=yes'],
      target,
      remoteCommand,
    ];

    final safeCommand = StringBuffer('ssh ');
    if (keyPath.isNotEmpty) {
      safeCommand.write('-i $keyPath -o IdentitiesOnly=yes ');
    }
    safeCommand.write('$target $remoteCommand');

    setState(() {
      _runningRemoteCommand = true;
      _remoteLiveOutput = 'Command: ${safeCommand.toString()}\n';
      _infoMessage = 'Running remote command on $dnsName...';
    });

    try {
      final process = await Process.start('ssh', sshArgs, runInShell: false);
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();

      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();

      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              stdoutBuffer.writeln(line);
              if (mounted) {
                setState(() {
                  _remoteLiveOutput += 'STDOUT: $line\n';
                });
              }
            },
            onDone: () => stdoutDone.complete(),
            onError: (_) => stdoutDone.complete(),
            cancelOnError: false,
          );

      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              stderrBuffer.writeln(line);
              if (mounted) {
                setState(() {
                  _remoteLiveOutput += 'STDERR: $line\n';
                });
              }
            },
            onDone: () => stderrDone.complete(),
            onError: (_) => stderrDone.complete(),
            cancelOnError: false,
          );

      final exitCode = await process.exitCode;
      await Future.wait([stdoutDone.future, stderrDone.future]);

      final stdoutText = stdoutBuffer.toString().trim();
      final stderrText = stderrBuffer.toString().trim();
      final success = exitCode == 0;

      final summary = StringBuffer()
        ..writeln('Command: ${safeCommand.toString()}')
        ..writeln('Exit code: $exitCode')
        ..writeln('');
      if (stdoutText.isNotEmpty) {
        summary
          ..writeln('STDOUT:')
          ..writeln(stdoutText)
          ..writeln('');
      }
      if (stderrText.isNotEmpty) {
        summary
          ..writeln('STDERR:')
          ..writeln(stderrText);
      }

      _remoteExecutionHistory.insert(
        0,
        RemoteExecutionRecord(
          startedAtIso: DateTime.now().toIso8601String(),
          deviceDnsName: dnsName,
          user: user,
          command: remoteCommand,
          exitCode: exitCode,
          success: success,
        ),
      );
      if (_remoteExecutionHistory.length > 30) {
        _remoteExecutionHistory = _remoteExecutionHistory.take(30).toList();
      }

      await _saveRemoteComputeState();

      if (!mounted) {
        return;
      }
      setState(() {
        _runningRemoteCommand = false;
        _remoteLiveOutput = summary.toString().trim();
        _infoMessage = success
            ? 'Remote command completed on $dnsName.'
            : 'Remote command failed on $dnsName (exit $exitCode).';
      });
    } on ProcessException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _runningRemoteCommand = false;
        _remoteLiveOutput += '\nERROR: ${error.message}';
        _infoMessage = 'Could not start ssh command. ${error.message}';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _runningRemoteCommand = false;
        _remoteLiveOutput += '\nERROR: $error';
        _infoMessage = 'Remote execution failed: $error';
      });
    }
  }

  Future<void> _runLocalFileOnRemoteCompute() async {
    final dnsName = _selectedRemoteDeviceDns;
    final user = _remoteUserController.text.trim();
    final keyPath = _remoteKeyPathController.text.trim();
    final localFilePath = _localStreamFilePathController.text.trim();
    final remoteStdinCommand = _remoteStdinCommandController.text.trim().isEmpty
        ? 'python3 -'
        : _remoteStdinCommandController.text.trim();

    if (dnsName == null || dnsName.isEmpty) {
      setState(() {
        _infoMessage = 'Select a remote device first.';
      });
      return;
    }

    if (user.isEmpty) {
      setState(() {
        _infoMessage = 'Remote user is required.';
      });
      return;
    }

    if (localFilePath.isEmpty) {
      setState(() {
        _infoMessage = 'Enter a local file path to stream.';
      });
      return;
    }

    final localFile = File(localFilePath);
    final exists = await localFile.exists();
    if (!exists) {
      setState(() {
        _infoMessage = 'Local file not found: $localFilePath';
      });
      return;
    }

    await _saveRemoteProfile(showMessage: false);

    final target = '$user@$dnsName';
    final sshArgs = <String>[
      if (keyPath.isNotEmpty) ...['-i', keyPath, '-o', 'IdentitiesOnly=yes'],
      target,
      remoteStdinCommand,
    ];

    final safeCommand = StringBuffer('ssh ');
    if (keyPath.isNotEmpty) {
      safeCommand.write('-i $keyPath -o IdentitiesOnly=yes ');
    }
    safeCommand.write('$target "$remoteStdinCommand" < "$localFilePath"');

    setState(() {
      _runningRemoteCommand = true;
      _remoteLiveOutput = 'Command: ${safeCommand.toString()}\n';
      _infoMessage = 'Streaming local file to $dnsName and running remotely...';
    });

    try {
      final process = await Process.start('ssh', sshArgs, runInShell: false);
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();

      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();

      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              stdoutBuffer.writeln(line);
              if (mounted) {
                setState(() {
                  _remoteLiveOutput += 'STDOUT: $line\n';
                });
              }
            },
            onDone: () => stdoutDone.complete(),
            onError: (_) => stdoutDone.complete(),
            cancelOnError: false,
          );

      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (line) {
              stderrBuffer.writeln(line);
              if (mounted) {
                setState(() {
                  _remoteLiveOutput += 'STDERR: $line\n';
                });
              }
            },
            onDone: () => stderrDone.complete(),
            onError: (_) => stderrDone.complete(),
            cancelOnError: false,
          );

      await process.stdin.addStream(localFile.openRead());
      await process.stdin.close();

      final exitCode = await process.exitCode;
      await Future.wait([stdoutDone.future, stderrDone.future]);

      final stdoutText = stdoutBuffer.toString().trim();
      final stderrText = stderrBuffer.toString().trim();
      final success = exitCode == 0;

      final summary = StringBuffer()
        ..writeln('Command: ${safeCommand.toString()}')
        ..writeln('Exit code: $exitCode')
        ..writeln('');
      if (stdoutText.isNotEmpty) {
        summary
          ..writeln('STDOUT:')
          ..writeln(stdoutText)
          ..writeln('');
      }
      if (stderrText.isNotEmpty) {
        summary
          ..writeln('STDERR:')
          ..writeln(stderrText);
      }

      _remoteExecutionHistory.insert(
        0,
        RemoteExecutionRecord(
          startedAtIso: DateTime.now().toIso8601String(),
          deviceDnsName: dnsName,
          user: user,
          command: 'stream:$localFilePath -> $remoteStdinCommand',
          exitCode: exitCode,
          success: success,
        ),
      );
      if (_remoteExecutionHistory.length > 30) {
        _remoteExecutionHistory = _remoteExecutionHistory.take(30).toList();
      }

      await _saveRemoteComputeState();

      if (!mounted) {
        return;
      }
      setState(() {
        _runningRemoteCommand = false;
        _remoteLiveOutput = summary.toString().trim();
        _infoMessage = success
            ? 'Remote stream run completed on $dnsName.'
            : 'Remote stream run failed on $dnsName (exit $exitCode).';
      });
    } on ProcessException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _runningRemoteCommand = false;
        _remoteLiveOutput += '\nERROR: ${error.message}';
        _infoMessage = 'Could not start SSH stream command. ${error.message}';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _runningRemoteCommand = false;
        _remoteLiveOutput += '\nERROR: $error';
        _infoMessage = 'Remote stream execution failed: $error';
      });
    }
  }

  String _historyTime(String isoText) {
    final parsed = DateTime.tryParse(isoText);
    if (parsed == null) {
      return isoText;
    }
    return parsed.toLocal().toIso8601String().replaceFirst('T', ' ');
  }

  Future<void> _handlePeerMenuAction({
    required TailscalePeer peer,
    required String action,
  }) async {
    if (action == 'select_remote') {
      _selectRemoteDevice(peer.normalizedDnsName);
      setState(() {
        _infoMessage = 'Selected ${peer.name} for remote compute runner.';
      });
      return;
    }

    if (action == 'copy_ping') {
      await _copyToClipboard(
        text: 'tailscale ping ${peer.normalizedDnsName}',
        successMessage: 'Copied ping command for ${peer.name}.',
      );
      return;
    }

    if (action == 'copy_ssh') {
      await _copyToClipboard(
        text: _sshCommandTemplate(peer),
        successMessage: 'Copied SSH template for ${peer.name}.',
      );
      return;
    }

    if (action == 'ping_now') {
      await _runAction(
        successMessage: 'Pinged ${peer.name}.',
        action: () => widget.service.pingPeer(target: peer.normalizedDnsName),
      );
    }
  }

  Future<void> _connectNewSession() async {
    final authKey = _authKeyController.text.trim();
    final usingAuthKey = authKey.isNotEmpty;
    final connected = _snapshot?.isConnected ?? false;

    await _saveKeyPreferences();

    await _runAction(
      successMessage: usingAuthKey
          ? 'Re-authenticated using auth key.'
          : 'Started a new login flow. Complete browser login if prompted.',
      action: () async {
        if (connected) {
          final logoutResult = await widget.service.logout();
          if (!logoutResult.success) {
            final logoutText = '${logoutResult.stdout}\n${logoutResult.stderr}'
                .toLowerCase();
            final alreadyLoggedOut =
                logoutText.contains('not logged in') ||
                logoutText.contains('already logged out');
            if (!alreadyLoggedOut) {
              return logoutResult;
            }
          }
        }

        return widget.service.connect(
          authKey: usingAuthKey ? authKey : null,
          forceReauth: !usingAuthKey,
          reset: true,
        );
      },
    );
  }

  Future<void> _setupThisLaptop() async {
    final authKey = _authKeyController.text.trim();
    if (authKey.isEmpty) {
      setState(() {
        _infoMessage =
            'Enter a valid tskey in Auth key to setup this laptop automatically.';
      });
      return;
    }

    await _saveKeyPreferences();

    await _runAction(
      successMessage: _setupEnableTailscaleSsh
          ? 'This laptop joined the tailnet and enabled Tailscale SSH.'
          : 'This laptop joined the tailnet.',
      action: () => widget.service.connect(
        authKey: authKey,
        reset: true,
        forceReauth: false,
        enableSsh: _setupEnableTailscaleSsh,
      ),
    );
  }

  Future<void> _toggleConnection() async {
    final connected = _snapshot?.isConnected ?? false;
    if (connected) {
      await _runAction(
        successMessage: 'Tailscale disconnected.',
        action: widget.service.disconnect,
      );
      return;
    }

    await _runAction(
      successMessage: 'Tailscale connected.',
      action: () => widget.service.connect(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final connected = snapshot?.isConnected ?? false;
    final stateText = snapshot?.backendState ?? 'Unknown';
    final stateColor = connected ? Colors.green : Colors.orange;
    final remoteCandidates = snapshot?.peers ?? const <TailscalePeer>[];
    final selectedRemoteDns = _selectedRemoteDeviceDns;
    final lastUpdatedText = _lastUpdated == null
        ? 'Not yet'
        : _lastUpdated!.toLocal().toIso8601String().replaceFirst('T', ' ');

    return Scaffold(
      appBar: AppBar(title: const Text('ScaleServe Tailscale Controller')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.circle, size: 12, color: stateColor),
                            const SizedBox(width: 8),
                            Text(
                              'State: $stateText',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text('Device: ${snapshot?.selfName ?? 'Unknown'}'),
                        Text('User: ${snapshot?.loginName ?? 'Unknown'}'),
                        Text('Tailnet: ${snapshot?.tailnetName ?? 'Unknown'}'),
                        Text(
                          'Tailnet DNS: ${snapshot?.magicDnsSuffix ?? 'Unknown'}',
                        ),
                        Text('Last updated: $lastUpdatedText'),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            FilledButton.icon(
                              onPressed: _isBusy
                                  ? null
                                  : () => _refreshStatus(showLoader: true),
                              icon: const Icon(Icons.refresh),
                              label: const Text('Refresh status'),
                            ),
                            FilledButton.icon(
                              onPressed: _isBusy ? null : _toggleConnection,
                              icon: Icon(
                                connected ? Icons.power_off : Icons.power,
                              ),
                              label: Text(connected ? 'Disconnect' : 'Connect'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _isBusy
                                  ? null
                                  : () => _runAction(
                                      successMessage: 'Tailscale connected.',
                                      action: () => widget.service.connect(),
                                    ),
                              icon: const Icon(Icons.link),
                              label: const Text('Run tailscale up'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _isBusy
                                  ? null
                                  : () => _runAction(
                                      successMessage: 'Tailscale disconnected.',
                                      action: widget.service.disconnect,
                                    ),
                              icon: const Icon(Icons.link_off),
                              label: const Text('Run tailscale down'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Remote Compute Runner',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Run a shell command on a selected tailnet device through SSH. '
                          'Save per-device user/key defaults and keep execution history.',
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'SSH Access Setup',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 6),
                              Text(_sshKeyStatusText),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: [
                                  FilledButton.icon(
                                    onPressed: _generatingSshKey
                                        ? null
                                        : _generateSshKeyPair,
                                    icon: const Icon(Icons.key),
                                    label: Text(
                                      _sshPublicKey.isEmpty
                                          ? 'Generate SSH Key'
                                          : 'Regenerate / Ensure Key',
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: _sshPublicKey.isEmpty
                                        ? null
                                        : _copyPublicKey,
                                    icon: const Icon(Icons.copy),
                                    label: const Text('Copy Public Key'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: _sshPublicKey.isEmpty
                                        ? null
                                        : _copyLinuxSshBootstrapCommand,
                                    icon: const Icon(Icons.terminal),
                                    label: const Text(
                                      'Copy Linux SSH Setup Command',
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed:
                                        _runningRemoteCommand ||
                                            _detectingRemoteUser
                                        ? null
                                        : _installPublicKeyOnRemote,
                                    icon: const Icon(
                                      Icons.published_with_changes,
                                    ),
                                    label: const Text('Install Key On Remote'),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed:
                                        _runningRemoteCommand ||
                                            _detectingRemoteUser
                                        ? null
                                        : _detectRemoteSshUser,
                                    icon: const Icon(Icons.person_search),
                                    label: Text(
                                      _detectingRemoteUser
                                          ? 'Detecting...'
                                          : 'Detect SSH User',
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed:
                                        _runningRemoteCommand ||
                                            _detectingRemoteUser
                                        ? null
                                        : _testSshAccess,
                                    icon: const Icon(Icons.verified_user),
                                    label: const Text('Test SSH Access'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Run the copied Linux SSH setup command on the target machine once. '
                                'This installs your public key into authorized_keys. '
                                'Or use Install Key On Remote if you can already SSH in with an existing key. '
                                'Then use Detect SSH User to auto-fill the working login name.',
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue:
                              (selectedRemoteDns != null &&
                                  remoteCandidates.any(
                                    (peer) =>
                                        peer.normalizedDnsName ==
                                        selectedRemoteDns,
                                  ))
                              ? selectedRemoteDns
                              : null,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Target device',
                          ),
                          items: remoteCandidates
                              .map(
                                (peer) => DropdownMenuItem<String>(
                                  value: peer.normalizedDnsName,
                                  child: Text(
                                    '${peer.name} (${peer.normalizedDnsName})',
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged:
                              _runningRemoteCommand || _detectingRemoteUser
                              ? null
                              : (value) => _selectRemoteDevice(value),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _remoteUserController,
                          enabled:
                              !_runningRemoteCommand && !_detectingRemoteUser,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Remote SSH user',
                            hintText: 'ubuntu / opc / ec2-user',
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _remoteKeyPathController,
                          enabled:
                              !_runningRemoteCommand && !_detectingRemoteUser,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'SSH key path (optional)',
                            hintText: '~/.ssh/id_ed25519',
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _bootstrapKeyPathController,
                          enabled:
                              !_runningRemoteCommand && !_detectingRemoteUser,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Bootstrap key path (first-time setup)',
                            hintText: '~/.ssh/oracle_server_key.pem',
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _remoteCommandController,
                          enabled:
                              !_runningRemoteCommand && !_detectingRemoteUser,
                          minLines: 2,
                          maxLines: 4,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Remote command',
                            hintText:
                                'cd /path/to/project && python3 script.py',
                          ),
                        ),
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.black12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Run Local File On Remote Compute',
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Streams a local file over SSH stdin so it runs on remote CPU '
                                'without a permanent upload.',
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                controller: _localStreamFilePathController,
                                enabled:
                                    !_runningRemoteCommand &&
                                    !_detectingRemoteUser,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: 'Local file path to stream',
                                  hintText: '/Users/you/path/script.py',
                                ),
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                controller: _remoteStdinCommandController,
                                enabled:
                                    !_runningRemoteCommand &&
                                    !_detectingRemoteUser,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  labelText: 'Remote command (reads stdin)',
                                  hintText: 'python3 -',
                                ),
                              ),
                              const SizedBox(height: 10),
                              FilledButton.icon(
                                onPressed:
                                    _runningRemoteCommand ||
                                        _detectingRemoteUser
                                    ? null
                                    : _runLocalFileOnRemoteCompute,
                                icon: const Icon(Icons.upload_file),
                                label: const Text('Stream Local File And Run'),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            FilledButton.icon(
                              onPressed:
                                  _runningRemoteCommand || _detectingRemoteUser
                                  ? null
                                  : _runRemoteCommand,
                              icon: const Icon(Icons.play_arrow),
                              label: const Text('Run On Selected Device'),
                            ),
                            OutlinedButton.icon(
                              onPressed:
                                  _runningRemoteCommand || _detectingRemoteUser
                                  ? null
                                  : () => _saveRemoteProfile(showMessage: true),
                              icon: const Icon(Icons.save),
                              label: const Text('Save Device Profile'),
                            ),
                            TextButton(
                              onPressed:
                                  _runningRemoteCommand ||
                                      _detectingRemoteUser ||
                                      _remoteExecutionHistory.isEmpty
                                  ? null
                                  : _clearRemoteHistory,
                              child: const Text('Clear Run History'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        if (_runningRemoteCommand || _detectingRemoteUser)
                          const LinearProgressIndicator(),
                        const SizedBox(height: 8),
                        SelectableText(_remoteLiveOutput),
                        const SizedBox(height: 12),
                        Text(
                          'Run history',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        if (_remoteExecutionHistory.isEmpty)
                          const Text('No remote commands run yet.')
                        else
                          ..._remoteExecutionHistory
                              .take(8)
                              .map(
                                (record) => ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    record.success
                                        ? Icons.check_circle
                                        : Icons.error_outline,
                                    color: record.success
                                        ? Colors.green
                                        : Colors.red,
                                  ),
                                  title: Text(
                                    '${record.user}@${record.deviceDnsName}',
                                  ),
                                  subtitle: Text(
                                    '${record.command}\n${_historyTime(record.startedAtIso)}  •  exit ${record.exitCode}',
                                  ),
                                  isThreeLine: true,
                                ),
                              ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Re-auth / Switch Tailnet',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Tailscale keeps one active connection per device. '
                          'This action re-authenticates this device or switches to another tailnet. '
                          'Use an auth key from a different tailnet to actually switch.',
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'On a new laptop, use the one-click setup button below to join this tailnet with SSH enabled.',
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _authKeyController,
                          enabled: !_isBusy,
                          obscureText: true,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Auth key (optional)',
                            hintText: 'tskey-...',
                          ),
                        ),
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text(
                            'Remember auth key on this computer',
                          ),
                          value: _rememberAuthKey,
                          onChanged: _isBusy
                              ? null
                              : (value) {
                                  setState(() {
                                    _rememberAuthKey = value ?? false;
                                  });
                                },
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text(
                            'Auto-connect on app launch with saved key',
                          ),
                          value: _autoConnectOnLaunch,
                          onChanged: _isBusy
                              ? null
                              : (value) {
                                  setState(() {
                                    _autoConnectOnLaunch = value ?? false;
                                  });
                                },
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text(
                            'Enable Tailscale SSH during one-click setup',
                          ),
                          value: _setupEnableTailscaleSsh,
                          onChanged: _isBusy
                              ? null
                              : (value) {
                                  setState(() {
                                    _setupEnableTailscaleSsh = value ?? true;
                                  });
                                },
                        ),
                        Row(
                          children: [
                            OutlinedButton.icon(
                              onPressed: _isBusy ? null : _saveKeyPreferences,
                              icon: const Icon(Icons.save),
                              label: const Text('Save key preferences'),
                            ),
                            const SizedBox(width: 10),
                            TextButton(
                              onPressed: _isBusy || !_hasStoredKey
                                  ? null
                                  : _clearSavedKey,
                              child: const Text('Clear saved key'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            FilledButton.icon(
                              onPressed: _isBusy ? null : _connectNewSession,
                              icon: const Icon(Icons.add_link),
                              label: const Text('Re-authenticate'),
                            ),
                            FilledButton.icon(
                              onPressed: _isBusy ? null : _setupThisLaptop,
                              icon: const Icon(Icons.rocket_launch),
                              label: const Text('One-Click Setup This Laptop'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Automation',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'No shared Gmail needed. Install Tailscale on each PC and run one of these join commands '
                          'to connect devices to the same tailnet.',
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _isBusy
                                  ? null
                                  : () => _copyToClipboard(
                                      text: _macJoinCommand(),
                                      successMessage:
                                          'Copied macOS join command.',
                                    ),
                              icon: const Icon(Icons.desktop_mac),
                              label: const Text('Copy macOS join command'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _isBusy
                                  ? null
                                  : () => _copyToClipboard(
                                      text: _windowsJoinCommand(),
                                      successMessage:
                                          'Copied Windows join command.',
                                    ),
                              icon: const Icon(Icons.desktop_windows),
                              label: const Text('Copy Windows join command'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _isBusy
                                  ? null
                                  : () => _copyToClipboard(
                                      text: _linuxJoinCommand(),
                                      successMessage:
                                          'Copied Linux join command.',
                                    ),
                              icon: const Icon(Icons.computer),
                              label: const Text('Copy Linux join command'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'If auth key field is blank, copied command will include tskey-REPLACE_ME placeholder.',
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Connected devices',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        if (snapshot == null || snapshot.peers.isEmpty)
                          const Text('No peers found from current status.')
                        else ...[
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            leading: const Icon(
                              Icons.laptop_mac,
                              color: Colors.blueGrey,
                            ),
                            title: Text('${snapshot.selfName} (This device)'),
                            subtitle: Text(
                              '${snapshot.selfIpAddress}  •  ${snapshot.selfDnsName}',
                            ),
                          ),
                          ...snapshot.peers.map(
                            (peer) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              leading: Icon(
                                peer.online
                                    ? Icons.check_circle
                                    : Icons.remove_circle_outline,
                                color: peer.online ? Colors.green : Colors.grey,
                              ),
                              title: Text(peer.name),
                              subtitle: Text(
                                '${peer.ipAddress}  •  ${peer.normalizedDnsName}  •  ${peer.os}',
                              ),
                              trailing: PopupMenuButton<String>(
                                tooltip: 'Device actions',
                                onSelected: (value) => _handlePeerMenuAction(
                                  peer: peer,
                                  action: value,
                                ),
                                itemBuilder: (context) => const [
                                  PopupMenuItem(
                                    value: 'select_remote',
                                    child: Text('Use in Remote Runner'),
                                  ),
                                  PopupMenuItem(
                                    value: 'ping_now',
                                    child: Text('Ping now'),
                                  ),
                                  PopupMenuItem(
                                    value: 'copy_ping',
                                    child: Text('Copy ping command'),
                                  ),
                                  PopupMenuItem(
                                    value: 'copy_ssh',
                                    child: Text('Copy SSH command template'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Command output',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        if (_loadingStatus || _runningAction)
                          const LinearProgressIndicator(),
                        const SizedBox(height: 8),
                        SelectableText(
                          _latestCommandOutput.isEmpty
                              ? 'No command run yet.'
                              : _latestCommandOutput,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(_infoMessage),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
