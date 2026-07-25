/// Lightweight OS isolation wrappers for [shell_exec].
///
/// Linux: bubblewrap (`bwrap`) when available.
/// macOS: `sandbox-exec` with a HOME-writable seatbelt profile when available.
/// Windows / mobile / missing tools: no wrap (policy sandbox still applies).
library;

import 'dart:io';

/// How a shell command will be launched.
class ShellIsolationPlan {
  /// Process executable (`bwrap`, `sandbox-exec`, `/bin/sh`, or `cmd`).
  final String executable;

  /// Arguments for [executable].
  final List<String> arguments;

  /// Working directory for [Process.run], or null when the wrapper chdirs.
  final String? workingDirectory;

  /// `bwrap` | `sandbox-exec` | `none`
  final String mode;

  const ShellIsolationPlan({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.mode,
  });
}

/// Builds and resolves shell isolation plans.
class OsShellIsolator {
  OsShellIsolator._();

  /// Pure: argv for `bwrap` wrapping `/bin/sh -c [command]`.
  ///
  /// HOME is bind-mounted read-write; common system trees are read-only;
  /// network namespace is unshared when [unshareNet] is true.
  static List<String> buildBwrapArguments({
    required String home,
    required String workingDir,
    required String command,
    bool unshareNet = true,
    List<String> roBinds = const [
      '/usr',
      '/bin',
      '/lib',
      '/lib64',
      '/sbin',
      '/etc',
    ],
    bool Function(String path)? pathExists,
  }) {
    final exists = pathExists ??
        (p) => Directory(p).existsSync() || File(p).existsSync();
    final args = <String>[
      '--die-with-parent',
      if (unshareNet) '--unshare-net',
      '--dev',
      '/dev',
      '--proc',
      '/proc',
      '--tmpfs',
      '/tmp',
    ];

    for (final path in roBinds) {
      if (exists(path)) {
        args.addAll(['--ro-bind', path, path]);
      }
    }

    if (home.isNotEmpty) {
      args.addAll(['--bind', home, home]);
    }

    // Ensure working dir is reachable when it is outside HOME.
    if (workingDir.isNotEmpty &&
        home.isNotEmpty &&
        !workingDir.startsWith(home) &&
        exists(workingDir)) {
      args.addAll(['--bind', workingDir, workingDir]);
    }

    final chdir = workingDir.isNotEmpty ? workingDir : home;
    if (chdir.isNotEmpty) {
      args.addAll(['--chdir', chdir]);
    }

    args.addAll(['/bin/sh', '-c', command]);
    return args;
  }

  /// Pure: seatbelt profile allowing writes under [home], denying system writes.
  static String buildMacSandboxProfile({required String home}) {
    final escapedHome = home.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    return '''
(version 1)
(deny default)
(allow process-exec)
(allow process-fork)
(allow signal)
(allow sysctl-read)
(allow mach-lookup)
(allow file-read*)
(allow file-write* (subpath "$escapedHome"))
(allow file-write* (subpath "/private/tmp") (subpath "/tmp") (subpath "/var/folders"))
(deny file-write* (subpath "/System") (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/etc") (subpath "/var") (subpath "/Library") (subpath "/private/etc") (subpath "/private/var"))
''';
  }

  /// Pure: argv for `sandbox-exec -p [profile] /bin/sh -c [command]`.
  static List<String> buildSandboxExecArguments({
    required String profile,
    required String command,
  }) {
    return ['-p', profile, '/bin/sh', '-c', command];
  }

  /// Unwrapped launch plan (Windows or fallback).
  static ShellIsolationPlan barePlan({
    required String command,
    required String workingDirectory,
  }) {
    if (Platform.isWindows) {
      return ShellIsolationPlan(
        executable: 'cmd',
        arguments: ['/c', command],
        workingDirectory: workingDirectory,
        mode: 'none',
      );
    }
    return ShellIsolationPlan(
      executable: '/bin/sh',
      arguments: ['-c', command],
      workingDirectory: workingDirectory,
      mode: 'none',
    );
  }

  /// Whether `bwrap` appears available on PATH / common locations.
  static bool isBwrapAvailable({bool Function(String path)? fileExists}) {
    final exists = fileExists ?? (p) => File(p).existsSync();
    const candidates = [
      '/usr/bin/bwrap',
      '/bin/bwrap',
      '/usr/local/bin/bwrap',
    ];
    for (final c in candidates) {
      if (exists(c)) return true;
    }
    return false;
  }

  /// Whether `sandbox-exec` appears available.
  static bool isSandboxExecAvailable({bool Function(String path)? fileExists}) {
    final exists = fileExists ?? (p) => File(p).existsSync();
    return exists('/usr/bin/sandbox-exec');
  }

  /// Resolve the best available isolation plan for this platform.
  ///
  /// Never throws; falls back to [barePlan] when wrappers are missing.
  /// On mobile, always returns [barePlan] (no process wrapping).
  static Future<ShellIsolationPlan> resolve({
    required String command,
    required String workingDirectory,
    String? home,
    bool Function(String path)? fileExists,
  }) async {
    final effectiveHome = home ??
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';

    if (Platform.isAndroid || Platform.isIOS) {
      return barePlan(command: command, workingDirectory: workingDirectory);
    }

    if (Platform.isLinux &&
        isBwrapAvailable(fileExists: fileExists)) {
      return ShellIsolationPlan(
        executable: 'bwrap',
        arguments: buildBwrapArguments(
          home: effectiveHome,
          workingDir: workingDirectory,
          command: command,
        ),
        workingDirectory: null,
        mode: 'bwrap',
      );
    }

    if (Platform.isMacOS &&
        isSandboxExecAvailable(fileExists: fileExists)) {
      final profile = buildMacSandboxProfile(home: effectiveHome);
      return ShellIsolationPlan(
        executable: 'sandbox-exec',
        arguments: buildSandboxExecArguments(
          profile: profile,
          command: command,
        ),
        workingDirectory: workingDirectory,
        mode: 'sandbox-exec',
      );
    }

    return barePlan(command: command, workingDirectory: workingDirectory);
  }
}
