class AppUser {
  const AppUser({
    required this.id,
    required this.username,
    required this.role,
    required this.isActive,
    required this.mfaEnabled,
    required this.createdAtIso,
    required this.updatedAtIso,
    this.activeWorkspaceId,
    this.email,
    this.lastLoginAtIso,
  });

  final String id;
  final String username;
  final String role;
  final bool isActive;
  final bool mfaEnabled;
  final String createdAtIso;
  final String updatedAtIso;
  final String? activeWorkspaceId;
  final String? email;
  final String? lastLoginAtIso;
}
