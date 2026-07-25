/// Evaluates whether an OS tool call is allowed under [OsSandboxConfig].
///
/// Hard deny is a security floor; confirmation cards remain a separate UX layer.
library;

import 'dart:io';

import 'os_sandbox_config.dart';

/// Result of a sandbox policy check.
class OsSandboxDecision {
  final bool allowed;
  final String? reason;

  const OsSandboxDecision._({required this.allowed, this.reason});

  const OsSandboxDecision.allow() : this._(allowed: true);

  const OsSandboxDecision.deny(String reason)
      : this._(allowed: false, reason: reason);
}

/// Policy gate used by [runTool] before execution.
class OsSandboxPolicy {
  final OsSandboxConfig config;

  /// Optional HOME override for tests (defaults to platform HOME/USERPROFILE).
  final String? homeOverride;

  OsSandboxPolicy({
    OsSandboxConfig? config,
    this.homeOverride,
  }) : config = config ?? OsSandboxConfig.active;

  /// Expand `~` and produce an absolute, normalized path string.
  ///
  /// When [resolveLinks] is true and the path exists, resolves symlinks.
  String canonicalize(String path, {bool resolveLinks = false}) {
    final home = homeOverride ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    var expanded = path;
    if (expanded.startsWith('~')) {
      expanded = '$home${expanded.substring(1)}';
    }
    if (expanded.isEmpty) return expanded;

    try {
      final entity = File(expanded);
      final absolute = entity.isAbsolute
          ? entity.path
          : File('${Directory.current.path}${Platform.pathSeparator}$expanded')
              .absolute
              .path;
      // Normalize `.` / `..` via URI when possible.
      final normalized = Uri.file(absolute).normalizePath().toFilePath();
      if (resolveLinks) {
        try {
          if (FileSystemEntity.typeSync(normalized) !=
              FileSystemEntityType.notFound) {
            return File(normalized).resolveSymbolicLinksSync();
          }
        } catch (_) {}
      }
      return normalized;
    } catch (_) {
      return expanded;
    }
  }

  /// Whether [path] falls under a denied system / extra-denied prefix.
  bool isDeniedPath(String path) {
    final canonical = canonicalize(path).toLowerCase();
    if (canonical.isEmpty) return false;

    for (final prefix in config.deniedSystemPathPrefixes) {
      if (_pathHasPrefix(canonical, prefix.toLowerCase())) return true;
    }
    for (final prefix in config.extraDeniedRoots) {
      if (_pathHasPrefix(canonical, canonicalize(prefix).toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  static bool _pathHasPrefix(String pathLower, String prefixLower) {
    if (prefixLower.isEmpty) return false;
    if (pathLower == prefixLower) return true;
    final sep = Platform.pathSeparator;
    // Ensure `/usr` does not match `/usrlocal` — require boundary or exact.
    if (pathLower.startsWith(prefixLower)) {
      if (pathLower.length == prefixLower.length) return true;
      final next = pathLower[prefixLower.length];
      return next == '/' || next == '\\' || next == sep;
    }
    return false;
  }

  /// Evaluate a tool invocation. Unknown tools are allowed (risk UX handles them).
  OsSandboxDecision evaluate(String toolName, Map<String, dynamic> args) {
    if (!config.enabled) return const OsSandboxDecision.allow();

    switch (toolName) {
      case 'shell_exec':
        return evaluateShell(args['command'] as String? ?? '');
      case 'file_write':
      case 'file_delete':
        return evaluatePathMutation(args['path'] as String? ?? '');
      case 'file_move':
        final src = evaluatePathMutation(args['source'] as String? ?? '');
        if (!src.allowed) return src;
        return evaluatePathMutation(args['destination'] as String? ?? '');
      case 'file_read':
      case 'file_list':
        // Reads of system paths are allowed; only extraDeniedRoots block access.
        final path = args['path'] as String? ?? '';
        if (path.isEmpty) return const OsSandboxDecision.allow();
        final canonical = canonicalize(path).toLowerCase();
        for (final prefix in config.extraDeniedRoots) {
          if (_pathHasPrefix(canonical, canonicalize(prefix).toLowerCase())) {
            return OsSandboxDecision.deny(
              'OS sandbox denied access to path under "$prefix": $path',
            );
          }
        }
        return const OsSandboxDecision.allow();
      default:
        return const OsSandboxDecision.allow();
    }
  }

  /// Hard-deny mutations under system / extra-denied roots.
  OsSandboxDecision evaluatePathMutation(String path) {
    if (!config.enabled) return const OsSandboxDecision.allow();
    if (path.trim().isEmpty) {
      return const OsSandboxDecision.deny('OS sandbox denied: empty path');
    }
    if (isDeniedPath(path)) {
      return OsSandboxDecision.deny(
        'OS sandbox denied mutating protected path: $path',
      );
    }
    return const OsSandboxDecision.allow();
  }

  /// Hard-deny catastrophic shell patterns from config.
  OsSandboxDecision evaluateShell(String command) {
    if (!config.enabled) return const OsSandboxDecision.allow();
    final trimmed = command.trim();
    if (trimmed.isEmpty) {
      return const OsSandboxDecision.deny('OS sandbox denied: empty command');
    }
    final lower = trimmed.toLowerCase();

    for (final pattern in config.deniedShellPatterns) {
      final p = pattern.toLowerCase();
      if (p.isEmpty) continue;
      if (lower.contains(p)) {
        return OsSandboxDecision.deny(
          'OS sandbox denied catastrophic shell pattern "$pattern"',
        );
      }
    }

    // Redirects into configured system prefixes (even if not in pattern list).
    for (final prefix in config.deniedSystemPathPrefixes) {
      final p = prefix.toLowerCase();
      if (p.isEmpty) continue;
      if (lower.contains('> $p') ||
          lower.contains('>> $p') ||
          lower.contains('>$p') ||
          lower.contains('>>$p')) {
        return OsSandboxDecision.deny(
          'OS sandbox denied shell redirect into protected path "$prefix"',
        );
      }
    }

    return const OsSandboxDecision.allow();
  }
}
