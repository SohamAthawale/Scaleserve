import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_user.dart';
import 'backend_auth_service.dart';
import 'local_settings_store.dart';
import 'remote_compute_store.dart';
import 'scaleserve_branding.dart';
import 'ssh_key_manager.dart';
import 'tailscale_service.dart';

void main() {
  runApp(const ScaleServeApp());
}

enum _DashboardSection { overview, remote, access, devices, logs }

extension on _DashboardSection {
  String get label {
    switch (this) {
      case _DashboardSection.overview:
        return 'Overview';
      case _DashboardSection.remote:
        return 'Remote Runner';
      case _DashboardSection.access:
        return 'Access & Auth';
      case _DashboardSection.devices:
        return 'Devices';
      case _DashboardSection.logs:
        return 'Logs';
    }
  }

  IconData get icon {
    switch (this) {
      case _DashboardSection.overview:
        return Icons.dashboard_outlined;
      case _DashboardSection.remote:
        return Icons.terminal_outlined;
      case _DashboardSection.access:
        return Icons.vpn_key_outlined;
      case _DashboardSection.devices:
        return Icons.devices_outlined;
      case _DashboardSection.logs:
        return Icons.article_outlined;
    }
  }
}

class _RemoteCommandPreset {
  const _RemoteCommandPreset({
    required this.id,
    required this.label,
    required this.description,
  });

  final String id;
  final String label;
  final String description;
}

class _StreamCommandPreset {
  const _StreamCommandPreset({
    required this.id,
    required this.label,
    required this.description,
    required this.posixCommand,
    required this.windowsCommand,
    this.supportsInteractiveInput = false,
  });

  final String id;
  final String label;
  final String description;
  final String posixCommand;
  final String windowsCommand;
  final bool supportsInteractiveInput;
}

class _RemoteMultiRunFileEntry {
  _RemoteMultiRunFileEntry({required this.id})
    : filePathController = TextEditingController(),
      remoteCommandController = TextEditingController(),
      windowsCleanupPatternController = TextEditingController(
        text: 'scaleserve_stream',
      ),
      runtimeInputController = TextEditingController();

  final String id;
  final TextEditingController filePathController;
  final TextEditingController remoteCommandController;
  final TextEditingController windowsCleanupPatternController;
  final TextEditingController runtimeInputController;
  String selectedStreamPresetId = 'custom_stdin';
  String output = '';
  String statusText = 'Idle';
  bool isRunning = false;
  bool stopRequested = false;
  bool enableInteractiveInputForPythonStreamRuns = false;
  bool autoKillWindowsPythonAfterStreamRun = true;
  bool activeRunSupportsRuntimeInput = false;
  Process? activeProcess;

  void dispose() {
    filePathController.dispose();
    remoteCommandController.dispose();
    windowsCleanupPatternController.dispose();
    runtimeInputController.dispose();
  }
}

class _RemoteMultiRunSystemGroup {
  _RemoteMultiRunSystemGroup({required this.id, required this.jobs});

  final String id;
  String? selectedDeviceDns;
  final List<_RemoteMultiRunFileEntry> jobs;

  void dispose() {
    for (final job in jobs) {
      job.dispose();
    }
  }
}

class _RemoteMultiRunJobRequest {
  const _RemoteMultiRunJobRequest({
    required this.systemGroup,
    required this.fileEntry,
    required this.dnsName,
    required this.user,
    required this.keyPath,
    required this.localFilePath,
    required this.remoteCommand,
    required this.safeCommand,
    required this.isWindowsTarget,
    required this.windowsCleanupPattern,
    required this.enableInteractiveInput,
    required this.autoKillWindowsPythonAfterStreamRun,
  });

  final _RemoteMultiRunSystemGroup systemGroup;
  final _RemoteMultiRunFileEntry fileEntry;
  final String dnsName;
  final String user;
  final String keyPath;
  final String localFilePath;
  final String remoteCommand;
  final String safeCommand;
  final bool isWindowsTarget;
  final String windowsCleanupPattern;
  final bool enableInteractiveInput;
  final bool autoKillWindowsPythonAfterStreamRun;
}

class _RemoteMultiRunJobOutcome {
  const _RemoteMultiRunJobOutcome({
    required this.systemId,
    required this.fileEntryId,
    required this.record,
    required this.summary,
    required this.stoppedByUser,
  });

  final String systemId;
  final String fileEntryId;
  final RemoteExecutionRecord record;
  final String summary;
  final bool stoppedByUser;
}

class ScaleServeApp extends StatefulWidget {
  const ScaleServeApp({
    super.key,
    this.service,
    this.authService,
    this.startAutoRefresh = true,
    this.fetchOnStartup = true,
    this.requireLogin = true,
  });

  final TailscaleService? service;
  final BackendAuthService? authService;
  final bool startAutoRefresh;
  final bool fetchOnStartup;
  final bool requireLogin;

  @override
  State<ScaleServeApp> createState() => _ScaleServeAppState();
}

class _ScaleServeAppState extends State<ScaleServeApp> {
  late final BackendAuthService _authService;
  AppUser? _signedInUser;

  @override
  void initState() {
    super.initState();
    _authService = widget.authService ?? BackendAuthService();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = scaleServeColorScheme();

    return MaterialApp(
      title: 'ScaleServe',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        scaffoldBackgroundColor: ScaleServeBrandPalette.obsidian,
        visualDensity: VisualDensity.comfortable,
        appBarTheme: AppBarTheme(
          centerTitle: false,
          backgroundColor: ScaleServeBrandPalette.obsidian.withValues(
            alpha: 0.82,
          ),
          foregroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(
              color: colorScheme.outline.withValues(alpha: 0.18),
            ),
          ),
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.94),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
              color: colorScheme.outline.withValues(alpha: 0.18),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
              color: colorScheme.outline.withValues(alpha: 0.18),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: colorScheme.primary, width: 1.4),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            backgroundColor: colorScheme.primary,
            foregroundColor: colorScheme.onPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            foregroundColor: colorScheme.primary,
            side: BorderSide(color: colorScheme.outline.withValues(alpha: 0.3)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        chipTheme: ChipThemeData(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          labelStyle: TextStyle(
            color: colorScheme.onSurface,
            fontWeight: FontWeight.w600,
          ),
          backgroundColor: Colors.white.withValues(alpha: 0.82),
          selectedColor: colorScheme.primaryContainer,
          side: BorderSide(color: colorScheme.outline.withValues(alpha: 0.2)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
      home: _buildHome(),
    );
  }

  Widget _buildHome() {
    final effectiveService = widget.service ?? TailscaleService();
    if (!widget.requireLogin) {
      return TailscaleDashboardPage(
        service: effectiveService,
        startAutoRefresh: widget.startAutoRefresh,
        fetchOnStartup: widget.fetchOnStartup,
      );
    }

    final user = _signedInUser;
    if (user == null) {
      return ScaleServeLoginPage(
        authService: _authService,
        onAuthenticated: (authenticatedUser) {
          if (!mounted) {
            return;
          }
          setState(() {
            _signedInUser = authenticatedUser;
          });
        },
      );
    }

    return TailscaleDashboardPage(
      service: effectiveService,
      startAutoRefresh: widget.startAutoRefresh,
      fetchOnStartup: widget.fetchOnStartup,
      signedInUser: user,
      onLogout: () {
        if (!mounted) {
          return;
        }
        setState(() {
          _signedInUser = null;
        });
      },
    );
  }
}

class ScaleServeLoginPage extends StatefulWidget {
  const ScaleServeLoginPage({
    super.key,
    required this.authService,
    required this.onAuthenticated,
  });

  final BackendAuthService authService;
  final ValueChanged<AppUser> onAuthenticated;

  @override
  State<ScaleServeLoginPage> createState() => _ScaleServeLoginPageState();
}

class _ScaleServeLoginPageState extends State<ScaleServeLoginPage> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  final TextEditingController _mfaCodeController = TextEditingController();

  bool _loading = true;
  bool _working = false;
  bool _setupMode = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _obscureMfaCode = true;
  bool _enableMfaForNewAccount = false;
  String _statusText = 'Loading authentication...';
  AppUser? _pendingMfaUser;
  String? _pendingMfaEmail;

  bool get _inMfaStep => _pendingMfaUser != null;

  @override
  void initState() {
    super.initState();
    _loadMode();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _mfaCodeController.dispose();
    super.dispose();
  }

  Future<void> _loadMode() async {
    setState(() {
      _loading = true;
      _statusText = 'Loading authentication...';
      _pendingMfaUser = null;
      _pendingMfaEmail = null;
      _mfaCodeController.clear();
    });

    try {
      final hasUsers = await widget.authService.hasUsers();
      if (!mounted) {
        return;
      }

      setState(() {
        _loading = false;
        _setupMode = !hasUsers;
        _statusText = _setupMode
            ? 'No operator account found. Create one to continue.'
            : 'Sign in with your Gmail and password.';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _statusText = 'Backend authentication unavailable: $error';
      });
    }
  }

