/// Configurable policy for the personal-assistant OS sandbox.
///
/// [defaults] is the single source of truth for shipping deny lists.
/// Callers may override via [OsSandboxConfig.active] or [copyWith] / [fromJson].
library;

/// Active sandbox configuration (in-memory; persistence/UI can load into this).
class OsSandboxConfig {
  /// Master switch. When false, [OsSandboxPolicy] allows everything.
  final bool enabled;

  /// Absolute path prefixes that must not be mutated (write/delete/move).
  final List<String> deniedSystemPathPrefixes;

  /// Case-insensitive substrings; matching shell commands are hard-denied.
  ///
  /// Defaults cover catastrophic ops only — not ordinary `rm ~/file`.
  final List<String> deniedShellPatterns;

  /// Extra roots the user explicitly allows (advanced; does not lock workspace).
  final List<String> extraAllowedRoots;

  /// Extra roots that are always denied (in addition to system prefixes).
  final List<String> extraDeniedRoots;

  const OsSandboxConfig({
    required this.enabled,
    required this.deniedSystemPathPrefixes,
    required this.deniedShellPatterns,
    this.extraAllowedRoots = const [],
    this.extraDeniedRoots = const [],
  });

  /// Shipping defaults for a personal assistant (HOME-friendly, not project-locked).
  static const defaults = OsSandboxConfig(
    enabled: true,
    deniedSystemPathPrefixes: [
      '/System',
      '/Library',
      '/usr',
      '/bin',
      '/sbin',
      '/etc',
      '/var',
      '/private',
      r'C:\Windows',
      r'C:\Program Files',
      r'C:\Program Files (x86)',
    ],
    deniedShellPatterns: [
      // Privilege escalation
      'sudo',
      'doas',
      // Catastrophic recursive deletes
      'rm -rf /',
      'rm -rf /*',
      'rm -fr /',
      'rm -fr /*',
      'rm -rf ~',
      'rm -rf ~/',
      'rm -fr ~',
      'rm -fr ~/',
      'rm -rf \$home',
      'rm -rf \$HOME',
      // Disk destruction
      'mkfs',
      'dd if=',
      'format ',
      // System-area redirects (complements path deny)
      '> /system',
      '>> /system',
      '> /usr',
      '>> /usr',
      '> /etc',
      '>> /etc',
      '> /bin',
      '>> /bin',
      r'> c:\windows',
      r'>> c:\windows',
    ],
  );

  static OsSandboxConfig _active = defaults;

  /// Process-wide active config (tests may [setActive] / [resetActive]).
  static OsSandboxConfig get active => _active;

  static void setActive(OsSandboxConfig config) => _active = config;

  static void resetActive() => _active = defaults;

  OsSandboxConfig copyWith({
    bool? enabled,
    List<String>? deniedSystemPathPrefixes,
    List<String>? deniedShellPatterns,
    List<String>? extraAllowedRoots,
    List<String>? extraDeniedRoots,
  }) {
    return OsSandboxConfig(
      enabled: enabled ?? this.enabled,
      deniedSystemPathPrefixes:
          deniedSystemPathPrefixes ?? this.deniedSystemPathPrefixes,
      deniedShellPatterns: deniedShellPatterns ?? this.deniedShellPatterns,
      extraAllowedRoots: extraAllowedRoots ?? this.extraAllowedRoots,
      extraDeniedRoots: extraDeniedRoots ?? this.extraDeniedRoots,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'denied_system_path_prefixes': deniedSystemPathPrefixes,
        'denied_shell_patterns': deniedShellPatterns,
        'extra_allowed_roots': extraAllowedRoots,
        'extra_denied_roots': extraDeniedRoots,
      };

  factory OsSandboxConfig.fromJson(Map<String, dynamic> json) {
    List<String> strings(String key, List<String> fallback) {
      final raw = json[key];
      if (raw is! List) return List<String>.from(fallback);
      return raw.map((e) => e.toString()).toList();
    }

    return OsSandboxConfig(
      enabled: json['enabled'] as bool? ?? defaults.enabled,
      deniedSystemPathPrefixes: strings(
        'denied_system_path_prefixes',
        defaults.deniedSystemPathPrefixes,
      ),
      deniedShellPatterns: strings(
        'denied_shell_patterns',
        defaults.deniedShellPatterns,
      ),
      extraAllowedRoots: strings('extra_allowed_roots', const []),
      extraDeniedRoots: strings('extra_denied_roots', const []),
    );
  }
}
