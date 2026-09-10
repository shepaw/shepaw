import 'dart:io';

import 'local_agent_hub_models.dart';

class HostCommandResult {
  const HostCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get success => exitCode == 0;
}

/// Filesystem / process / network IO used by [LocalAgentHubService].
///
/// Production uses [LocalAgentHubHost.platform]; tests inject a fake.
class LocalAgentHubHost {
  LocalAgentHubHost({
    this.environment,
    this.windows,
    this.fileExistsFn,
    this.readFileFn,
    this.listDirFn,
    this.runFn,
    this.startDetachedFn,
    this.localIpv4sFn,
    this.homeDirFn,
  });

  factory LocalAgentHubHost.platform() => LocalAgentHubHost();

  final Map<String, String>? environment;
  final bool? windows;
  final bool Function(String path)? fileExistsFn;
  final String? Function(String path)? readFileFn;
  final List<String> Function(String path)? listDirFn;
  final Future<HostCommandResult> Function(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    Duration? timeout,
  })? runFn;
  final Future<void> Function(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  })? startDetachedFn;
  final Future<Set<String>> Function()? localIpv4sFn;
  final String Function()? homeDirFn;

  bool get isWindows => windows ?? Platform.isWindows;

  Map<String, String> get env => environment ?? Platform.environment;

  String homeDir() {
    if (homeDirFn != null) return homeDirFn!();
    final fromEnv = isWindows ? env['USERPROFILE'] : env['HOME'];
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    return Directory.current.path;
  }

  bool fileExists(String path) {
    if (fileExistsFn != null) return fileExistsFn!(path);
    return File(path).existsSync() || Directory(path).existsSync();
  }

  String? readFile(String path) {
    if (readFileFn != null) return readFileFn!(path);
    try {
      return File(path).readAsStringSync();
    } catch (_) {
      return null;
    }
  }

  List<String> listDir(String path) {
    if (listDirFn != null) return listDirFn!(path);
    try {
      return Directory(path)
          .listSync()
          .map((e) => e.path)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<Set<String>> localIpv4s() async {
    if (localIpv4sFn != null) return localIpv4sFn!();
    final out = <String>{'127.0.0.1'};
    try {
      for (final iface in await NetworkInterface.list(
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      )) {
        for (final addr in iface.addresses) {
          out.add(addr.address);
        }
      }
    } catch (_) {}
    return out;
  }

  Future<HostCommandResult> run(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    if (runFn != null) {
      return runFn!(
        executable,
        args,
        environment: environment,
        timeout: timeout,
      );
    }
    try {
      final result = await Process.run(
        executable,
        args,
        environment: environment,
        includeParentEnvironment: true,
        runInShell: isWindows,
      ).timeout(timeout ?? const Duration(seconds: 30));
      return HostCommandResult(
        exitCode: result.exitCode,
        stdout: result.stdout?.toString() ?? '',
        stderr: result.stderr?.toString() ?? '',
      );
    } on ProcessException catch (e) {
      return HostCommandResult(exitCode: 127, stdout: '', stderr: e.message);
    }
  }

  Future<void> startDetached(
    String executable,
    List<String> args, {
    Map<String, String>? environment,
  }) async {
    if (startDetachedFn != null) {
      await startDetachedFn!(executable, args, environment: environment);
      return;
    }
    await Process.start(
      executable,
      args,
      environment: environment,
      includeParentEnvironment: true,
      mode: ProcessStartMode.detached,
      runInShell: isWindows,
    );
  }

  /// Directories that GUI-launched apps often miss from PATH.
  List<String> extraBinDirs() {
    final home = homeDir();
    final dirs = <String>[];
    if (isWindows) {
      final pf = env['ProgramFiles'];
      final pf86 = env['ProgramFiles(x86)'];
      final appData = env['APPDATA'];
      final localApp = env['LOCALAPPDATA'];
      if (pf != null) dirs.add(joinPathSegments([pf, 'nodejs'], windows: true));
      if (pf86 != null) {
        dirs.add(joinPathSegments([pf86, 'nodejs'], windows: true));
      }
      if (appData != null) {
        dirs.add(joinPathSegments([appData, 'npm'], windows: true));
      }
      if (localApp != null) {
        dirs.add(joinPathSegments([localApp, 'fnm'], windows: true));
      }
    } else {
      dirs.addAll([
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '$home/.local/bin',
        '$home/.volta/bin',
        '$home/.fnm/aliases/default/bin',
        '$home/.local/share/fnm/aliases/default/bin',
        '$home/.nodenv/shims',
        '$home/.asdf/shims',
      ]);
      final nvmRoot = env['NVM_DIR']?.isNotEmpty == true
          ? env['NVM_DIR']!
          : '$home/.nvm';
      final versions = List<String>.from(listDir('$nvmRoot/versions/node'));
      versions.sort();
      for (final v in versions.reversed) {
        dirs.add(joinPathSegments([v, 'bin'], windows: false));
      }
    }
    return dirs.where(fileExists).toList();
  }

  Map<String, String> augmentedEnvironment() {
    final merged = Map<String, String>.from(env);
    final current = merged['PATH'] ?? merged['Path'] ?? '';
    merged['PATH'] = augmentPath(
      current,
      extraBinDirs(),
      windows: isWindows,
    );
    if (isWindows) merged['Path'] = merged['PATH']!;
    return merged;
  }
}