  Future<void> _signIn() async {
    if (_working) {
      return;
    }
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _statusText = 'Enter Gmail and password.';
      });
      return;
    }

    setState(() {
      _working = true;
      _statusText = 'Validating credentials...';
    });

    try {
      final result = await widget.authService.login(
        email: email,
        password: password,
      );
      if (!mounted) {
        return;
      }
      if (!result.success) {
        setState(() {
          _working = false;
          _statusText = result.message;
        });
        return;
      }

      if (result.mfaRequired) {
        final user = result.user;
        final mfaEmail = ((user?.email ?? email)).trim();
        if (user == null || mfaEmail.isEmpty) {
          setState(() {
            _working = false;
            _statusText = 'MFA is required but recovery Gmail was unavailable.';
          });
          return;
        }
        setState(() {
          _working = false;
          _pendingMfaUser = user;
          _pendingMfaEmail = mfaEmail;
          _passwordController.clear();
          _statusText = 'MFA OTP sent to ${result.maskedEmail ?? '(hidden)'}.';
        });
        return;
      }

      final user = result.user;
      if (user == null) {
        setState(() {
          _working = false;
          _statusText = 'Sign-in succeeded but user payload was missing.';
        });
        return;
      }
      _passwordController.clear();
      widget.onAuthenticated(user);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _working = false;
        _statusText = 'Sign-in failed: $error';
      });
    }
  }

  Future<void> _createFirstAccount() async {
    if (_working) {
      return;
    }
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmPasswordController.text;

    if (email.isEmpty || password.isEmpty || confirm.isEmpty) {
      setState(() {
        _statusText = 'Fill Gmail, password, and confirm password.';
      });
      return;
    }
    if (password != confirm) {
      setState(() {
        _statusText = 'Password and confirm password must match.';
      });
      return;
    }

    setState(() {
      _working = true;
      _statusText = 'Creating first operator account...';
    });

    try {
      final result = await widget.authService.bootstrapFirstUser(
        email: email,
        password: password,
        mfaEnabled: _enableMfaForNewAccount,
      );
      if (!mounted) {
        return;
      }
      if (!result.success || result.user == null) {
        setState(() {
          _working = false;
          final message = result.message.toLowerCase();
          if (message.contains('bootstrap already completed') ||
              message.contains('users already exist')) {
            _setupMode = false;
            _statusText =
                'Account already exists. Sign in with Gmail and password.';
            _confirmPasswordController.clear();
          } else {
            _statusText = result.message;
          }
        });
        return;
      }

      _confirmPasswordController.clear();
      _passwordController.clear();
      widget.onAuthenticated(result.user!);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _working = false;
        _statusText = 'Could not create account: $error';
      });
    }
  }

  Future<void> _verifyMfaCode() async {
    if (_working) {
      return;
    }
    final user = _pendingMfaUser;
    final email = (_pendingMfaEmail ?? '').trim();
    final otp = _mfaCodeController.text.trim();
    if (user == null) {
      return;
    }
    if (email.isEmpty) {
      setState(() {
        _statusText = 'Recovery Gmail is missing for MFA verification.';
      });
      return;
    }
    if (otp.isEmpty) {
      setState(() {
        _statusText = 'Enter the MFA OTP.';
      });
      return;
    }

    setState(() {
      _working = true;
      _statusText = 'Verifying MFA OTP...';
    });

    try {
      final result = await widget.authService.verifyMfaOtp(
        email: email,
        otp: otp,
      );
      if (!mounted) {
        return;
      }
      if (!result.success || result.user == null) {
        setState(() {
          _working = false;
          _statusText = result.message;
        });
        return;
      }

      _mfaCodeController.clear();
      widget.onAuthenticated(result.user!);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _working = false;
        _statusText = 'MFA verification failed: $error';
      });
    }
  }

  Future<void> _resendMfaCode() async {
    if (_working) {
      return;
    }
    final email = (_pendingMfaEmail ?? '').trim();
    if (email.isEmpty) {
      return;
    }

    setState(() {
      _working = true;
      _statusText = 'Sending new MFA OTP...';
    });

    try {
      final result = await widget.authService.requestLoginMfaOtp(email: email);
      if (!mounted) {
        return;
      }
      setState(() {
        _working = false;
        _statusText = result.success
            ? 'New MFA OTP sent to ${result.maskedEmail ?? '(hidden)'}.'
            : 'Could not resend MFA OTP: ${result.message}';
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _working = false;
        _statusText = 'Could not resend MFA OTP: $error';
      });
    }
  }

  void _cancelMfaStep() {
    setState(() {
      _pendingMfaUser = null;
      _pendingMfaEmail = null;
      _mfaCodeController.clear();
      _statusText = 'MFA cancelled. Sign in again.';
    });
  }

  Future<void> _openForgotPasswordDialog() async {
    if (_working) {
      return;
    }
    final email = _emailController.text.trim();
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return ForgotPasswordDialog(
          authService: widget.authService,
          initialEmail: email,
        );
      },
    );

    if (!mounted || result == null || result.isEmpty) {
      return;
    }

    setState(() {
      _emailController.text = result;
      _passwordController.clear();
      _statusText = 'Password reset complete. Sign in with your new password.';
    });
  }

  Widget _buildBrandStoryCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        constraints: const BoxConstraints(minHeight: 360),
        decoration: BoxDecoration(
          gradient: ScaleServeBrandPalette.brandGradient,
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: Colors.white.withValues(alpha: 0.10),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                child: Text(
                  'SIGNAL-FIRST BRANDING',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const ScaleServeBrandLockupImage(height: 72),
              const SizedBox(height: 20),
              const ScaleServeBrandVideoPanel(),
              const SizedBox(height: 20),
              Text(
                'This panel now uses the exact branding photo and motion asset from your project, sized directly into the UI instead of recreating the logo in code.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.72),
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: const [
                  ScaleServeFeatureBadge(
                    icon: Icons.bolt_outlined,
                    label: 'Exact photo lockup',
                    backgroundColor: Color(0x1AFFFFFF),
                    foregroundColor: Colors.white,
                    borderColor: Color(0x24FFFFFF),
                  ),
                  ScaleServeFeatureBadge(
                    icon: Icons.play_circle_outline,
                    label: 'Exact motion asset',
                    backgroundColor: Color(0x1AFFFFFF),
                    foregroundColor: Colors.white,
                    borderColor: Color(0x24FFFFFF),
                  ),
                  ScaleServeFeatureBadge(
                    icon: Icons.aspect_ratio_outlined,
                    label: 'Sized for UI',
                    backgroundColor: Color(0x1AFFFFFF),
                    foregroundColor: Colors.white,
                    borderColor: Color(0x24FFFFFF),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  color: Colors.white.withValues(alpha: 0.08),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Brand direction',
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Keep the system stark. Black does the heavy lifting, the green mark does the recognition work, and the white type keeps the product feeling immediate and confident.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.74),
                        height: 1.55,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAuthCard(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const ScaleServeBrandLockupImage(height: 58),
            const SizedBox(height: 12),
            Text(
              _setupMode
                  ? 'Create the first operator account to initialize the workspace.'
                  : (_inMfaStep
                        ? 'Confirm the one-time code sent to your recovery Gmail.'
                        : 'Sign in to the operator console.'),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _setupMode
                  ? 'Create first operator account'
                  : (_inMfaStep ? 'Verify MFA OTP' : 'Operator sign in'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _inMfaStep
                  ? 'A one-time code has been sent to your recovery Gmail.'
                  : 'Authentication is validated through the backend API and PostgreSQL source of truth.',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
            ),
            const SizedBox(height: 16),
            if (_loading) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
            ],
            if (_inMfaStep) ...[
              TextField(
                controller: _mfaCodeController,
                enabled: !_loading && !_working,
                obscureText: _obscureMfaCode,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (!_loading && !_working) {
                    _verifyMfaCode();
                  }
                },
                decoration: InputDecoration(
                  labelText: 'MFA OTP',
                  hintText: '6-digit code',
                  suffixIcon: IconButton(
                    onPressed: _loading || _working
                        ? null
                        : () {
                            setState(() {
                              _obscureMfaCode = !_obscureMfaCode;
                            });
                          },
                    icon: Icon(
                      _obscureMfaCode ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
            ] else ...[
              TextField(
                controller: _emailController,
                enabled: !_loading && !_working,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Gmail',
                  hintText: 'you@gmail.com',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _passwordController,
                enabled: !_loading && !_working,
                obscureText: _obscurePassword,
                textInputAction: _setupMode
                    ? TextInputAction.next
                    : TextInputAction.done,
                onSubmitted: _setupMode
                    ? null
                    : (_) {
                        if (!_loading && !_working) {
                          _signIn();
                        }
                      },
                decoration: InputDecoration(
                  labelText: 'Password',
                  hintText: 'Minimum 8 characters',
                  suffixIcon: IconButton(
                    onPressed: _loading || _working
                        ? null
                        : () {
                            setState(() {
                              _obscurePassword = !_obscurePassword;
                            });
                          },
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility
                          : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
              if (_setupMode) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _confirmPasswordController,
                  enabled: !_loading && !_working,
                  obscureText: _obscureConfirmPassword,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) {
                    if (!_loading && !_working) {
                      _createFirstAccount();
                    }
                  },
                  decoration: InputDecoration(
                    labelText: 'Confirm password',
                    suffixIcon: IconButton(
                      onPressed: _loading || _working
                          ? null
                          : () {
                              setState(() {
                                _obscureConfirmPassword =
                                    !_obscureConfirmPassword;
                              });
                            },
                      icon: Icon(
                        _obscureConfirmPassword
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _enableMfaForNewAccount,
                  onChanged: _loading || _working
                      ? null
                      : (value) {
                          setState(() {
                            _enableMfaForNewAccount = value ?? false;
                          });
                        },
                  title: const Text('Enable MFA at sign-in'),
                  subtitle: const Text(
                    'Requires OTP sender Gmail configured on the backend.',
                  ),
                ),
              ] else ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _loading || _working
                        ? null
                        : _openForgotPasswordDialog,
                    child: const Text('Forgot password?'),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 14),
            if (_inMfaStep)
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: _loading || _working ? null : _verifyMfaCode,
                    icon: const Icon(Icons.verified_user),
                    label: Text(_working ? 'Please wait...' : 'Verify OTP'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _loading || _working ? null : _resendMfaCode,
                    icon: const Icon(Icons.mark_email_unread_outlined),
                    label: const Text('Resend OTP'),
                  ),
                  TextButton(
                    onPressed: _loading || _working ? null : _cancelMfaStep,
                    child: const Text('Cancel'),
                  ),
                ],
              )
            else
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _loading || _working
                          ? null
                          : (_setupMode ? _createFirstAccount : _signIn),
                      icon: Icon(_setupMode ? Icons.person_add : Icons.login),
                      label: Text(
                        _working
                            ? 'Please wait...'
                            : (_setupMode
                                  ? 'Create Account & Sign In'
                                  : 'Sign In'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _working ? null : _loadMode,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: theme.colorScheme.primaryContainer.withValues(
                  alpha: 0.46,
                ),
                border: Border.all(
                  color: theme.colorScheme.outline.withValues(alpha: 0.16),
                ),
              ),
              child: Text(
                _statusText,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ScaleServeShellBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 980;
              final authCard = ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: _buildAuthCard(context),
              );

              return SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1180),
                    child: isWide
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(child: _buildBrandStoryCard(context)),
                              const SizedBox(width: 24),
                              SizedBox(width: 480, child: authCard),
                            ],
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildBrandStoryCard(context),
                              const SizedBox(height: 20),
                              Center(child: authCard),
                            ],
                          ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class ForgotPasswordDialog extends StatefulWidget {
  const ForgotPasswordDialog({
    super.key,
    required this.authService,
    required this.initialEmail,
  });

  final BackendAuthService authService;
  final String initialEmail;

  @override
  State<ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<ForgotPasswordDialog> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _otpController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();

  bool _working = false;
  bool _otpSent = false;
  bool _obscureNewPassword = true;
  bool _obscureConfirmPassword = true;
  String _statusText = 'Enter recovery Gmail to send password reset OTP.';

  @override
  void initState() {
    super.initState();
    _emailController.text = widget.initialEmail;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _otpController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _sendOtp() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() {
        _statusText = 'Enter Gmail first.';
      });
      return;
    }

    setState(() {
      _working = true;
      _statusText = 'Sending password reset OTP...';
    });

    try {
      final result = await widget.authService.requestForgotPasswordOtp(
        email: email,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _working = false;
        _otpSent = result.success;
        _statusText = result.success
            ? 'OTP sent to ${result.maskedEmail ?? '(hidden)'}.'
            : result.message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _working = false;
        _statusText = 'Could not send OTP: $error';
      });
    }
  }

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim();
    final otp = _otpController.text.trim();
    final newPassword = _newPasswordController.text;
    final confirm = _confirmPasswordController.text;

    if (email.isEmpty ||
        otp.isEmpty ||
        newPassword.isEmpty ||
        confirm.isEmpty) {
      setState(() {
        _statusText = 'Fill Gmail, OTP, and both password fields.';
      });
      return;
    }
    if (newPassword != confirm) {
      setState(() {
        _statusText = 'New password and confirm password must match.';
      });
      return;
    }

    setState(() {
      _working = true;
      _statusText = 'Resetting password...';
    });

    try {
      final result = await widget.authService.resetPassword(
        email: email,
        otp: otp,
        newPassword: newPassword,
      );
      if (!mounted) {
        return;
      }
      if (!result.success) {
        setState(() {
          _working = false;
          _statusText = result.message;
        });
        return;
      }
      Navigator.of(context).pop(email);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _working = false;
        _statusText = 'Password reset failed: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Forgot Password'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _emailController,
              enabled: !_working,
              decoration: const InputDecoration(
                labelText: 'Recovery Gmail',
                hintText: 'you@gmail.com',
              ),
            ),
            const SizedBox(height: 10),
            if (_otpSent) ...[
              TextField(
                controller: _otpController,
                enabled: !_working,
                decoration: const InputDecoration(
                  labelText: 'OTP',
                  hintText: '6-digit code',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _newPasswordController,
                enabled: !_working,
                obscureText: _obscureNewPassword,
                decoration: InputDecoration(
                  labelText: 'New password',
                  hintText: 'Minimum 8 characters',
                  suffixIcon: IconButton(
                    onPressed: _working
                        ? null
                        : () {
                            setState(() {
                              _obscureNewPassword = !_obscureNewPassword;
                            });
                          },
                    icon: Icon(
                      _obscureNewPassword
                          ? Icons.visibility
                          : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _confirmPasswordController,
                enabled: !_working,
                obscureText: _obscureConfirmPassword,
                decoration: InputDecoration(
                  labelText: 'Confirm new password',
                  suffixIcon: IconButton(
                    onPressed: _working
                        ? null
                        : () {
                            setState(() {
                              _obscureConfirmPassword =
                                  !_obscureConfirmPassword;
                            });
                          },
                    icon: Icon(
                      _obscureConfirmPassword
                          ? Icons.visibility
                          : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: Theme.of(
                  context,
                ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
              ),
              child: Text(_statusText),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (_otpSent)
          OutlinedButton(
            onPressed: _working ? null : _sendOtp,
            child: const Text('Resend OTP'),
          ),
        FilledButton(
          onPressed: _working ? null : (_otpSent ? _resetPassword : _sendOtp),
          child: Text(_otpSent ? 'Reset Password' : 'Send OTP'),
        ),
      ],
    );
  }
}

class TailscaleDashboardPage extends StatefulWidget {
  const TailscaleDashboardPage({
    super.key,
    required this.service,
    required this.startAutoRefresh,
    required this.fetchOnStartup,
    this.signedInUser,
    this.onLogout,
  });

  final TailscaleService service;
  final bool startAutoRefresh;
  final bool fetchOnStartup;
  final AppUser? signedInUser;
  final VoidCallback? onLogout;

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
  static const List<_RemoteCommandPreset>
  _remoteCommandPresetCatalog = <_RemoteCommandPreset>[
    _RemoteCommandPreset(
      id: 'custom',
      label: 'Custom command',
      description:
          'Type any command manually (shell, Python, Node, Docker, etc.).',
    ),
    _RemoteCommandPreset(
      id: 'system_probe',
      label: 'System probe',
      description:
          'Quick OS + runtime diagnostics (uname/version/python/node).',
    ),
    _RemoteCommandPreset(
      id: 'gpu_inventory',
      label: 'GPU inventory',
      description:
          'Checks NVIDIA/AMD GPU tooling and prints available GPU details.',
    ),
    _RemoteCommandPreset(
      id: 'gpu_quick_check',
      label: 'GPU quick check',
      description:
          'Fast compatibility check for CUDA toolchain and GPU visibility.',
    ),
    _RemoteCommandPreset(
      id: 'pytorch_cuda_check',
      label: 'PyTorch CUDA check',
      description: 'Verifies PyTorch, CUDA visibility, and visible GPU names.',
    ),
    _RemoteCommandPreset(
      id: 'ollama_health',
      label: 'Ollama health',
      description: 'Checks Ollama version and local Ollama API tags endpoint.',
    ),
    _RemoteCommandPreset(
      id: 'ollama_generate',
      label: 'Ollama test generate',
      description:
          'Runs a quick local generation test (model may auto-download).',
    ),
    _RemoteCommandPreset(
      id: 'ollama_chat_api',
      label: 'Ollama chat API',
      description:
          'Calls Ollama through its local OpenAI-compatible chat endpoint.',
    ),
    _RemoteCommandPreset(
      id: 'openai_api_smoke',
      label: 'OpenAI models list',
      description: 'Lists OpenAI models using OPENAI_API_KEY on target.',
    ),
    _RemoteCommandPreset(
      id: 'openai_chat_api',
      label: 'OpenAI chat test',
      description: 'Sends a short chat request using OPENAI_API_KEY on target.',
    ),
    _RemoteCommandPreset(
      id: 'openai_compat_local_chat',
      label: 'Local OpenAI-compatible chat',
      description:
          'Calls a local/self-hosted OpenAI-style endpoint such as Ollama or vLLM.',
    ),
    _RemoteCommandPreset(
      id: 'vllm_health',
      label: 'vLLM health',
      description:
          'Checks for vLLM plus a local OpenAI-compatible server on :8000.',
    ),
  ];
  static const List<_StreamCommandPreset>
  _streamCommandPresetCatalog = <_StreamCommandPreset>[
    _StreamCommandPreset(
      id: 'custom_stdin',
      label: 'Custom stdin command',
      description:
          'Use any command that reads from stdin: bash -s, python3 -, node -, pwsh -Command -, ruby -, and more.',
      posixCommand: '',
      windowsCommand: '',
    ),
    _StreamCommandPreset(
      id: 'python_stdin',
      label: 'Python (stdin)',
      description:
          'Streams local file into Python interpreter on target machine.',
      posixCommand: 'python3 -',
      windowsCommand: 'py -',
      supportsInteractiveInput: true,
    ),
    _StreamCommandPreset(
      id: 'bash_stdin',
      label: 'Bash (stdin)',
      description: 'Streams local file into bash shell (good for .sh scripts).',
      posixCommand: 'bash -s',
      windowsCommand: 'bash -s',
    ),
    _StreamCommandPreset(
      id: 'sh_stdin',
      label: 'POSIX sh (stdin)',
      description: 'Streams local file into /bin/sh-compatible shell.',
      posixCommand: 'sh -s',
      windowsCommand: 'sh -s',
    ),
    _StreamCommandPreset(
      id: 'node_stdin',
      label: 'Node.js (stdin)',
      description:
          'Streams local file directly into Node.js runtime on target.',
      posixCommand: 'node -',
      windowsCommand: 'node -',
    ),
    _StreamCommandPreset(
      id: 'ruby_stdin',
      label: 'Ruby (stdin)',
      description: 'Streams local file directly into the Ruby interpreter.',
      posixCommand: 'ruby -',
      windowsCommand: 'ruby -',
    ),
    _StreamCommandPreset(
      id: 'perl_stdin',
      label: 'Perl (stdin)',
      description: 'Streams local file directly into the Perl interpreter.',
      posixCommand: 'perl -',
      windowsCommand: 'perl -',
    ),
    _StreamCommandPreset(
      id: 'powershell_stdin',
      label: 'PowerShell (stdin)',
      description:
          'Streams local file into PowerShell (Windows: powershell, POSIX: pwsh).',
      posixCommand: 'pwsh -NoProfile -Command -',
      windowsCommand: 'powershell -NoProfile -Command -',
    ),
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
  final TextEditingController _remoteCommandController =
      TextEditingController();
  final TextEditingController _deviceSearchController = TextEditingController();
  int _multiRemoteRunSystemCounter = 0;
  int _multiRemoteRunFileCounter = 0;
  late final List<_RemoteMultiRunSystemGroup> _multiRemoteRunSystems =
      <_RemoteMultiRunSystemGroup>[_createMultiRemoteRunSystemGroup()];

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
  bool _runningParallelRemoteRuns = false;
  bool _generatingSshKey = false;
  bool _detectingRemoteUser = false;
  bool _rememberAuthKey = false;
  bool _autoConnectOnLaunch = false;
  bool _setupEnableTailscaleSsh = true;
  bool _hasStoredKey = false;
  bool _remoteStopRequested = false;
  bool _showRemoteAdvancedOptions = false;
  bool _showParallelRemoteRuns = false;
  String _selectedRemoteCommandPresetId = 'custom';
  _DashboardSection _activeSection = _DashboardSection.overview;
  String _deviceSearchQuery = '';

  String? _selectedRemoteDeviceDns;
  Map<String, RemoteDeviceProfile> _remoteProfilesByDns =
      <String, RemoteDeviceProfile>{};
  List<RemoteExecutionRecord> _remoteExecutionHistory =
      <RemoteExecutionRecord>[];
  Process? _activeRemoteSshProcess;

  Timer? _refreshTimer;

  bool get _isBusy => _loadingStatus || _runningAction;
  bool get _remoteExecutionBusy =>
      _runningRemoteCommand || _runningParallelRemoteRuns;
  bool get _remoteRunnerBusy =>
      _remoteExecutionBusy || _detectingRemoteUser || _generatingSshKey;

  _RemoteMultiRunFileEntry _createMultiRemoteRunFileEntry() {
    _multiRemoteRunFileCounter += 1;
    return _RemoteMultiRunFileEntry(id: 'file_$_multiRemoteRunFileCounter');
  }

  _RemoteMultiRunSystemGroup _createMultiRemoteRunSystemGroup() {
    _multiRemoteRunSystemCounter += 1;
    return _RemoteMultiRunSystemGroup(
      id: 'system_$_multiRemoteRunSystemCounter',
      jobs: <_RemoteMultiRunFileEntry>[_createMultiRemoteRunFileEntry()],
    );
  }

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

  String _bashEncodedCommand(String script) {
    final encoded = base64Encode(utf8.encode(script));
    return 'bash -lc "TMP=/tmp/scaleserve_ssh_doctor.sh && '
        'printf %s \'$encoded\' | '
        '(base64 --decode 2>/dev/null || base64 -d 2>/dev/null || base64 -D 2>/dev/null) > \\\$TMP && '
        'bash \\\$TMP; STATUS=\\\$?; rm -f \\\$TMP; exit \\\$STATUS"';
  }

  String _posixSshDoctorCommand() {
    if (_sshPublicKey.isEmpty) {
      return '';
    }

    const scriptTemplate = r'''
set -eu

say() {
  printf '%s\\n' "$1"
}

fail() {
  say 'ScaleServe POSIX SSH Doctor: FAILED'
  say "$1"
  exit 1
}

KEY_B64='__SCALESERVE_KEY_B64__'
KEY="$(printf %s "$KEY_B64" | (base64 --decode 2>/dev/null || base64 -d 2>/dev/null || base64 -D 2>/dev/null || echo ''))"

if [ -z "$KEY" ]; then
  fail 'SSH key payload is empty.'
fi

OS="$(uname -s 2>/dev/null || echo unknown)"
TARGET_USER="$(id -un 2>/dev/null || echo user)"
TARGET_HOME="${HOME:-}"

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  TARGET_USER="$SUDO_USER"
  TARGET_HOME="$(eval echo "~$SUDO_USER" 2>/dev/null || echo "$HOME")"
fi

if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
  fail "Unable to determine home directory for $TARGET_USER."
fi

USER_SSH_DIR="$TARGET_HOME/.ssh"
USER_AUTH="$USER_SSH_DIR/authorized_keys"

mkdir -p "$USER_SSH_DIR"
chmod 700 "$USER_SSH_DIR"
touch "$USER_AUTH"
chmod 600 "$USER_AUTH"
grep -qxF "$KEY" "$USER_AUTH" || printf '%s\\n' "$KEY" >> "$USER_AUTH"

if [ "$(id -u)" -eq 0 ]; then
  chown "$TARGET_USER" "$USER_SSH_DIR" "$USER_AUTH" >/dev/null 2>&1 || true
fi

if grep -qxF "$KEY" "$USER_AUTH"; then
  KEY_OK=yes
else
  KEY_OK=no
fi

if [ "$KEY_OK" != "yes" ]; then
  fail "Key was not persisted in $USER_AUTH"
fi

if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
elif command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
else
  SUDO=""
fi

ensure_openssh_linux() {
  if command -v sshd >/dev/null 2>&1; then
    return 0
  fi

  if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
    return 1
  fi

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -y >/dev/null 2>&1 || true
    $SUDO apt-get install -y openssh-server >/dev/null 2>&1 || true
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y openssh-server >/dev/null 2>&1 || true
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y openssh-server >/dev/null 2>&1 || true
  elif command -v zypper >/dev/null 2>&1; then
    $SUDO zypper --non-interactive install openssh >/dev/null 2>&1 || true
  elif command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -Sy --noconfirm openssh >/dev/null 2>&1 || true
  fi

  command -v sshd >/dev/null 2>&1
}

SERVICE_STARTED=no
SERVICE_NAME=unknown

if [ "$OS" = "Darwin" ]; then
  if command -v systemsetup >/dev/null 2>&1; then
    $SUDO systemsetup -setremotelogin on >/dev/null 2>&1 || true
  fi
  if command -v launchctl >/dev/null 2>&1; then
    $SUDO launchctl enable system/com.openssh.sshd >/dev/null 2>&1 || true
    $SUDO launchctl kickstart -k system/com.openssh.sshd >/dev/null 2>&1 || true
    $SUDO launchctl load -w /System/Library/LaunchDaemons/ssh.plist >/dev/null 2>&1 || true
  fi
  SERVICE_NAME=sshd
else
  ensure_openssh_linux >/dev/null 2>&1 || true

  if command -v systemctl >/dev/null 2>&1; then
    for svc in ssh sshd; do
      $SUDO systemctl enable "$svc" >/dev/null 2>&1 || true
      $SUDO systemctl start "$svc" >/dev/null 2>&1 || true
      $SUDO systemctl restart "$svc" >/dev/null 2>&1 || true
      if $SUDO systemctl is-active "$svc" >/dev/null 2>&1; then
        SERVICE_STARTED=yes
        SERVICE_NAME="$svc"
        break
      fi
    done
  elif command -v service >/dev/null 2>&1; then
    for svc in ssh sshd; do
      $SUDO service "$svc" start >/dev/null 2>&1 || true
      if $SUDO service "$svc" status >/dev/null 2>&1; then
        SERVICE_STARTED=yes
        SERVICE_NAME="$svc"
        break
      fi
    done
  elif command -v rc-service >/dev/null 2>&1; then
    for svc in sshd ssh; do
      $SUDO rc-service "$svc" start >/dev/null 2>&1 || true
      if $SUDO rc-service "$svc" status >/dev/null 2>&1; then
        SERVICE_STARTED=yes
        SERVICE_NAME="$svc"
        break
      fi
    done
  fi
fi

if [ "$OS" = "Darwin" ]; then
  if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:22 -sTCP:LISTEN >/dev/null 2>&1; then
    SERVICE_STARTED=yes
  fi
fi

if command -v ufw >/dev/null 2>&1; then
  $SUDO ufw allow 22/tcp >/dev/null 2>&1 || true
fi
if command -v firewall-cmd >/dev/null 2>&1; then
  $SUDO firewall-cmd --add-service=ssh --permanent >/dev/null 2>&1 || true
  $SUDO firewall-cmd --add-service=ssh >/dev/null 2>&1 || true
fi

if command -v sshd >/dev/null 2>&1; then
  sshd -t >/dev/null 2>&1 || true
fi

PORT_OK=no
if command -v ss >/dev/null 2>&1; then
  ss -lnt 2>/dev/null | grep -Eq '(^|[[:space:]])(0\\.0\\.0\\.0|::|\\*):22[[:space:]]' && PORT_OK=yes || true
elif command -v lsof >/dev/null 2>&1; then
  lsof -nP -iTCP:22 -sTCP:LISTEN >/dev/null 2>&1 && PORT_OK=yes || true
elif command -v netstat >/dev/null 2>&1; then
  netstat -an 2>/dev/null | grep -E 'LISTEN|LISTENING' | grep -Eq '[:.]22[[:space:]]' && PORT_OK=yes || true
fi

if [ "$PORT_OK" != "yes" ]; then
  fail 'Port 22 is not listening. Re-run once with admin/root privileges and verify OpenSSH server is installed and enabled.'
fi

say 'ScaleServe POSIX SSH Doctor: SUCCESS'
say "OS: $OS"
say "target user: $TARGET_USER"
say "authorized_keys: $USER_AUTH (key present=$KEY_OK)"
say "ssh service candidate: $SERVICE_NAME (started=$SERVICE_STARTED)"
say "port 22 listening: $PORT_OK"
say 'Next: from your controller run: ssh -i <key_path> <user>@<tailscale_dns> "echo scaleserve-ssh-ok"'
''';

    final keyB64 = base64Encode(utf8.encode(_sshPublicKey.trim()));
    final script = scriptTemplate.replaceAll('__SCALESERVE_KEY_B64__', keyB64);
    return _bashEncodedCommand(script);
  }

  String _powershellEncodedCommand(String script) {
    final bytes = <int>[];
    for (final codeUnit in script.codeUnits) {
      bytes.add(codeUnit & 0xFF);
      bytes.add((codeUnit >> 8) & 0xFF);
    }
    final encoded = base64Encode(bytes);
    return 'powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded';
  }

  String _windowsAuthorizedKeySetupCommand() {
    if (_sshPublicKey.isEmpty) {
      return '';
    }

    const scriptTemplate = r'''
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$key = @'
__SCALESERVE_KEY__
'@.Trim()

if ([string]::IsNullOrWhiteSpace($key)) {
  throw 'ScaleServe SSH key is empty.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Write-UniqueLine([string]$Path, [string]$Line) {
  $dir = Split-Path -Path $Path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  $lines = @()
  if (Test-Path -LiteralPath $Path) {
    $lines = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -ne '' }
  }

  if ($lines -notcontains $Line) {
    $lines += $Line
  }

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines($Path, $lines, $utf8NoBom)
}

function Ensure-OpenSshServer {
  $cap = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
  if ($null -eq $cap) {
    throw 'OpenSSH.Server capability not found.'
  }

  if ($cap.State -ne 'Installed') {
    if (-not $isAdmin) {
      throw 'OpenSSH.Server is not installed. Re-run as Administrator to install it.'
    }
    Add-WindowsCapability -Online -Name $cap.Name | Out-Null
  }

  if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
    throw 'sshd service is unavailable after OpenSSH install.'
  }
}

function Set-GlobalSshdDirective([string]$Name, [string]$Value) {
  if (-not $isAdmin) {
    return
  }

  $configPath = Join-Path $env:ProgramData 'ssh\sshd_config'
  if (-not (Test-Path -LiteralPath $configPath)) {
    throw "sshd_config not found at $configPath"
  }

  $lines = Get-Content -LiteralPath $configPath -ErrorAction Stop
  $firstMatchIndex = $lines.Count
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*Match\s+') {
      $firstMatchIndex = $i
      break
    }
  }

  $directiveRegex = '^\s*#?\s*' + [regex]::Escape($Name) + '\s+'
  $updated = $false
  for ($i = 0; $i -lt $firstMatchIndex; $i++) {
    if ($lines[$i] -match $directiveRegex) {
      $lines[$i] = "$Name $Value"
      $updated = $true
      break
    }
  }

  if (-not $updated) {
    if ($firstMatchIndex -lt 0 -or $firstMatchIndex -gt $lines.Count) {
      $firstMatchIndex = $lines.Count
    }
    $head = @()
    $tail = @()
    if ($firstMatchIndex -gt 0) { $head = $lines[0..($firstMatchIndex - 1)] }
    if ($firstMatchIndex -lt $lines.Count) { $tail = $lines[$firstMatchIndex..($lines.Count - 1)] }
    $lines = @($head + @("$Name $Value") + $tail)
  }

  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines($configPath, $lines, $utf8NoBom)
}

function Ensure-FirewallRule {
  if (-not $isAdmin) {
    return
  }

  if (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue) {
    Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' | Out-Null
  } else {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
  }
}

Ensure-OpenSshServer
Ensure-FirewallRule
Set-GlobalSshdDirective -Name 'PubkeyAuthentication' -Value 'yes'

if ($isAdmin) {
  Set-Service -Name sshd -StartupType Automatic
  Start-Service -Name sshd
}

$userAuth = Join-Path (Join-Path $env:USERPROFILE '.ssh') 'authorized_keys'
Write-UniqueLine -Path $userAuth -Line $key
& icacls (Split-Path $userAuth) /inheritance:r /grant:r ($env:USERNAME + ':(OI)(CI)F') /grant:r 'SYSTEM:(OI)(CI)F' | Out-Null
& icacls $userAuth /inheritance:r /grant:r ($env:USERNAME + ':F') /grant:r 'SYSTEM:F' | Out-Null

$adminAuth = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
if ($isAdmin) {
  Write-UniqueLine -Path $adminAuth -Line $key
  & icacls $adminAuth /inheritance:r /grant:r 'Administrators:F' /grant:r 'SYSTEM:F' | Out-Null
}

try {
  Restart-Service -Name sshd -Force -ErrorAction Stop
} catch {
  $service = Get-Service -Name sshd -ErrorAction SilentlyContinue
  if ($null -eq $service -or $service.Status -ne 'Running') {
    throw
  }
}

$service = Get-Service -Name sshd
if ($service.Status -ne 'Running') {
  throw 'sshd service is not running.'
}

$portCheck = Test-NetConnection -ComputerName '127.0.0.1' -Port 22 -WarningAction SilentlyContinue
if (-not $portCheck.TcpTestSucceeded) {
  throw 'TCP port 22 is not reachable on localhost.'
}

$userKeyPresent = Select-String -Path $userAuth -SimpleMatch $key -Quiet
if (-not $userKeyPresent) {
  throw "Key was not persisted in $userAuth"
}

$adminKeyPresent = $false
if (Test-Path -LiteralPath $adminAuth) {
  $adminKeyPresent = Select-String -Path $adminAuth -SimpleMatch $key -Quiet
}

Write-Host 'ScaleServe Windows SSH Doctor: SUCCESS'
Write-Host ('sshd status: ' + $service.Status)
Write-Host ('Local port 22 check: ' + $portCheck.TcpTestSucceeded)
Write-Host ('User authorized_keys: ' + $userAuth + ' (key present=' + $userKeyPresent + ')')
if ($isAdmin) {
  Write-Host ('Admin authorized_keys: ' + $adminAuth + ' (key present=' + $adminKeyPresent + ')')
}
Write-Host 'Next: from your controller run: ssh -i <key_path> <user>@<tailscale_dns> \"echo scaleserve-ssh-ok\"'
''';

    final script = scriptTemplate.replaceAll(
      '__SCALESERVE_KEY__',
      _sshPublicKey.trim(),
    );
    return _powershellEncodedCommand(script);
  }

  bool _isWindowsPeer(TailscalePeer? peer) {
    return (peer?.os ?? '').toLowerCase().contains('windows');
  }

  bool _isMacPeer(TailscalePeer? peer) {
    final os = (peer?.os ?? '').toLowerCase();
    return os.contains('mac') || os.contains('darwin') || os.contains('osx');
  }

  bool _isLinuxPeer(TailscalePeer? peer) {
    final os = (peer?.os ?? '').toLowerCase();
    return os.contains('linux') ||
        os.contains('ubuntu') ||
        os.contains('debian') ||
        os.contains('fedora') ||
        os.contains('centos') ||
        os.contains('arch');
  }

  String _targetSshSetupCommandForPeer(TailscalePeer? peer) {
    if (_isWindowsPeer(peer)) {
      return _windowsAuthorizedKeySetupCommand();
    }
    return _posixSshDoctorCommand();
  }

  String _targetSshDoctorButtonLabel(TailscalePeer? peer) {
    if (_isWindowsPeer(peer)) {
      return 'Copy Windows SSH Doctor Command';
    }
    if (_isMacPeer(peer)) {
      return 'Copy macOS SSH Doctor Command';
    }
    if (_isLinuxPeer(peer)) {
      return 'Copy Linux SSH Doctor Command';
    }
    return 'Copy SSH Doctor Command';
  }

  String _targetSshDoctorCopiedMessage(TailscalePeer? peer) {
    if (_isWindowsPeer(peer)) {
      return 'Copied Windows SSH Doctor + key setup command.';
    }
    if (_isMacPeer(peer)) {
      return 'Copied macOS SSH Doctor + key setup command.';
    }
    if (_isLinuxPeer(peer)) {
      return 'Copied Linux SSH Doctor + key setup command.';
    }
    return 'Copied SSH Doctor + key setup command.';
  }

  String _targetSshDoctorQuickSetupHint(TailscalePeer? peer) {
    if (_isWindowsPeer(peer)) {
      return 'run it once as Administrator on the target.';
    }
    if (_isMacPeer(peer)) {
      return 'run it once on the target in Terminal (use sudo when prompted).';
    }
    if (_isLinuxPeer(peer)) {
      return 'run it once on the target (use sudo/root if needed).';
    }
    return 'run it once on the target.';
  }

  String _targetSshDoctorTip(TailscalePeer? peer) {
    if (_isWindowsPeer(peer)) {
      return 'Tip: On Windows targets, run the Windows SSH Doctor command once with admin rights to auto-fix OpenSSH service, firewall, config, and key placement.';
    }
    if (_isMacPeer(peer)) {
      return 'Tip: On macOS targets, run the macOS SSH Doctor command once to validate authorized_keys, enable Remote Login, and check port 22.';
    }
    if (_isLinuxPeer(peer)) {
      return 'Tip: On Linux/Ubuntu targets, run the Linux SSH Doctor command once to validate key placement, start sshd, and check port 22.';
    }
    return 'Tip: Run the SSH Doctor command once on the target to validate key placement and SSH service health.';
  }

  String _targetOsLabel(TailscalePeer? peer) {
    if (_isWindowsPeer(peer)) {
      return 'Windows';
    }
    if (_isMacPeer(peer)) {
      return 'macOS';
    }
    if (_isLinuxPeer(peer)) {
      return 'Linux';
    }
    return 'target';
  }

  _RemoteCommandPreset _remoteCommandPresetById(String id) {
    for (final preset in _remoteCommandPresetCatalog) {
      if (preset.id == id) {
        return preset;
      }
    }
    return _remoteCommandPresetCatalog.first;
  }

  _StreamCommandPreset _streamCommandPresetById(String id) {
    for (final preset in _streamCommandPresetCatalog) {
      if (preset.id == id) {
        return preset;
      }
    }
    return _streamCommandPresetCatalog.first;
  }

  String _remoteCommandForPreset({
    required String presetId,
    required TailscalePeer? peer,
  }) {
    final windows = _isWindowsPeer(peer);
    switch (presetId) {
      case 'system_probe':
        if (windows) {
          return r'powershell -NoProfile -NonInteractive -Command "Get-CimInstance Win32_OperatingSystem | Select-Object Caption,Version,OSArchitecture; if (Get-Command py -ErrorAction SilentlyContinue) { py --version }; if (Get-Command python -ErrorAction SilentlyContinue) { python --version }; if (Get-Command node -ErrorAction SilentlyContinue) { node --version }; if (Get-Command docker -ErrorAction SilentlyContinue) { docker --version }"';
        }
        return "bash -lc 'uname -a; (python3 --version || python --version || true); (node --version || true); (docker --version || true)'";
      case 'gpu_inventory':
        if (windows) {
          return r'powershell -NoProfile -NonInteractive -Command "if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { nvidia-smi } elseif (Get-Command rocm-smi -ErrorAction SilentlyContinue) { rocm-smi } else { Get-CimInstance Win32_VideoController | Select-Object Name,DriverVersion,AdapterRAM | Format-Table -AutoSize }"';
        }
        return "bash -lc 'if command -v nvidia-smi >/dev/null 2>&1; then nvidia-smi; elif command -v rocm-smi >/dev/null 2>&1; then rocm-smi; elif [ \"\$(uname -s)\" = \"Darwin\" ]; then system_profiler SPDisplaysDataType; else (lspci 2>/dev/null | grep -Ei \"vga|3d|display|nvidia|amd\") || echo \"No GPU tool found\"; fi'";
      case 'gpu_quick_check':
        if (windows) {
          return r'powershell -NoProfile -NonInteractive -Command "if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader } else { Write-Host '
              'nvidia-smi not found'
              ' }; if (Get-Command nvcc -ErrorAction SilentlyContinue) { nvcc --version } else { Write-Host '
              'nvcc not found'
              ' }"';
        }
        return "bash -lc '(command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader) || echo \"nvidia-smi not found\"; (command -v nvcc >/dev/null 2>&1 && nvcc --version) || echo \"nvcc not found\"'";
      case 'pytorch_cuda_check':
        if (windows) {
          return r"""powershell -NoProfile -NonInteractive -Command "$cmd = 'import torch; print(\"torch\", torch.__version__); print(\"cuda available:\", torch.cuda.is_available()); print(\"device count:\", torch.cuda.device_count()); [print(f\"gpu {i}: {torch.cuda.get_device_name(i)}\") for i in range(torch.cuda.device_count())]'; if (Get-Command py -ErrorAction SilentlyContinue) { py -c $cmd } elseif (Get-Command python -ErrorAction SilentlyContinue) { python -c $cmd } else { Write-Host 'Python not found'; exit 1 }" """;
        }
        return "bash -lc '(python3 -c \"import torch; print(\\\"torch\\\", torch.__version__); print(\\\"cuda available:\\\", torch.cuda.is_available()); print(\\\"device count:\\\", torch.cuda.device_count()); [print(f\\\"gpu {i}: {torch.cuda.get_device_name(i)}\\\") for i in range(torch.cuda.device_count())]\" 2>/dev/null || python -c \"import torch; print(\\\"torch\\\", torch.__version__); print(\\\"cuda available:\\\", torch.cuda.is_available()); print(\\\"device count:\\\", torch.cuda.device_count()); [print(f\\\"gpu {i}: {torch.cuda.get_device_name(i)}\\\") for i in range(torch.cuda.device_count())]\" 2>/dev/null) || echo \"PyTorch not installed or CUDA not available\"'";
      case 'ollama_health':
        if (windows) {
          return r'powershell -NoProfile -NonInteractive -Command "ollama --version; try { (Invoke-RestMethod -Uri http://127.0.0.1:11434/api/tags -Method Get | ConvertTo-Json -Depth 6) } catch { Write-Host $_.Exception.Message; exit 1 }"';
        }
        return "bash -lc 'ollama --version && curl -sS http://127.0.0.1:11434/api/tags || echo \"Ollama API unavailable on :11434\"'";
      case 'ollama_generate':
        return 'ollama run llama3.2:3b "Say hello from ScaleServe and include GPU status if available."';
      case 'ollama_chat_api':
        if (windows) {
          return r"""powershell -NoProfile -NonInteractive -Command "$model = if ($env:OLLAMA_MODEL) { $env:OLLAMA_MODEL } else { 'llama3.2:3b' }; $body = @{ model = $model; messages = @(@{ role = 'user'; content = 'Say hello from ScaleServe and mention whether GPU acceleration is visible.' }); stream = $false } | ConvertTo-Json -Depth 6; Invoke-RestMethod -Method Post -Uri http://127.0.0.1:11434/v1/chat/completions -ContentType 'application/json' -Body $body | ConvertTo-Json -Depth 6" """;
        }
        return "bash -lc 'model=\"\${OLLAMA_MODEL:-llama3.2:3b}\"; curl -sS http://127.0.0.1:11434/v1/chat/completions -H \"Content-Type: application/json\" -d \"{\\\"model\\\":\\\"\$model\\\",\\\"messages\\\":[{\\\"role\\\":\\\"user\\\",\\\"content\\\":\\\"Say hello from ScaleServe and mention whether GPU acceleration is visible.\\\"}],\\\"stream\\\":false}\"'";
      case 'openai_api_smoke':
        if (windows) {
          return "powershell -NoProfile -NonInteractive -Command \"\$k=\$env:OPENAI_API_KEY; if (-not \$k) { Write-Host \\\"Set OPENAI_API_KEY first\\\"; exit 1 }; \$h=@{Authorization=(\\\"Bearer \\\" + \$k)}; Invoke-RestMethod -Method Get -Uri https://api.openai.com/v1/models -Headers \$h | ConvertTo-Json -Depth 4\"";
        }
        return "bash -lc 'if [ -z \"\$OPENAI_API_KEY\" ]; then echo \"Set OPENAI_API_KEY first\"; exit 1; fi; curl -sS https://api.openai.com/v1/models -H \"Authorization: Bearer \$OPENAI_API_KEY\" | head -c 1200'";
      case 'openai_chat_api':
        if (windows) {
          return r"""powershell -NoProfile -NonInteractive -Command "$k = $env:OPENAI_API_KEY; if (-not $k) { Write-Host 'Set OPENAI_API_KEY first'; exit 1 }; $model = if ($env:OPENAI_MODEL) { $env:OPENAI_MODEL } else { 'gpt-4o-mini' }; $headers = @{ Authorization = ('Bearer ' + $k); 'Content-Type' = 'application/json' }; $body = @{ model = $model; messages = @(@{ role = 'user'; content = 'Reply with a short hello from ScaleServe and mention the hostname if available.' }); max_tokens = 80 } | ConvertTo-Json -Depth 6; Invoke-RestMethod -Method Post -Uri https://api.openai.com/v1/chat/completions -Headers $headers -Body $body | ConvertTo-Json -Depth 6" """;
        }
        return "bash -lc 'model=\"\${OPENAI_MODEL:-gpt-4o-mini}\"; if [ -z \"\$OPENAI_API_KEY\" ]; then echo \"Set OPENAI_API_KEY first\"; exit 1; fi; curl -sS https://api.openai.com/v1/chat/completions -H \"Authorization: Bearer \$OPENAI_API_KEY\" -H \"Content-Type: application/json\" -d \"{\\\"model\\\":\\\"\$model\\\",\\\"messages\\\":[{\\\"role\\\":\\\"user\\\",\\\"content\\\":\\\"Reply with a short hello from ScaleServe and mention the hostname if available.\\\"}],\\\"max_tokens\\\":80}\" | head -c 2000'";
      case 'openai_compat_local_chat':
        if (windows) {
          return r"""powershell -NoProfile -NonInteractive -Command "$base = if ($env:OPENAI_BASE_URL) { $env:OPENAI_BASE_URL } else { 'http://127.0.0.1:11434/v1' }; $model = if ($env:OPENAI_COMPAT_MODEL) { $env:OPENAI_COMPAT_MODEL } else { 'llama3.2:3b' }; $key = if ($env:OPENAI_COMPAT_API_KEY) { $env:OPENAI_COMPAT_API_KEY } else { 'ollama' }; $headers = @{ Authorization = ('Bearer ' + $key); 'Content-Type' = 'application/json' }; $body = @{ model = $model; messages = @(@{ role = 'user'; content = 'Say hello from ScaleServe via an OpenAI-compatible endpoint.' }); stream = $false } | ConvertTo-Json -Depth 6; Invoke-RestMethod -Method Post -Uri ($base + '/chat/completions') -Headers $headers -Body $body | ConvertTo-Json -Depth 6" """;
        }
        return "bash -lc 'base=\"\${OPENAI_BASE_URL:-http://127.0.0.1:11434/v1}\"; model=\"\${OPENAI_COMPAT_MODEL:-llama3.2:3b}\"; key=\"\${OPENAI_COMPAT_API_KEY:-ollama}\"; curl -sS \"\$base/chat/completions\" -H \"Authorization: Bearer \$key\" -H \"Content-Type: application/json\" -d \"{\\\"model\\\":\\\"\$model\\\",\\\"messages\\\":[{\\\"role\\\":\\\"user\\\",\\\"content\\\":\\\"Say hello from ScaleServe via an OpenAI-compatible endpoint.\\\"}],\\\"stream\\\":false}\" | head -c 2000'";
      case 'vllm_health':
        if (windows) {
          return r"""powershell -NoProfile -NonInteractive -Command "if (Get-Command py -ErrorAction SilentlyContinue) { py -m vllm.entrypoints.openai.api_server --help *> $null; if ($LASTEXITCODE -eq 0) { Write-Host 'vLLM Python package detected' } else { Write-Host 'vLLM Python package not detected' } } elseif (Get-Command python -ErrorAction SilentlyContinue) { python -m vllm.entrypoints.openai.api_server --help *> $null; if ($LASTEXITCODE -eq 0) { Write-Host 'vLLM Python package detected' } else { Write-Host 'vLLM Python package not detected' } } else { Write-Host 'Python not found' }; try { Invoke-RestMethod -Method Get -Uri http://127.0.0.1:8000/v1/models | ConvertTo-Json -Depth 6 } catch { Write-Host 'OpenAI-compatible server not reachable on :8000' }" """;
        }
        return "bash -lc '(python3 -m vllm.entrypoints.openai.api_server --help >/dev/null 2>&1 && echo \"vLLM Python package detected\") || echo \"vLLM Python package not detected\"; curl -sS http://127.0.0.1:8000/v1/models || echo \"OpenAI-compatible server not reachable on :8000\"'";
      case 'custom':
      default:
        return '';
    }
  }

  String _streamCommandForPreset({
    required String presetId,
    required TailscalePeer? peer,
  }) {
    final preset = _streamCommandPresetById(presetId);
    return _isWindowsPeer(peer) ? preset.windowsCommand : preset.posixCommand;
  }

  RemoteDeviceProfile? _remoteProfileForDns(String dnsName) {
    final normalized = dnsName.trim();
    if (normalized.isEmpty) {
      return null;
    }
    return _remoteProfilesByDns[normalized] ??
        (normalized.endsWith('.')
            ? _remoteProfilesByDns[normalized.substring(
                0,
                normalized.length - 1,
              )]
            : _remoteProfilesByDns['$normalized.']);
  }

  String _multiRemoteRunSystemLabel(_RemoteMultiRunSystemGroup systemGroup) {
    final index = _multiRemoteRunSystems.indexWhere(
      (item) => identical(item, systemGroup),
    );
    if (index == -1) {
      return 'System';
    }
    return 'System ${index + 1}';
  }

  String _multiRemoteRunFileLabel(
    _RemoteMultiRunSystemGroup systemGroup,
    _RemoteMultiRunFileEntry fileEntry,
  ) {
    final index = systemGroup.jobs.indexWhere(
      (item) => identical(item, fileEntry),
    );
    if (index == -1) {
      return 'File';
    }
    return 'File ${index + 1}';
  }

  String _effectiveMultiRemoteRunCommand(
    _RemoteMultiRunSystemGroup systemGroup,
    _RemoteMultiRunFileEntry fileEntry,
  ) {
    final overrideCommand = fileEntry.remoteCommandController.text.trim();
    if (overrideCommand.isNotEmpty) {
      return overrideCommand;
    }
    final peer = _peerByDnsName(systemGroup.selectedDeviceDns ?? '');
    return _streamCommandForPreset(
      presetId: fileEntry.selectedStreamPresetId,
      peer: peer,
    );
  }

  void _applyMultiRemoteRunStreamPreset({
    required _RemoteMultiRunSystemGroup systemGroup,
    required _RemoteMultiRunFileEntry fileEntry,
    required bool showMessage,
  }) {
    final peer = _peerByDnsName(systemGroup.selectedDeviceDns ?? '');
    final preset = _streamCommandPresetById(fileEntry.selectedStreamPresetId);
    if (preset.id == 'custom_stdin') {
      if (!showMessage) {
        return;
      }
      setState(() {
        _infoMessage =
            'Custom stdin mode selected. Enter any command that reads stdin for ${_targetOsLabel(peer)}.';
      });
      return;
    }
    final command = _streamCommandForPreset(presetId: preset.id, peer: peer);
    setState(() {
      fileEntry.remoteCommandController.text = command;
      if (!preset.supportsInteractiveInput) {
        fileEntry.enableInteractiveInputForPythonStreamRuns = false;
      }
      if (showMessage) {
        _infoMessage =
            'Applied stream preset "${preset.label}" for ${_targetOsLabel(peer)}.';
      }
    });
  }

  String _buildSafeRemoteStreamCommand({
    required String keyPath,
    required String target,
    required String displayCommand,
    required String localFilePath,
  }) {
    final safeCommand = StringBuffer('ssh ');
    if (keyPath.isNotEmpty) {
      safeCommand.write('-i $keyPath -o IdentitiesOnly=yes ');
    }
    safeCommand.write(
      '-o BatchMode=yes -o NumberOfPasswordPrompts=0 '
      '-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new ',
    );
    safeCommand.write('$target "$displayCommand" < "$localFilePath"');
    return safeCommand.toString();
  }

  void _addMultiRemoteRunSystem() {
    if (_remoteRunnerBusy) {
      return;
    }
    setState(() {
      _showParallelRemoteRuns = true;
      _multiRemoteRunSystems.add(_createMultiRemoteRunSystemGroup());
      _infoMessage =
          'Added another remote system block for multi-target execution.';
    });
  }

  void _removeMultiRemoteRunSystem(_RemoteMultiRunSystemGroup systemGroup) {
    if (_remoteRunnerBusy || _multiRemoteRunSystems.length <= 1) {
      return;
    }
    final systemLabel = _multiRemoteRunSystemLabel(systemGroup);
    setState(() {
      _multiRemoteRunSystems.remove(systemGroup);
      systemGroup.dispose();
      _infoMessage = 'Removed $systemLabel.';
    });
  }

  void _setMultiRemoteRunFileCount(
    _RemoteMultiRunSystemGroup systemGroup,
    int count,
  ) {
    if (_remoteRunnerBusy) {
      return;
    }
    if (count < 1) {
      return;
    }

    setState(() {
      while (systemGroup.jobs.length < count) {
        systemGroup.jobs.add(_createMultiRemoteRunFileEntry());
      }
      while (systemGroup.jobs.length > count) {
        final removed = systemGroup.jobs.removeLast();
        removed.activeProcess?.kill();
        removed.dispose();
      }
      _showParallelRemoteRuns = true;
    });
  }

  Future<_RemoteMultiRunJobRequest> _prepareRemoteMultiRunJobRequest({
    required _RemoteMultiRunSystemGroup systemGroup,
    required _RemoteMultiRunFileEntry fileEntry,
  }) async {
    final systemLabel = _multiRemoteRunSystemLabel(systemGroup);
    final fileLabel = _multiRemoteRunFileLabel(systemGroup, fileEntry);
    final dnsName = (systemGroup.selectedDeviceDns ?? '').trim();
    if (dnsName.isEmpty) {
      throw StateError('$systemLabel: select a target system.');
    }

    final peer = _peerByDnsName(dnsName);
    final profile = _remoteProfileForDns(dnsName);
    final fallbackUser = _defaultSshUserForPeer(peer);
    final user = (profile?.user.trim().isNotEmpty ?? false)
        ? profile!.user.trim()
        : fallbackUser;
    if (user.isEmpty || user == '<remote-user>') {
      throw StateError(
        '$systemLabel: save a device profile or enter a valid SSH user first.',
      );
    }

    final keyPath = (profile?.keyPath.trim().isNotEmpty ?? false)
        ? profile!.keyPath.trim()
        : _remoteKeyPathController.text.trim();
    final localFilePath = fileEntry.filePathController.text.trim();
    final file = File(localFilePath);
    if (!await file.exists()) {
      throw StateError('$systemLabel / $fileLabel: local file not found.');
    }

    final remoteCommand = _effectiveMultiRemoteRunCommand(
      systemGroup,
      fileEntry,
    );
    if (remoteCommand.isEmpty) {
      throw StateError(
        '$systemLabel / $fileLabel: enter a command to run (for example: bash -s, python3 -, node -, pwsh -Command -, ruby -).',
      );
    }
    if (fileEntry.enableInteractiveInputForPythonStreamRuns &&
        !_isPythonStdinCommand(remoteCommand)) {
      throw StateError(
        '$systemLabel / $fileLabel: interactive input only works with commands like "py -" or "python -".',
      );
    }

    final target = '$user@$dnsName';
    final safeCommand = _buildSafeRemoteStreamCommand(
      keyPath: keyPath,
      target: target,
      displayCommand: remoteCommand,
      localFilePath: localFilePath,
    );

    return _RemoteMultiRunJobRequest(
      systemGroup: systemGroup,
      fileEntry: fileEntry,
      dnsName: dnsName,
      user: user,
      keyPath: keyPath,
      localFilePath: localFilePath,
      remoteCommand: remoteCommand,
      safeCommand: safeCommand,
      isWindowsTarget: _isWindowsPeer(peer),
      windowsCleanupPattern: fileEntry.windowsCleanupPatternController.text
          .trim(),
      enableInteractiveInput:
          fileEntry.enableInteractiveInputForPythonStreamRuns,
      autoKillWindowsPythonAfterStreamRun:
          fileEntry.autoKillWindowsPythonAfterStreamRun,
    );
  }

  Future<void> _sendMultiRemoteRunInputLine(
    _RemoteMultiRunFileEntry fileEntry,
  ) async {
    final process = fileEntry.activeProcess;
    final input = fileEntry.runtimeInputController.text;
    if (process == null ||
        !fileEntry.isRunning ||
        !fileEntry.activeRunSupportsRuntimeInput) {
      if (!mounted) {
        return;
      }
      setState(() {
        _infoMessage = 'No active interactive multi-system remote run.';
      });
      return;
    }

    try {
      process.stdin.writeln(input);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _infoMessage = 'Could not send input to remote process: $error';
      });
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      fileEntry.runtimeInputController.clear();
      fileEntry.output += 'STDIN: $input\n';
      _infoMessage = 'Sent input to multi-system remote process.';
    });
  }

  Future<void> _sendMultiRemoteRunInputEof(
    _RemoteMultiRunFileEntry fileEntry,
  ) async {
    final process = fileEntry.activeProcess;
    if (process == null ||
        !fileEntry.isRunning ||
        !fileEntry.activeRunSupportsRuntimeInput) {
      if (!mounted) {
        return;
      }
      setState(() {
        _infoMessage = 'No active interactive multi-system remote run.';
      });
      return;
    }

    try {
      await process.stdin.close();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _infoMessage = 'Could not send EOF to remote process: $error';
      });
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      fileEntry.activeRunSupportsRuntimeInput = false;
      fileEntry.statusText = 'Running';
      _infoMessage = 'Sent EOF to multi-system remote process stdin.';
    });
  }

  Future<void> _stopMultiRemoteRunJob(
    _RemoteMultiRunFileEntry fileEntry,
  ) async {
    final process = fileEntry.activeProcess;
    if (process == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _infoMessage = 'No active remote run to stop for this file.';
      });
      return;
    }

    fileEntry.stopRequested = true;
    var killed = false;
    try {
      killed = process.kill(ProcessSignal.sigterm);
    } catch (_) {
      // Fall through to default kill below.
    }
    if (!killed) {
      try {
        killed = process.kill();
      } catch (_) {
        // Best effort only.
      }
    }

    if (!mounted) {
      return;
    }
    setState(() {
      fileEntry.activeRunSupportsRuntimeInput = false;
      fileEntry.output += '\n[Control] Stop requested by user.\n';
      fileEntry.statusText = 'Stopping';
      _infoMessage = killed
          ? 'Stop requested. Waiting for the file run to exit...'
          : 'Could not send stop signal to the file run.';
    });
  }

  Future<_RemoteMultiRunJobOutcome> _executeRemoteMultiRunJob(
    _RemoteMultiRunJobRequest request,
  ) async {
    final fileEntry = request.fileEntry;
    final systemLabel = _multiRemoteRunSystemLabel(request.systemGroup);
    final fileLabel = _multiRemoteRunFileLabel(request.systemGroup, fileEntry);
    final startedAt = DateTime.now().toUtc();
    final localFile = File(request.localFilePath);
    final localFileLength = await localFile.length();
    final interactivePythonStdinRun =
        request.enableInteractiveInput &&
        _isPythonStdinCommand(request.remoteCommand);

    final effectiveRemoteCommand = interactivePythonStdinRun
        ? _buildPythonInteractiveStreamCommand(
                remoteStdinCommand: request.remoteCommand,
                scriptByteLength: localFileLength,
              ) ??
              request.remoteCommand
        : request.remoteCommand;

    if (interactivePythonStdinRun &&
        effectiveRemoteCommand == request.remoteCommand) {
      throw StateError(
        '$systemLabel / $fileLabel: interactive stdin mode requires a command like "py -" or "python -".',
      );
    }

    final displayCommand = interactivePythonStdinRun
        ? '${request.remoteCommand} [interactive wrapper]'
        : effectiveRemoteCommand;
    final safeCommand = _buildSafeRemoteStreamCommand(
      keyPath: request.keyPath,
      target: '${request.user}@${request.dnsName}',
      displayCommand: displayCommand,
      localFilePath: request.localFilePath,
    );
    final commandLabel =
        'stream:${request.localFilePath} -> ${request.remoteCommand}';

    if (mounted) {
      setState(() {
        fileEntry.isRunning = true;
        fileEntry.stopRequested = false;
        fileEntry.activeRunSupportsRuntimeInput = false;
        fileEntry.runtimeInputController.clear();
        fileEntry.output =
            'Command: $safeCommand\n\n'
            'Starting $fileLabel on ${request.dnsName}...';
        fileEntry.statusText = 'Running';
      });
    } else {
      fileEntry.isRunning = true;
      fileEntry.stopRequested = false;
      fileEntry.activeRunSupportsRuntimeInput = false;
      fileEntry.runtimeInputController.clear();
      fileEntry.output =
          'Command: $safeCommand\n\n'
          'Starting $fileLabel on ${request.dnsName}...';
      fileEntry.statusText = 'Running';
    }

    Process? process;
    try {
      final target = '${request.user}@${request.dnsName}';
      final sshArgs = <String>[
        '-o',
        'BatchMode=yes',
        '-o',
        'NumberOfPasswordPrompts=0',
        '-o',
        'ConnectTimeout=8',
        '-o',
        'StrictHostKeyChecking=accept-new',
        if (request.keyPath.isNotEmpty) ...[
          '-i',
          request.keyPath,
          '-o',
          'IdentitiesOnly=yes',
        ],
        target,
        effectiveRemoteCommand,
      ];

      process = await Process.start('ssh', sshArgs, runInShell: false);
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();
      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();

      if (mounted) {
        setState(() {
          fileEntry.activeProcess = process;
          fileEntry.statusText = 'Streaming';
        });
      } else {
        fileEntry.activeProcess = process;
        fileEntry.statusText = 'Streaming';
      }

      process.stdout
          .transform(utf8.decoder)
          .listen(
            (chunk) {
              stdoutBuffer.write(chunk);
              if (mounted) {
                setState(() {
                  fileEntry.output += 'STDOUT: $chunk';
                });
              } else {
                fileEntry.output += 'STDOUT: $chunk';
              }
            },
            onDone: () => stdoutDone.complete(),
            onError: (_) => stdoutDone.complete(),
            cancelOnError: false,
          );

      process.stderr
          .transform(utf8.decoder)
          .listen(
            (chunk) {
              stderrBuffer.write(chunk);
              if (mounted) {
                setState(() {
                  fileEntry.output += 'STDERR: $chunk';
                });
              } else {
                fileEntry.output += 'STDERR: $chunk';
              }
            },
            onDone: () => stderrDone.complete(),
            onError: (_) => stderrDone.complete(),
            cancelOnError: false,
          );

      await process.stdin.addStream(localFile.openRead());
      if (interactivePythonStdinRun) {
        if (mounted) {
          setState(() {
            fileEntry.activeRunSupportsRuntimeInput = true;
            fileEntry.statusText = 'Waiting for input';
            _infoMessage =
                '$systemLabel / $fileLabel is waiting for runtime input.';
          });
        } else {
          fileEntry.activeRunSupportsRuntimeInput = true;
          fileEntry.statusText = 'Waiting for input';
        }
      } else {
        await process.stdin.close();
      }

      final exitCode = await process.exitCode;
      await Future.wait([stdoutDone.future, stderrDone.future]);
      if (interactivePythonStdinRun) {
        try {
          await process.stdin.close();
        } catch (_) {
          // Process may already be closed.
        }
      }

      final stdoutText = stdoutBuffer.toString().trim();
      final stderrText = stderrBuffer.toString().trim();
      final stoppedByUser = fileEntry.stopRequested;
      final finishedAt = DateTime.now().toUtc();

      final shouldAutoCleanup =
          request.isWindowsTarget &&
          request.autoKillWindowsPythonAfterStreamRun;
      final cleanupOutput = shouldAutoCleanup
          ? (request.windowsCleanupPattern.isNotEmpty
                ? await _cleanupWindowsPythonProcesses(
                    dnsName: request.dnsName,
                    user: request.user,
                    keyPath: request.keyPath,
                    commandLinePattern: request.windowsCleanupPattern,
                  )
                : 'Skipped auto-cleanup because cleanup pattern is empty.')
          : '';

      final summary = StringBuffer()
        ..writeln('Command: $safeCommand')
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
      if (cleanupOutput.isNotEmpty) {
        summary
          ..writeln('')
          ..writeln('AUTO-CLEANUP:')
          ..writeln(cleanupOutput);
      }

      final record = RemoteExecutionRecord(
        startedAtIso: startedAt.toIso8601String(),
        finishedAtIso: finishedAt.toIso8601String(),
        deviceDnsName: request.dnsName,
        user: request.user,
        command: commandLabel,
        exitCode: exitCode,
        success: exitCode == 0,
        stdout: stdoutText,
        stderr: stderrText,
        runType: 'stream_file',
        localFilePath: request.localFilePath,
        metadataJson: jsonEncode(<String, dynamic>{
          'safeCommand': safeCommand,
          'parallelRun': true,
          'systemId': request.systemGroup.id,
          'fileEntryId': fileEntry.id,
          'systemLabel': systemLabel,
          'fileLabel': fileLabel,
          'cleanupApplied': shouldAutoCleanup,
          'cleanupPattern': request.windowsCleanupPattern,
          'interactiveInput': interactivePythonStdinRun,
          'stoppedByUser': stoppedByUser,
        }),
      );

      if (mounted) {
        setState(() {
          fileEntry.output = summary.toString().trim();
          fileEntry.activeRunSupportsRuntimeInput = false;
          fileEntry.statusText = stoppedByUser
              ? 'Stopped'
              : (exitCode == 0 ? 'Completed' : 'Failed (exit $exitCode)');
          fileEntry.isRunning = false;
          fileEntry.activeProcess = null;
        });
      } else {
        fileEntry.output = summary.toString().trim();
        fileEntry.activeRunSupportsRuntimeInput = false;
        fileEntry.statusText = stoppedByUser
            ? 'Stopped'
            : (exitCode == 0 ? 'Completed' : 'Failed (exit $exitCode)');
        fileEntry.isRunning = false;
        fileEntry.activeProcess = null;
      }

      return _RemoteMultiRunJobOutcome(
        systemId: request.systemGroup.id,
        fileEntryId: fileEntry.id,
        record: record,
        summary: summary.toString().trim(),
        stoppedByUser: stoppedByUser,
      );
    } on ProcessException catch (error) {
      final finishedAt = DateTime.now().toUtc();
      final summary =
          'Command: $safeCommand\n'
          'ERROR: ${error.message}';
      final record = RemoteExecutionRecord(
        startedAtIso: startedAt.toIso8601String(),
        finishedAtIso: finishedAt.toIso8601String(),
        deviceDnsName: request.dnsName,
        user: request.user,
        command: commandLabel,
        exitCode: -1,
        success: false,
        stdout: '',
        stderr: error.message,
        runType: 'stream_file',
        localFilePath: request.localFilePath,
        metadataJson: jsonEncode(<String, dynamic>{
          'safeCommand': safeCommand,
          'parallelRun': true,
          'systemId': request.systemGroup.id,
          'fileEntryId': fileEntry.id,
          'systemLabel': systemLabel,
          'fileLabel': fileLabel,
          'interactiveInput': interactivePythonStdinRun,
          'stoppedByUser': fileEntry.stopRequested,
        }),
      );

      if (mounted) {
        setState(() {
          fileEntry.output = summary;
          fileEntry.activeRunSupportsRuntimeInput = false;
          fileEntry.statusText = 'Failed to start';
          fileEntry.isRunning = false;
          fileEntry.activeProcess = null;
        });
      } else {
        fileEntry.output = summary;
        fileEntry.activeRunSupportsRuntimeInput = false;
        fileEntry.statusText = 'Failed to start';
        fileEntry.isRunning = false;
        fileEntry.activeProcess = null;
      }

      return _RemoteMultiRunJobOutcome(
        systemId: request.systemGroup.id,
        fileEntryId: fileEntry.id,
        record: record,
        summary: summary,
        stoppedByUser: fileEntry.stopRequested,
      );
    } catch (error) {
      final finishedAt = DateTime.now().toUtc();
      final summary = 'Command: $safeCommand\nERROR: $error';
      final record = RemoteExecutionRecord(
        startedAtIso: startedAt.toIso8601String(),
        finishedAtIso: finishedAt.toIso8601String(),
        deviceDnsName: request.dnsName,
        user: request.user,
        command: commandLabel,
        exitCode: -1,
        success: false,
        stdout: '',
        stderr: error.toString(),
        runType: 'stream_file',
        localFilePath: request.localFilePath,
        metadataJson: jsonEncode(<String, dynamic>{
          'safeCommand': safeCommand,
          'parallelRun': true,
          'systemId': request.systemGroup.id,
          'fileEntryId': fileEntry.id,
          'systemLabel': systemLabel,
          'fileLabel': fileLabel,
          'interactiveInput': interactivePythonStdinRun,
          'stoppedByUser': fileEntry.stopRequested,
        }),
      );

      if (mounted) {
        setState(() {
          fileEntry.output = summary;
          fileEntry.activeRunSupportsRuntimeInput = false;
          fileEntry.statusText = 'Failed';
          fileEntry.isRunning = false;
          fileEntry.activeProcess = null;
        });
      } else {
        fileEntry.output = summary;
        fileEntry.activeRunSupportsRuntimeInput = false;
        fileEntry.statusText = 'Failed';
        fileEntry.isRunning = false;
        fileEntry.activeProcess = null;
      }

      return _RemoteMultiRunJobOutcome(
        systemId: request.systemGroup.id,
        fileEntryId: fileEntry.id,
        record: record,
        summary: summary,
        stoppedByUser: fileEntry.stopRequested,
      );
    } finally {
      if (mounted) {
        setState(() {
          if (identical(fileEntry.activeProcess, process)) {
            fileEntry.activeProcess = null;
          }
          fileEntry.activeRunSupportsRuntimeInput = false;
          fileEntry.isRunning = false;
        });
      } else {
        if (identical(fileEntry.activeProcess, process)) {
          fileEntry.activeProcess = null;
        }
        fileEntry.activeRunSupportsRuntimeInput = false;
        fileEntry.isRunning = false;
      }
    }
  }

  Future<void> _runMultiRemoteSystemJobs() async {
    if (_remoteRunnerBusy) {
      return;
    }

    final validationErrors = <String>[];
    final requests = <_RemoteMultiRunJobRequest>[];

    for (final systemGroup in _multiRemoteRunSystems) {
      final systemLabel = _multiRemoteRunSystemLabel(systemGroup);
      final dnsName = (systemGroup.selectedDeviceDns ?? '').trim();
      if (dnsName.isEmpty) {
        validationErrors.add('$systemLabel: select a target system.');
        continue;
      }

      for (final fileEntry in systemGroup.jobs) {
        final fileLabel = _multiRemoteRunFileLabel(systemGroup, fileEntry);
        if (fileEntry.filePathController.text.trim().isEmpty) {
          validationErrors.add(
            '$systemLabel / $fileLabel: enter a local file path.',
          );
          continue;
        }
        try {
          requests.add(
            await _prepareRemoteMultiRunJobRequest(
              systemGroup: systemGroup,
              fileEntry: fileEntry,
            ),
          );
        } catch (error) {
          validationErrors.add(
            error.toString().replaceFirst('Bad state: ', ''),
          );
        }
      }
    }

    if (validationErrors.isNotEmpty) {
      setState(() {
        _showParallelRemoteRuns = true;
        _infoMessage = validationErrors.join('\n');
      });
      return;
    }

    if (requests.isEmpty) {
      setState(() {
        _showParallelRemoteRuns = true;
        _infoMessage = 'Add at least one remote file run before starting.';
      });
      return;
    }

    setState(() {
      _showParallelRemoteRuns = true;
      _runningParallelRemoteRuns = true;
      for (final systemGroup in _multiRemoteRunSystems) {
        for (final fileEntry in systemGroup.jobs) {
          fileEntry.stopRequested = false;
          fileEntry.activeProcess = null;
          fileEntry.activeRunSupportsRuntimeInput = false;
          final scheduled = requests.any(
            (request) => identical(request.fileEntry, fileEntry),
          );
          fileEntry.isRunning = scheduled;
          if (scheduled) {
            fileEntry.output = '';
            fileEntry.statusText = 'Queued';
          } else if (fileEntry.output.isEmpty) {
            fileEntry.statusText = 'Idle';
          }
        }
      }
      _infoMessage =
          'Starting ${requests.length} remote run(s) across '
          '${requests.map((request) => request.systemGroup.id).toSet().length} system(s)...';
    });

    try {
      final outcomes = await Future.wait(
        requests.map(_executeRemoteMultiRunJob),
      );
      final records = outcomes.map((outcome) => outcome.record).toList()
        ..sort((a, b) => b.startedAtIso.compareTo(a.startedAtIso));

      _remoteExecutionHistory = <RemoteExecutionRecord>[
        ...records,
        ..._remoteExecutionHistory,
      ];
      if (_remoteExecutionHistory.length > 30) {
        _remoteExecutionHistory = _remoteExecutionHistory.take(30).toList();
      }
      await _saveRemoteComputeState();

      final successCount = records.where((record) => record.success).length;
      final stoppedCount = outcomes
          .where((outcome) => outcome.stoppedByUser)
          .length;

      if (!mounted) {
        _runningParallelRemoteRuns = false;
        return;
      }

      setState(() {
        _runningParallelRemoteRuns = false;
        if (stoppedCount > 0) {
          _infoMessage =
              'Stop requested. $successCount/${records.length} remote run(s) completed successfully.';
        } else if (successCount == records.length) {
          _infoMessage =
              'Completed ${records.length} remote run(s) across ${requests.map((request) => request.systemGroup.id).toSet().length} system(s).';
        } else {
          _infoMessage =
              'Finished ${records.length} remote run(s) with ${records.length - successCount} failure(s).';
        }
      });
    } catch (error) {
      if (!mounted) {
        _runningParallelRemoteRuns = false;
        return;
      }
      setState(() {
        _runningParallelRemoteRuns = false;
        _infoMessage = 'Parallel remote execution failed: $error';
      });
    }
  }

  Future<void> _stopParallelRemoteRuns() async {
    final activeJobs = <_RemoteMultiRunFileEntry>[];
    for (final systemGroup in _multiRemoteRunSystems) {
      for (final fileEntry in systemGroup.jobs) {
        if (fileEntry.activeProcess != null) {
          activeJobs.add(fileEntry);
        }
      }
    }

    if (activeJobs.isEmpty) {
      if (!mounted) {
        return;
      }
      setState(() {
        _infoMessage = 'No active parallel remote runs to stop.';
      });
      return;
    }

    var signaledAny = false;
    for (final fileEntry in activeJobs) {
      fileEntry.stopRequested = true;
      var killed = false;
      try {
        killed = fileEntry.activeProcess?.kill(ProcessSignal.sigterm) ?? false;
      } catch (_) {
        // Fall through to default kill below.
      }
      if (!killed) {
        try {
          killed = fileEntry.activeProcess?.kill() ?? false;
        } catch (_) {
          // Best effort only.
        }
      }
      signaledAny = signaledAny || killed;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      for (final fileEntry in activeJobs) {
        fileEntry.activeRunSupportsRuntimeInput = false;
        fileEntry.output += '\n[Control] Stop requested by user.\n';
        fileEntry.statusText = 'Stopping';
      }
      _infoMessage = signaledAny
          ? 'Stop requested for active parallel remote runs.'
          : 'Could not send stop signal to the active parallel remote runs.';
    });
  }

  void _applySelectedRemoteCommandPreset({required bool showMessage}) {
    final preset = _remoteCommandPresetById(_selectedRemoteCommandPresetId);
    if (preset.id == 'custom') {
      if (!showMessage || !mounted) {
        return;
      }
      setState(() {
        _infoMessage =
            'Custom command mode selected. Edit the command field directly.';
      });
      return;
    }

    final peer = _peerByDnsName(_selectedRemoteDeviceDns ?? '');
    final command = _remoteCommandForPreset(presetId: preset.id, peer: peer);
    if (command.isEmpty) {
      if (!showMessage || !mounted) {
        return;
      }
      setState(() {
        _infoMessage =
            'Could not build preset command for ${_targetOsLabel(peer)} target.';
      });
      return;
    }

    setState(() {
      _remoteCommandController.text = command;
      _infoMessage =
          'Applied preset "${preset.label}" for ${_targetOsLabel(peer)}.';
    });
  }

  Future<void> _runSelectedRemoteCommandPreset() async {
    if (_selectedRemoteCommandPresetId != 'custom') {
      _applySelectedRemoteCommandPreset(showMessage: false);
    }
    await _runRemoteCommand();
  }

  Future<void> _copyTargetSshBootstrapCommand() async {
    final peer = _peerByDnsName(_selectedRemoteDeviceDns ?? '');
    final command = _targetSshSetupCommandForPeer(peer);
    if (command.isEmpty) {
      setState(() {
        _infoMessage = 'Generate or load an SSH key first.';
      });
      return;
    }

    await _copyToClipboard(
      text: command,
      successMessage: _targetSshDoctorCopiedMessage(peer),
    );
  }

  String _sshValidationCommand({
    required String user,
    required String dnsName,
    required String keyPath,
  }) {
    final buffer = StringBuffer(
      'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new ',
    );
    if (keyPath.trim().isNotEmpty) {
      buffer.write('-i "$keyPath" -o IdentitiesOnly=yes ');
    }
    buffer.write('$user@$dnsName "echo scaleserve-ssh-ok"');
    return buffer.toString();
  }

  Future<void> _copySshValidationCommand() async {
    final dnsName = _selectedRemoteDeviceDns;
    final user = _remoteUserController.text.trim();
    if (dnsName == null || dnsName.isEmpty) {
      setState(() {
        _infoMessage = 'Select a target device first.';
      });
      return;
    }
    if (user.isEmpty) {
      setState(() {
        _infoMessage =
            'Remote SSH user is required before copying validation command.';
      });
      return;
    }

    final keyPath = _remoteKeyPathController.text.trim();
    final command = _sshValidationCommand(
      user: user,
      dnsName: dnsName,
      keyPath: keyPath,
    );
    await _copyToClipboard(
      text: command,
      successMessage: 'Copied SSH validation command.',
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

  Future<void> _runQuickSshSetup() async {
    final dnsName = _selectedRemoteDeviceDns;
    final peer = _peerByDnsName(dnsName ?? '');
    if (dnsName == null || dnsName.isEmpty) {
      setState(() {
        _infoMessage = 'Select a target device first.';
      });
      return;
    }
    if (_remoteRunnerBusy) {
      return;
    }

    setState(() {
      _showRemoteAdvancedOptions = true;
      _infoMessage =
          'Quick setup started for $dnsName: ensuring key, detecting SSH user, and testing access.';
    });

    await _generateSshKeyPair();
    if (!mounted) {
      return;
    }
    if (_sshPublicKey.isEmpty) {
      setState(() {
        _infoMessage =
            'Quick setup could not prepare the SSH key. Open Advanced SSH options and generate key manually.';
      });
      return;
    }

    final bootstrapKeyPath = _bootstrapKeyPathController.text.trim();
    final bootstrapUser = _remoteUserController.text.trim();
    if (bootstrapKeyPath.isNotEmpty && bootstrapUser.isNotEmpty) {
      await _installPublicKeyOnRemote();
      if (!mounted) {
        return;
      }
    } else {
      final osLabel = _targetOsLabel(peer);
      final setupCommandLabel = _targetSshDoctorButtonLabel(peer);
      final runHint = _targetSshDoctorQuickSetupHint(peer);
      setState(() {
        _infoMessage = osLabel == 'target'
            ? 'If SSH still fails, click $setupCommandLabel and $runHint'
            : '$osLabel target detected. If SSH still fails, click $setupCommandLabel and $runHint';
      });
    }

    if (_remoteUserController.text.trim().isEmpty) {
      await _detectRemoteSshUser();
      if (!mounted) {
        return;
      }
    }

    if (_remoteUserController.text.trim().isEmpty) {
      setState(() {
        _infoMessage =
            'Quick setup could not detect a working SSH user. Open Advanced SSH options, set user manually, then run Test SSH Access.';
      });
      return;
    }

    await _testSshAccess();
    if (!mounted) {
      return;
    }

    setState(() {
      _showRemoteAdvancedOptions = false;
    });
  }

  Future<void> _installPublicKeyOnRemote() async {
    final dnsName = _selectedRemoteDeviceDns;
    final user = _remoteUserController.text.trim();
    final bootstrapKeyPath = _bootstrapKeyPathController.text.trim();

    if (_remoteExecutionBusy) {
      setState(() {
        _infoMessage =
            'Wait for the active remote run to finish before installing keys.';
      });
      return;
    }

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

    final peer = _peerByDnsName(dnsName);
    final bootstrapCommand = _targetSshSetupCommandForPeer(peer);
    if (bootstrapCommand.isEmpty) {
      setState(() {
        _infoMessage = 'Generate or load your ScaleServe SSH key first.';
      });
      return;
    }
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
      _infoMessage =
          'Installing ScaleServe public key on $dnsName (${_targetOsLabel(peer)})...';
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

    if (_remoteExecutionBusy) {
      setState(() {
        _infoMessage =
            'Wait for the active remote run to finish before testing SSH.';
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
    _activeRemoteSshProcess?.kill();
    for (final system in _multiRemoteRunSystems) {
      for (final job in system.jobs) {
        job.activeProcess?.kill();
      }
      system.dispose();
    }
    _authKeyController.dispose();
    _remoteUserController.dispose();
    _remoteKeyPathController.dispose();
    _bootstrapKeyPathController.dispose();
    _remoteCommandController.dispose();
    _deviceSearchController.dispose();
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
      try {
        await _remoteComputeStore.recordMachineSnapshot(snapshot: snapshot);
      } catch (_) {
        // Keep UI flow running even if snapshot persistence fails.
      }
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

      try {
        await _remoteComputeStore.appendCommandLog(
          commandText: result.commandString,
          safeCommandText: result.safeCommandString,
          exitCode: result.exitCode,
          stdout: result.stdout,
          stderr: result.stderr,
        );
      } catch (_) {
        // Ignore command log persistence failures.
      }

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
    return '& "C:\\Program Files\\Tailscale\\tailscale.exe" up --reset '
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

    if (_remoteExecutionBusy) {
      setState(() {
        _infoMessage =
            'Wait for the active remote run to finish before detecting the SSH user.';
      });
      return;
    }

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
          'Could not detect SSH user automatically. Run SSH setup once '
          'on the target machine, then retry Test SSH Access.';
    });
  }

  String _sshCommandTemplate(TailscalePeer peer) {
    final user = _defaultSshUserTemplate();
    return 'ssh $user@${peer.normalizedDnsName}';
  }

  Future<void> _runRemoteCommand() async {
    if (_remoteRunnerBusy) {
      return;
    }

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
      '-o',
      'BatchMode=yes',
      '-o',
      'NumberOfPasswordPrompts=0',
      '-o',
      'ConnectTimeout=8',
      '-o',
      'StrictHostKeyChecking=accept-new',
      if (keyPath.isNotEmpty) ...['-i', keyPath, '-o', 'IdentitiesOnly=yes'],
      target,
      remoteCommand,
    ];

    final safeCommand = StringBuffer('ssh ');
    if (keyPath.isNotEmpty) {
      safeCommand.write('-i $keyPath -o IdentitiesOnly=yes ');
    }
    safeCommand.write(
      '-o BatchMode=yes -o NumberOfPasswordPrompts=0 '
      '-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new ',
    );
    safeCommand.write('$target $remoteCommand');
    final startedAt = DateTime.now().toUtc();

    setState(() {
      _runningRemoteCommand = true;
      _remoteStopRequested = false;
      _remoteLiveOutput = 'Command: ${safeCommand.toString()}\n';
      _infoMessage = 'Running remote command on $dnsName...';
    });

    Process? process;
    try {
      process = await Process.start('ssh', sshArgs, runInShell: false);
      _activeRemoteSshProcess = process;
      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();

      final stdoutDone = Completer<void>();
      final stderrDone = Completer<void>();

      process.stdout
          .transform(utf8.decoder)
          .listen(
            (chunk) {
              stdoutBuffer.write(chunk);
              if (mounted) {
                setState(() {
                  _remoteLiveOutput += 'STDOUT: $chunk';
                });
              }
            },
            onDone: () => stdoutDone.complete(),
            onError: (_) => stdoutDone.complete(),
            cancelOnError: false,
          );

      process.stderr
          .transform(utf8.decoder)
          .listen(
            (chunk) {
              stderrBuffer.write(chunk);
              if (mounted) {
                setState(() {
                  _remoteLiveOutput += 'STDERR: $chunk';
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
      final stoppedByUser = _remoteStopRequested;
      final success = exitCode == 0;
      final finishedAt = DateTime.now().toUtc();

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
          startedAtIso: startedAt.toIso8601String(),
          finishedAtIso: finishedAt.toIso8601String(),
          deviceDnsName: dnsName,
          user: user,
          command: remoteCommand,
          exitCode: exitCode,
          success: success,
          stdout: stdoutText,
          stderr: stderrText,
          runType: 'remote_command',
          metadataJson: jsonEncode(<String, dynamic>{
            'safeCommand': safeCommand.toString(),
            'stoppedByUser': stoppedByUser,
          }),
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
        _infoMessage = stoppedByUser
            ? 'Remote command stopped by user.'
            : (success
                  ? 'Remote command completed on $dnsName.'
                  : 'Remote command failed on $dnsName (exit $exitCode).');
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
    } finally {
      if (identical(_activeRemoteSshProcess, process)) {
        _activeRemoteSshProcess = null;
      }
      _remoteStopRequested = false;
    }
  }

  bool _isPythonStdinCommand(String command) {
    final stdinPattern = RegExp(
      r'^(?:py|python(?:\d+(?:\.\d+)?)?)\s+-(?=\s|$)',
      caseSensitive: false,
    );
    return stdinPattern.hasMatch(command.trim());
  }

  String? _buildPythonInteractiveStreamCommand({
    required String remoteStdinCommand,
    required int scriptByteLength,
  }) {
    final trimmed = remoteStdinCommand.trim();
    final stdinPattern = RegExp(
      r'^\s*(py|python(?:\d+(?:\.\d+)?)?)\s+-(?:\s+(.*))?$',
      caseSensitive: false,
    );
    final match = stdinPattern.firstMatch(trimmed);
    if (match == null) {
      return null;
    }

    final launcher = match.group(1);
    if (launcher == null || launcher.isEmpty) {
      return null;
    }
    final trailingArgs = (match.group(2) ?? '').trim();

    const bootstrapScript = '''
import os
import subprocess
import sys
import tempfile

n = int(sys.argv[1])
args = sys.argv[2:]
path = os.path.join(tempfile.gettempdir(), 'scaleserve_stream.py')
remaining = n

with open(path, 'wb') as handle:
    while remaining > 0:
        chunk = sys.stdin.buffer.read(remaining)
        if not chunk:
            break
        handle.write(chunk)
        remaining -= len(chunk)

if remaining > 0:
    print(f"ERROR: expected {n} script bytes, received {n - remaining}.", file=sys.stderr)
    raise SystemExit(97)

try:
    rc = subprocess.call([sys.executable, "-u", path, *args], stdin=sys.stdin, stdout=sys.stdout, stderr=sys.stderr)
finally:
    try:
        os.remove(path)
    except OSError:
        pass

raise SystemExit(rc)
''';

    final bootstrapEncoded = base64.encode(utf8.encode(bootstrapScript));
    final command = StringBuffer()
      ..write('$launcher -c ')
      ..write(
        '"import base64;exec(base64.b64decode(\'$bootstrapEncoded\').decode(\'utf-8\'))"',
      )
      ..write(' $scriptByteLength');
    if (trailingArgs.isNotEmpty) {
      command.write(' $trailingArgs');
    }
    return command.toString();
  }

  Future<void> _stopRunningRemoteCommand() async {
    final process = _activeRemoteSshProcess;
    if (process == null) {
      if (!mounted) {
        return;
      }
      setState(() {
        _infoMessage = 'No active remote command to stop.';
      });
      return;
    }

    _remoteStopRequested = true;
    var killed = false;
    try {
      killed = process.kill(ProcessSignal.sigterm);
    } catch (_) {
      // Fallback below.
    }
    if (!killed) {
      try {
        killed = process.kill();
      } catch (_) {
        // Best effort only.
      }
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _remoteLiveOutput += '\n[Control] Stop requested by user.\n';
      _infoMessage = killed
          ? 'Stop requested. Waiting for remote process to exit...'
          : 'Could not send stop signal to remote process.';
    });
  }

  Future<String> _cleanupWindowsPythonProcesses({
    required String dnsName,
    required String user,
    required String keyPath,
    required String commandLinePattern,
  }) async {
    final escapedPattern = commandLinePattern.replaceAll("'", "''");
    final cleanupCommand =
        'powershell -NoProfile -NonInteractive -Command '
        '"\$pattern = \'$escapedPattern\'; '
        '\$targets = Get-CimInstance Win32_Process | Where-Object { '
        '((\$_.Name -ieq \'python.exe\') -or (\$_.Name -ieq \'py.exe\')) '
        '-and \$_.CommandLine -and (\$_.CommandLine -like (\'*\' + \$pattern + \'*\')) '
        '}; '
        'if (\$targets) { '
        '\$targets | Select-Object ProcessId, Name, CommandLine | Format-Table -AutoSize; '
        '\$targets | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue }; '
        'Write-Output (\'Killed matched processes: \' + (\$targets.Count)) '
        '} else { '
        'Write-Output (\'No matching python/py process found for pattern: \' + \$pattern) '
        '}"';

    final args = <String>[
      '-o',
      'BatchMode=yes',
      '-o',
      'StrictHostKeyChecking=accept-new',
      if (keyPath.isNotEmpty) ...['-i', keyPath, '-o', 'IdentitiesOnly=yes'],
      '$user@$dnsName',
      cleanupCommand,
    ];

    try {
      final result = await Process.run(
        'ssh',
        args,
        runInShell: false,
      ).timeout(const Duration(seconds: 20));
      final stdout = (result.stdout ?? '').toString().trim();
      final stderr = (result.stderr ?? '').toString().trim();
      final out = StringBuffer()
        ..writeln(
          'Command: ssh $user@$dnsName "<auto-kill-python pattern=$commandLinePattern>"',
        )
        ..writeln('Exit code: ${result.exitCode}');
      if (stdout.isNotEmpty) {
        out
          ..writeln('STDOUT:')
          ..writeln(stdout);
      }
      if (stderr.isNotEmpty) {
        out
          ..writeln('STDERR:')
          ..writeln(stderr);
      }
      return out.toString().trim();
    } on TimeoutException {
      return 'Timed out while trying to auto-kill python.exe on remote Windows target.';
    } catch (error) {
      return 'Auto-cleanup failed: $error';
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
        _activeSection = _DashboardSection.remote;
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

    final enableTailscaleSsh = _setupEnableTailscaleSsh && !Platform.isWindows;
    final successMessage = enableTailscaleSsh
        ? 'This laptop joined the tailnet and enabled Tailscale SSH.'
        : (Platform.isWindows && _setupEnableTailscaleSsh
              ? 'This Windows laptop joined the tailnet. '
                    'Tailscale SSH server is not supported on Windows.'
              : 'This laptop joined the tailnet.');

    await _runAction(
      successMessage: successMessage,
      action: () => widget.service.connect(
        authKey: authKey,
        reset: true,
        forceReauth: false,
        enableSsh: enableTailscaleSsh,
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

  String _formatDateTime(DateTime? value) {
    if (value == null) {
      return 'Not yet';
    }
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  String _sectionDescription(_DashboardSection section) {
    switch (section) {
      case _DashboardSection.overview:
        return 'Quick status and core connectivity actions.';
      case _DashboardSection.remote:
        return 'Run commands on remote tailnet devices through SSH.';
      case _DashboardSection.access:
        return 'Manage auth key preferences and one-click setup.';
      case _DashboardSection.devices:
        return 'Browse peers, filter devices, and run shortcuts.';
      case _DashboardSection.logs:
        return 'Inspect local command output and remote runner logs.';
    }
  }

  bool _peerMatchesQuery(TailscalePeer peer, String query) {
    if (query.isEmpty) {
      return true;
    }
    final q = query.toLowerCase();
    return peer.name.toLowerCase().contains(q) ||
        peer.normalizedDnsName.toLowerCase().contains(q) ||
        peer.ipAddress.toLowerCase().contains(q) ||
        peer.os.toLowerCase().contains(q);
  }

  Widget _buildOutputPanel({
    required BuildContext context,
    required String text,
    required String emptyText,
    double maxHeight = 320,
  }) {
    final display = text.trim().isEmpty ? emptyText : text;
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      constraints: BoxConstraints(minHeight: 120, maxHeight: maxHeight),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.22),
        ),
        color: theme.colorScheme.surface.withValues(alpha: 0.55),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(
          display,
          style: theme.textTheme.bodySmall?.copyWith(
            fontFamily: 'monospace',
            height: 1.45,
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip({
    required BuildContext context,
    required IconData icon,
    required String label,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: theme.colorScheme.surface.withValues(alpha: 0.9),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(icon, size: 15), const SizedBox(width: 6), Text(label)],
      ),
    );
  }

  String _multiRemoteRunProfileSummary(_RemoteMultiRunSystemGroup systemGroup) {
    final dnsName = (systemGroup.selectedDeviceDns ?? '').trim();
    if (dnsName.isEmpty) {
      return 'Choose a system, then each file row below will use that system profile.';
    }

    final peer = _peerByDnsName(dnsName);
    final profile = _remoteProfileForDns(dnsName);
    if (profile != null) {
      final hasCustomKey = profile.keyPath.trim().isNotEmpty;
      return hasCustomKey
          ? 'Using saved profile for ${profile.user} with a saved SSH key path.'
          : 'Using saved profile for ${profile.user}. Shared/default SSH key path will be used.';
    }

    final fallbackUser = _defaultSshUserForPeer(peer);
    if (fallbackUser == '<remote-user>') {
      return 'No saved profile found for this system yet. Save a device profile first in the single-target runner above.';
    }

    return 'No saved profile found yet. This block will fall back to SSH user "$fallbackUser" and the shared key path field above.';
  }

  Widget _buildMultiRemoteRunFileCard({
    required BuildContext context,
    required _RemoteMultiRunSystemGroup systemGroup,
    required _RemoteMultiRunFileEntry fileEntry,
  }) {
    final theme = Theme.of(context);
    final selectedPreset = _streamCommandPresetById(
      fileEntry.selectedStreamPresetId,
    );
    final fileLabel = _multiRemoteRunFileLabel(systemGroup, fileEntry);

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
        color: theme.colorScheme.surface.withValues(alpha: 0.55),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(fileLabel, style: theme.textTheme.titleSmall),
              const SizedBox(width: 10),
              _buildStatusChip(
                context: context,
                icon: fileEntry.isRunning
                    ? Icons.sync
                    : (fileEntry.statusText.startsWith('Completed')
                          ? Icons.check_circle_outline
                          : Icons.article_outlined),
                label: fileEntry.statusText,
              ),
              const Spacer(),
              if (fileEntry.activeProcess != null)
                TextButton.icon(
                  onPressed: () => _stopMultiRemoteRunJob(fileEntry),
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: fileEntry.selectedStreamPresetId,
            decoration: const InputDecoration(labelText: 'Stream mode preset'),
            items: _streamCommandPresetCatalog
                .map(
                  (preset) => DropdownMenuItem<String>(
                    value: preset.id,
                    child: Text(preset.label),
                  ),
                )
                .toList(),
            onChanged: _remoteRunnerBusy
                ? null
                : (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      fileEntry.selectedStreamPresetId = value;
                    });
                  },
          ),
          const SizedBox(height: 6),
          Text(selectedPreset.description, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _remoteRunnerBusy
                ? null
                : () => _applyMultiRemoteRunStreamPreset(
                    systemGroup: systemGroup,
                    fileEntry: fileEntry,
                    showMessage: true,
                  ),
            icon: const Icon(Icons.tune),
            label: const Text('Apply Stream Preset'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: fileEntry.filePathController,
            enabled: !_remoteRunnerBusy,
            decoration: InputDecoration(
              labelText: 'Local file path to stream',
              hintText: '/Users/you/path/script.sh / app.js / tool.py',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: fileEntry.remoteCommandController,
            enabled: !_remoteRunnerBusy,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Remote command (reads stdin)',
              hintText:
                  'bash -s / python3 - / node - / pwsh -Command - / ruby - / custom stdin reader',
            ),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: fileEntry.enableInteractiveInputForPythonStreamRuns,
            onChanged: _remoteRunnerBusy
                ? null
                : (value) {
                    setState(() {
                      fileEntry.enableInteractiveInputForPythonStreamRuns =
                          value ?? true;
                    });
                  },
            title: const Text(
              'Enable interactive input() for Python stream runs only',
            ),
            subtitle: const Text(
              'Other runtimes still work here; this only keeps stdin open for Python prompt/response flows.',
            ),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: fileEntry.autoKillWindowsPythonAfterStreamRun,
            onChanged: _remoteRunnerBusy
                ? null
                : (value) {
                    setState(() {
                      fileEntry.autoKillWindowsPythonAfterStreamRun =
                          value ?? true;
                    });
                  },
            title: const Text(
              'Auto-clean matched python/py process after stream run on Windows',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: fileEntry.windowsCleanupPatternController,
            enabled: !_remoteRunnerBusy,
            decoration: const InputDecoration(
              labelText: 'Windows cleanup match (command line contains)',
              hintText: 'scaleserve_stream',
            ),
          ),
          if (fileEntry.isRunning &&
              fileEntry.activeRunSupportsRuntimeInput) ...[
            const SizedBox(height: 10),
            TextField(
              controller: fileEntry.runtimeInputController,
              enabled: fileEntry.activeProcess != null,
              onSubmitted: fileEntry.activeProcess == null
                  ? null
                  : (_) => _sendMultiRemoteRunInputLine(fileEntry),
              decoration: InputDecoration(
                labelText: '$fileLabel runtime input',
                hintText: 'Type a reply for input() and press Send',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: fileEntry.activeProcess == null
                      ? null
                      : () => _sendMultiRemoteRunInputLine(fileEntry),
                  icon: const Icon(Icons.send),
                  label: const Text('Send Input'),
                ),
                OutlinedButton.icon(
                  onPressed: fileEntry.activeProcess == null
                      ? null
                      : () => _sendMultiRemoteRunInputEof(fileEntry),
                  icon: const Icon(Icons.subdirectory_arrow_left),
                  label: const Text('Send EOF'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          if (_runningParallelRemoteRuns && fileEntry.isRunning)
            const LinearProgressIndicator(),
          if (_runningParallelRemoteRuns && fileEntry.isRunning)
            const SizedBox(height: 10),
          _buildOutputPanel(
            context: context,
            text: fileEntry.output,
            emptyText: 'No output yet for $fileLabel.',
            maxHeight: 220,
          ),
        ],
      ),
    );
  }

  Widget _buildMultiRemoteRunSystemCard({
    required BuildContext context,
    required _RemoteMultiRunSystemGroup systemGroup,
    required List<TailscalePeer> remoteCandidates,
  }) {
    final theme = Theme.of(context);
    final systemLabel = _multiRemoteRunSystemLabel(systemGroup);

    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(systemLabel, style: theme.textTheme.titleSmall),
              ),
              if (_multiRemoteRunSystems.length > 1)
                TextButton.icon(
                  onPressed: _remoteRunnerBusy
                      ? null
                      : () => _removeMultiRemoteRunSystem(systemGroup),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove System'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: systemGroup.selectedDeviceDns,
            decoration: const InputDecoration(labelText: 'Target system'),
            items: remoteCandidates
                .map(
                  (peer) => DropdownMenuItem<String>(
                    value: peer.normalizedDnsName,
                    child: Text('${peer.name} (${peer.normalizedDnsName})'),
                  ),
                )
                .toList(),
            onChanged: _remoteRunnerBusy
                ? null
                : (value) {
                    setState(() {
                      systemGroup.selectedDeviceDns = value;
                    });
                  },
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<int>(
            initialValue: systemGroup.jobs.length,
            decoration: const InputDecoration(
              labelText: 'How many files for this system?',
            ),
            items: List<DropdownMenuItem<int>>.generate(
              6,
              (index) => DropdownMenuItem<int>(
                value: index + 1,
                child: Text('${index + 1}'),
              ),
            ),
            onChanged: _remoteRunnerBusy
                ? null
                : (value) {
                    if (value == null) {
                      return;
                    }
                    _setMultiRemoteRunFileCount(systemGroup, value);
                  },
          ),
          const SizedBox(height: 8),
          Text(
            _multiRemoteRunProfileSummary(systemGroup),
            style: theme.textTheme.bodySmall,
          ),
          ...systemGroup.jobs.map(
            (fileEntry) => _buildMultiRemoteRunFileCard(
              context: context,
              systemGroup: systemGroup,
              fileEntry: fileEntry,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardTitle(BuildContext context) {
    return const ScaleServeBrandLockupImage(height: 38);
  }

  Widget _buildHeroStat({
    required BuildContext context,
    required String label,
    required String value,
  }) {
    return Container(
      constraints: const BoxConstraints(minWidth: 148),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withValues(alpha: 0.10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.68),
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBrandHeroCard({
    required BuildContext context,
    required List<TailscalePeer> remoteCandidates,
    required bool connected,
  }) {
    final theme = Theme.of(context);
    final successfulRuns = _remoteExecutionHistory
        .where((record) => record.success)
        .length;
    final operatorLabel =
        widget.signedInUser?.username ?? 'Local operator mode';

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          gradient: ScaleServeBrandPalette.brandGradient,
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: Colors.white.withValues(alpha: 0.10),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.14),
                  ),
                ),
                child: Text(
                  connected ? 'LIVE OPERATOR SIGNAL' : 'SIGNAL STACK READY',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              const ScaleServeBrandLockupImage(height: 70),
              const SizedBox(height: 18),
              Text(
                'ScaleServe operator console using the exact uploaded brand lockup.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.white.withValues(alpha: 0.76),
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _buildHeroStat(
                    context: context,
                    label: 'TAILNET',
                    value: connected ? 'Connected' : 'Awaiting link',
                  ),
                  _buildHeroStat(
                    context: context,
                    label: 'VISIBLE PEERS',
                    value: '${remoteCandidates.length}',
                  ),
                  _buildHeroStat(
                    context: context,
                    label: 'SUCCESSFUL RUNS',
                    value: '$successfulRuns',
                  ),
                  _buildHeroStat(
                    context: context,
                    label: 'OPERATOR',
                    value: operatorLabel,
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: const [
                  ScaleServeFeatureBadge(
                    icon: Icons.bolt_outlined,
                    label: 'Exact brand lockup',
                    backgroundColor: Color(0x1AFFFFFF),
                    foregroundColor: Colors.white,
                    borderColor: Color(0x24FFFFFF),
                  ),
                  ScaleServeFeatureBadge(
                    icon: Icons.terminal,
                    label: 'Command-first workflows',
                    backgroundColor: Color(0x1AFFFFFF),
                    foregroundColor: Colors.white,
                    borderColor: Color(0x24FFFFFF),
                  ),
                  ScaleServeFeatureBadge(
                    icon: Icons.shield_outlined,
                    label: 'Trusted access layer',
                    backgroundColor: Color(0x1AFFFFFF),
                    foregroundColor: Colors.white,
                    borderColor: Color(0x24FFFFFF),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionSelector(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _DashboardSection.values
          .map((section) {
            final selected = _activeSection == section;
            return ChoiceChip(
              selected: selected,
              showCheckmark: false,
              selectedColor: theme.colorScheme.primaryContainer,
              backgroundColor: Colors.white.withValues(alpha: 0.82),
              side: BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.18),
              ),
              avatar: Icon(
                section.icon,
                size: 18,
                color: selected ? theme.colorScheme.primary : null,
              ),
              label: Text(
                section.label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: selected ? theme.colorScheme.primary : null,
                  fontWeight: FontWeight.w700,
                ),
              ),
              onSelected: (_) {
                setState(() {
                  _activeSection = section;
                });
              },
            );
          })
          .toList(growable: false),
    );
  }

  Widget _buildStatusCard({
    required BuildContext context,
    required TailscaleSnapshot? snapshot,
    required bool connected,
    required String stateText,
    required Color stateColor,
    required String lastUpdatedText,
  }) {
    final theme = Theme.of(context);
    return Card(
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            colors: [
              theme.colorScheme.primary.withValues(alpha: 0.12),
              Colors.white,
              theme.colorScheme.secondary.withValues(alpha: 0.07),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Control plane status',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.circle, size: 12, color: stateColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      connected
                          ? 'Connected ($stateText)'
                          : 'Not connected ($stateText)',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (_loadingStatus || _runningAction)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildStatusChip(
                    context: context,
                    icon: Icons.laptop_mac_outlined,
                    label: 'Device: ${snapshot?.selfName ?? 'Unknown'}',
                  ),
                  _buildStatusChip(
                    context: context,
                    icon: Icons.person_outline,
                    label: 'User: ${snapshot?.loginName ?? 'Unknown'}',
                  ),
                  _buildStatusChip(
                    context: context,
                    icon: Icons.hub_outlined,
                    label: 'Tailnet: ${snapshot?.tailnetName ?? 'Unknown'}',
                  ),
                  _buildStatusChip(
                    context: context,
                    icon: Icons.schedule,
                    label: 'Updated: $lastUpdatedText',
                  ),
                ],
              ),
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
                    icon: Icon(connected ? Icons.power_off : Icons.power),
                    label: Text(connected ? 'Disconnect' : 'Connect'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        _activeSection = _DashboardSection.remote;
                      });
                    },
                    icon: const Icon(Icons.terminal),
                    label: const Text('Open Remote Runner'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverviewCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Connection Controls',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Use direct commands for troubleshooting or scripted workflows.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
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
                TextButton.icon(
                  onPressed: () {
                    setState(() {
                      _activeSection = _DashboardSection.logs;
                    });
                  },
                  icon: const Icon(Icons.article_outlined),
                  label: const Text('View latest logs'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRemoteRunnerCard({
    required BuildContext context,
    required List<TailscalePeer> remoteCandidates,
    required String? selectedRemoteDns,
  }) {
    final theme = Theme.of(context);
    final isBusy = _remoteRunnerBusy;
    final selectedPeer = _peerByDnsName(selectedRemoteDns ?? '');
    final setupCommandLabel = _targetSshDoctorButtonLabel(selectedPeer);
    final setupTip = _targetSshDoctorTip(selectedPeer);
    final selectedCommandPreset = _remoteCommandPresetById(
      _selectedRemoteCommandPresetId,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Remote Compute Runner', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Use Quick Setup for the fastest path: select target, click Quick Setup, then run your command.',
            ),
            if (selectedRemoteDns != null) ...[
              const SizedBox(height: 10),
              _buildStatusChip(
                context: context,
                icon: Icons.memory_outlined,
                label: 'Selected target: $selectedRemoteDns',
              ),
            ],
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(
                  color: theme.colorScheme.outline.withValues(alpha: 0.2),
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Quick Setup (Recommended)',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '1) Select target device  2) Click Quick Setup  3) Run your command',
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: isBusy ? null : _runQuickSshSetup,
                        icon: const Icon(Icons.auto_fix_high),
                        label: Text(isBusy ? 'Please wait...' : 'Quick Setup'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _sshPublicKey.isEmpty
                            ? null
                            : _copyTargetSshBootstrapCommand,
                        icon: const Icon(Icons.terminal),
                        label: Text(setupCommandLabel),
                      ),
                      OutlinedButton.icon(
                        onPressed: isBusy ? null : _copySshValidationCommand,
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('Copy Validate SSH Command'),
                      ),
                      OutlinedButton.icon(
                        onPressed: isBusy ? null : _installPublicKeyOnRemote,
                        icon: const Icon(Icons.published_with_changes),
                        label: const Text('Install Key On Remote'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(_sshKeyStatusText, style: theme.textTheme.bodySmall),
                  const SizedBox(height: 6),
                  Text(setupTip),
                ],
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue:
                  (selectedRemoteDns != null &&
                      remoteCandidates.any(
                        (peer) => peer.normalizedDnsName == selectedRemoteDns,
                      ))
                  ? selectedRemoteDns
                  : null,
              decoration: const InputDecoration(labelText: 'Target device'),
              items: remoteCandidates
                  .map(
                    (peer) => DropdownMenuItem<String>(
                      value: peer.normalizedDnsName,
                      child: Text('${peer.name} (${peer.normalizedDnsName})'),
                    ),
                  )
                  .toList(),
              onChanged: isBusy ? null : (value) => _selectRemoteDevice(value),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _remoteUserController,
              enabled: !isBusy,
              decoration: const InputDecoration(
                labelText: 'Remote SSH user',
                hintText: 'ubuntu / opc / ec2-user',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _remoteCommandController,
              enabled: !isBusy,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Remote command',
                hintText:
                    'nvidia-smi / ollama run llama3.2:3b / curl OpenAI or Ollama APIs / custom shell command',
                helperText:
                    'Type your manual command here. The preset selector below is not an editable text box.',
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _selectedRemoteCommandPresetId,
              decoration: const InputDecoration(
                labelText: 'Command preset selector (shell + GPU + LLM)',
                helperText:
                    'Choose a preset to fill the command box above, or keep "Custom command" and type in the command box.',
              ),
              items: _remoteCommandPresetCatalog
                  .map(
                    (preset) => DropdownMenuItem<String>(
                      value: preset.id,
                      child: Text(preset.label),
                    ),
                  )
                  .toList(),
              onChanged: isBusy
                  ? null
                  : (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _selectedRemoteCommandPresetId = value;
                      });
                    },
            ),
            const SizedBox(height: 6),
            Text(
              selectedCommandPreset.description,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: isBusy
                      ? null
                      : () => _applySelectedRemoteCommandPreset(
                          showMessage: true,
                        ),
                  icon: const Icon(Icons.tune),
                  label: const Text('Apply Preset'),
                ),
                OutlinedButton.icon(
                  onPressed: isBusy ? null : _runSelectedRemoteCommandPreset,
                  icon: const Icon(Icons.bolt),
                  label: const Text('Run Selected Preset'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: isBusy ? null : _runRemoteCommand,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Run On Selected Device'),
                ),
                OutlinedButton.icon(
                  onPressed: isBusy
                      ? null
                      : () => _saveRemoteProfile(showMessage: true),
                  icon: const Icon(Icons.save),
                  label: const Text('Save Device Profile'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      _runningRemoteCommand && _activeRemoteSshProcess != null
                      ? _stopRunningRemoteCommand
                      : null,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Stop Running Command'),
                ),
                TextButton(
                  onPressed: isBusy || _remoteExecutionHistory.isEmpty
                      ? null
                      : _clearRemoteHistory,
                  child: const Text('Clear Run History'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Advanced SSH Options'),
              subtitle: const Text(
                'Manual key actions, detection, and first-time bootstrap key path.',
              ),
              initiallyExpanded: _showRemoteAdvancedOptions,
              onExpansionChanged: (expanded) {
                setState(() {
                  _showRemoteAdvancedOptions = expanded;
                });
              },
              children: [
                const SizedBox(height: 8),
                TextField(
                  controller: _remoteKeyPathController,
                  enabled: !isBusy,
                  decoration: const InputDecoration(
                    labelText: 'SSH key path (optional)',
                    hintText: '~/.ssh/id_ed25519',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _bootstrapKeyPathController,
                  enabled: !isBusy,
                  decoration: const InputDecoration(
                    labelText: 'Bootstrap key path (first-time setup)',
                    hintText: '~/.ssh/oracle_server_key.pem',
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: isBusy ? null : _generateSshKeyPair,
                      icon: const Icon(Icons.key),
                      label: const Text('Regenerate / Ensure Key'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _sshPublicKey.isEmpty ? null : _copyPublicKey,
                      icon: const Icon(Icons.copy),
                      label: const Text('Copy Public Key'),
                    ),
                    OutlinedButton.icon(
                      onPressed: isBusy ? null : _detectRemoteSshUser,
                      icon: const Icon(Icons.person_search),
                      label: Text(
                        _detectingRemoteUser
                            ? 'Detecting...'
                            : 'Detect SSH User',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: isBusy ? null : _testSshAccess,
                      icon: const Icon(Icons.verified_user),
                      label: const Text('Test SSH Access'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Multi-System Remote File / Script Runs'),
              subtitle: const Text(
                'Stream local files into stdin-based commands on one or many remote systems.',
              ),
              initiallyExpanded: _showParallelRemoteRuns,
              onExpansionChanged: (expanded) {
                setState(() {
                  _showParallelRemoteRuns = expanded;
                });
              },
              children: [
                const SizedBox(height: 8),
                Text(
                  'Each system block picks one target. Inside that block, choose how many files to run, set each file path and command, and every file gets its own output pane. Use Python, bash, sh, Node, PowerShell, Ruby, Perl, or any custom stdin-reading command. Interactive runtime replies currently stay Python-only.',
                  style: theme.textTheme.bodySmall,
                ),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: isBusy ? null : _runMultiRemoteSystemJobs,
                      icon: const Icon(Icons.playlist_play),
                      label: const Text('Run All Multi-System Jobs'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _runningParallelRemoteRuns
                          ? _stopParallelRemoteRuns
                          : null,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Stop Multi-System Jobs'),
                    ),
                    OutlinedButton.icon(
                      onPressed: isBusy ? null : _addMultiRemoteRunSystem,
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text('Add Another System'),
                    ),
                  ],
                ),
                ..._multiRemoteRunSystems.map(
                  (systemGroup) => _buildMultiRemoteRunSystemCard(
                    context: context,
                    systemGroup: systemGroup,
                    remoteCandidates: remoteCandidates,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (isBusy) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            _buildOutputPanel(
              context: context,
              text: _remoteLiveOutput,
              emptyText: 'No remote command run yet.',
              maxHeight: 360,
            ),
            const SizedBox(height: 12),
            Text('Run history', style: theme.textTheme.titleSmall),
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
                        color: record.success ? Colors.green : Colors.red,
                      ),
                      title: Text('${record.user}@${record.deviceDnsName}'),
                      subtitle: Text(
                        '${record.command}\n${_historyTime(record.startedAtIso)}  •  exit ${record.exitCode}',
                      ),
                      isThreeLine: true,
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccessCard({
    required BuildContext context,
    required bool tailscaleSshSupportedHere,
  }) {
    return Card(
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
              'Use this flow to re-authenticate or switch tailnet contexts.',
            ),
            const SizedBox(height: 6),
            Text(
              tailscaleSshSupportedHere
                  ? 'On a new laptop, one-click setup can join with SSH enabled.'
                  : 'On Windows, one-click setup joins the tailnet but skips --ssh.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _authKeyController,
              enabled: !_isBusy,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Auth key (optional)',
                hintText: 'tskey-...',
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Remember auth key on this computer'),
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
              title: const Text('Auto-connect on app launch with saved key'),
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
              title: Text(
                tailscaleSshSupportedHere
                    ? 'Enable Tailscale SSH during one-click setup'
                    : 'Enable Tailscale SSH during one-click setup (not supported on Windows)',
              ),
              value: tailscaleSshSupportedHere && _setupEnableTailscaleSsh,
              onChanged: _isBusy || !tailscaleSshSupportedHere
                  ? null
                  : (value) {
                      setState(() {
                        _setupEnableTailscaleSsh = value ?? true;
                      });
                    },
            ),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: _isBusy ? null : _saveKeyPreferences,
                  icon: const Icon(Icons.save),
                  label: const Text('Save key preferences'),
                ),
                TextButton(
                  onPressed: _isBusy || !_hasStoredKey ? null : _clearSavedKey,
                  child: const Text('Clear saved key'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Divider(),
            const SizedBox(height: 10),
            Text(
              'Authentication + OTP Source of Truth',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            const Text(
              'Login, MFA, forgot-password, machine snapshots, and run logs are backed by the Python API + PostgreSQL. '
              'Configure Gmail OTP sender in `scaleserve_backend/.env`, then restart backend.',
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
    );
  }

  Widget _buildAutomationCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Join Commands',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Install Tailscale on each PC and run one of these commands '
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
                          successMessage: 'Copied macOS join command.',
                        ),
                  icon: const Icon(Icons.desktop_mac),
                  label: const Text('Copy macOS command'),
                ),
                OutlinedButton.icon(
                  onPressed: _isBusy
                      ? null
                      : () => _copyToClipboard(
                          text: _windowsJoinCommand(),
                          successMessage: 'Copied Windows join command.',
                        ),
                  icon: const Icon(Icons.desktop_windows),
                  label: const Text('Copy Windows command'),
                ),
                OutlinedButton.icon(
                  onPressed: _isBusy
                      ? null
                      : () => _copyToClipboard(
                          text: _linuxJoinCommand(),
                          successMessage: 'Copied Linux join command.',
                        ),
                  icon: const Icon(Icons.computer),
                  label: const Text('Copy Linux command'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'If auth key is blank, commands use tskey-REPLACE_ME placeholder.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDevicesCard({
    required BuildContext context,
    required TailscaleSnapshot? snapshot,
  }) {
    final peers = snapshot?.peers ?? const <TailscalePeer>[];
    final query = _deviceSearchQuery.trim();
    final filteredPeers = peers
        .where((peer) => _peerMatchesQuery(peer, query))
        .toList(growable: false);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Connected Devices',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _deviceSearchController,
              onChanged: (value) {
                setState(() {
                  _deviceSearchQuery = value;
                });
              },
              decoration: InputDecoration(
                labelText: 'Filter by name, DNS, IP, or OS',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _deviceSearchQuery.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _deviceSearchController.clear();
                          setState(() {
                            _deviceSearchQuery = '';
                          });
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Showing ${filteredPeers.length} of ${peers.length} peer device(s)',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (snapshot == null || peers.isEmpty)
              const Text('No peers found from current status.')
            else ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.laptop_mac, color: Colors.blueGrey),
                title: Text('${snapshot.selfName} (This device)'),
                subtitle: Text(
                  '${snapshot.selfIpAddress}  •  ${snapshot.selfDnsName}',
                ),
              ),
              if (filteredPeers.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('No peers match the current filter.'),
                )
              else
                ...filteredPeers.map(
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
                      onSelected: (value) =>
                          _handlePeerMenuAction(peer: peer, action: value),
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
    );
  }

  Widget _buildLogsCard({
    required BuildContext context,
    required String title,
    required String text,
    required String emptyText,
    required bool showProgress,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (showProgress) const LinearProgressIndicator(),
            if (showProgress) const SizedBox(height: 8),
            _buildOutputPanel(
              context: context,
              text: text,
              emptyText: emptyText,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard(BuildContext context) {
    final lower = _infoMessage.toLowerCase();
    final isError = lower.contains('error') || lower.contains('failed');
    final color = isError ? Colors.red.shade50 : Colors.teal.shade50;
    final icon = isError ? Icons.error_outline : Icons.info_outline;

    return Card(
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: color,
        ),
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon),
            const SizedBox(width: 10),
            Expanded(child: Text(_infoMessage)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    final connected = snapshot?.isConnected ?? false;
    final stateText = snapshot?.backendState ?? 'Unknown';
    final stateColor = connected
        ? const Color(0xFF1F7A4F)
        : const Color(0xFFB54708);
    final remoteCandidates = snapshot?.peers ?? const <TailscalePeer>[];
    final selectedRemoteDns = _selectedRemoteDeviceDns;
    final tailscaleSshSupportedHere = !Platform.isWindows;
    final lastUpdatedText = _formatDateTime(_lastUpdated);

    final sectionCards = <Widget>[];
    switch (_activeSection) {
      case _DashboardSection.overview:
        sectionCards.add(_buildOverviewCard(context));
        sectionCards.add(_buildInfoCard(context));
      case _DashboardSection.remote:
        sectionCards.add(
          _buildRemoteRunnerCard(
            context: context,
            remoteCandidates: remoteCandidates,
            selectedRemoteDns: selectedRemoteDns,
          ),
        );
      case _DashboardSection.access:
        sectionCards.add(
          _buildAccessCard(
            context: context,
            tailscaleSshSupportedHere: tailscaleSshSupportedHere,
          ),
        );
        sectionCards.add(_buildAutomationCard(context));
      case _DashboardSection.devices:
        sectionCards.add(
          _buildDevicesCard(context: context, snapshot: snapshot),
        );
      case _DashboardSection.logs:
        sectionCards.add(
          _buildLogsCard(
            context: context,
            title: 'Command output',
            text: _latestCommandOutput,
            emptyText: 'No command run yet.',
            showProgress: _loadingStatus || _runningAction,
          ),
        );
        sectionCards.add(
          _buildLogsCard(
            context: context,
            title: 'Remote runner output',
            text: _remoteLiveOutput,
            emptyText: 'No remote command run yet.',
            showProgress: _runningRemoteCommand || _detectingRemoteUser,
          ),
        );
        sectionCards.add(_buildInfoCard(context));
    }

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 78,
        titleSpacing: 18,
        title: _buildDashboardTitle(context),
        actions: [
          if (widget.signedInUser != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: Theme.of(
                      context,
                    ).colorScheme.primaryContainer.withValues(alpha: 0.72),
                  ),
                  child: Text('User: ${widget.signedInUser!.username}'),
                ),
              ),
            ),
          if (widget.onLogout != null)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: TextButton.icon(
                onPressed: widget.onLogout,
                icon: const Icon(Icons.logout),
                label: const Text('Sign out'),
              ),
            ),
        ],
      ),
      body: ScaleServeShellBackground(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildBrandHeroCard(
                    context: context,
                    remoteCandidates: remoteCandidates,
                    connected: connected,
                  ),
                  const SizedBox(height: 16),
                  _buildStatusCard(
                    context: context,
                    snapshot: snapshot,
                    connected: connected,
                    stateText: stateText,
                    stateColor: stateColor,
                    lastUpdatedText: lastUpdatedText,
                  ),
                  const SizedBox(height: 16),
                  _buildSectionSelector(context),
                  const SizedBox(height: 14),
                  Text(
                    _activeSection.label,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _sectionDescription(_activeSection),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 16),
                  for (var i = 0; i < sectionCards.length; i++) ...[
                    sectionCards[i],
                    if (i != sectionCards.length - 1)
                      const SizedBox(height: 16),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
