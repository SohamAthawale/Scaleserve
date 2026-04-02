import 'dart:async';

import 'package:flutter/material.dart';

import 'local_settings_store.dart';
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
  final LocalSettingsStore _settingsStore = LocalSettingsStore();
  final TextEditingController _authKeyController = TextEditingController();

  TailscaleSnapshot? _snapshot;
  String _infoMessage = 'Checking Tailscale status...';
  String _latestCommandOutput = '';
  DateTime? _lastUpdated;

  bool _loadingStatus = true;
  bool _runningAction = false;
  bool _rememberAuthKey = false;
  bool _autoConnectOnLaunch = false;
  bool _hasStoredKey = false;
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

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _authKeyController.dispose();
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
                          'Re-auth / Switch Tailnet',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Tailscale keeps one active connection per device. '
                          'This action re-authenticates this device or switches to another tailnet. '
                          'Use an auth key from a different tailnet to actually switch.',
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
                        FilledButton.icon(
                          onPressed: _isBusy ? null : _connectNewSession,
                          icon: const Icon(Icons.add_link),
                          label: const Text('Re-authenticate'),
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
                                '${peer.ipAddress}  •  ${peer.dnsName}',
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
