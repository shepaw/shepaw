import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'cli_host.dart';
import 'logger_service.dart';

/// 包里的 CLI 相对已安装的那份，该怎么处理。
enum BundledCliAction { absent, install, upgrade, keep }

class CliBundleResult {
  const CliBundleResult({
    required this.action,
    this.binary,
    this.warning,
  });

  final BundledCliAction action;

  /// 同步之后 `~/.shepaw/bin`（Windows 为 `%LOCALAPPDATA%\Shepaw\bin`）里的文件。
  final String? binary;

  final String? warning;
}

const cliPathMarker = '# shepaw-cli';

/// 包内版本不比已安装的新，就保持原样，避免盖掉 `shepaw update` 装上的更新版本。
BundledCliAction planBundledCli({
  required bool bundleExists,
  required String? bundledVersion,
  required bool installedExists,
  required String? installedVersion,
}) {
  if (!bundleExists) return BundledCliAction.absent;
  if (!installedExists) return BundledCliAction.install;
  if (bundledVersion == null) return BundledCliAction.keep;
  if (installedVersion == null) return BundledCliAction.upgrade;
  if (compareCliVersions(bundledVersion, installedVersion) > 0) {
    return BundledCliAction.upgrade;
  }
  return BundledCliAction.keep;
}

/// `shepaw version` 的第一行，例如 `shepaw 0.1.0`。
String? parseCliVersion(String stdout) {
  final match =
      RegExp(r'shepaw\s+v?(\d+\S*)', caseSensitive: false).firstMatch(stdout);
  if (match != null) return match.group(1);
  for (final line in stdout.split(RegExp(r'\r?\n'))) {
    final token = line.trim();
    if (RegExp(r'^v?\d').hasMatch(token)) {
      return token.startsWith('v') || token.startsWith('V')
          ? token.substring(1)
          : token;
    }
  }
  return null;
}

/// 负数表示 [a] 比 [b] 旧。解析不了的版本比解析得了的旧。
int compareCliVersions(String a, String b) {
  final pa = _parseCliVersion(a);
  final pb = _parseCliVersion(b);
  if (pa == null && pb == null) return 0;
  if (pa == null) return -1;
  if (pb == null) return 1;
  for (var i = 0; i < 3; i++) {
    final diff = pa.parts[i].compareTo(pb.parts[i]);
    if (diff != 0) return diff;
  }
  if (pa.pre == null && pb.pre == null) return 0;
  if (pa.pre == null) return 1;
  if (pb.pre == null) return -1;
  return pa.pre!.compareTo(pb.pre!);
}

class _ParsedCliVersion {
  const _ParsedCliVersion(this.parts, this.pre);

  final List<int> parts;
  final String? pre;
}

_ParsedCliVersion? _parseCliVersion(String raw) {
  var text = raw.trim();
  if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);
  final match = RegExp(
    r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?$',
  ).firstMatch(text);
  if (match == null) return null;
  return _ParsedCliVersion(
    [
      int.parse(match.group(1)!),
      int.parse(match.group(2) ?? '0'),
      int.parse(match.group(3) ?? '0'),
    ],
    match.group(4),
  );
}

/// macOS：`ShePaw.app/Contents/Resources/shepaw`。
/// Windows / Linux：可执行文件旁边的 `cli/shepaw`（Windows 加 `.exe`）。
String? bundledCliCandidate(
  String executable, {
  required String operatingSystem,
}) {
  final windows = operatingSystem == 'windows';
  final ctx = p.Context(style: windows ? p.Style.windows : p.Style.posix);
  if (operatingSystem == 'macos') {
    final contents = ctx.dirname(ctx.dirname(executable));
    return ctx.join(contents, 'Resources', 'shepaw');
  }
  if (operatingSystem == 'windows') {
    return ctx.join(ctx.dirname(executable), 'cli', 'shepaw.exe');
  }
  if (operatingSystem == 'linux') {
    return ctx.join(ctx.dirname(executable), 'cli', 'shepaw');
  }
  return null;
}

String shellRcPath({
  required String home,
  required String shell,
  bool macos = true,
}) {
  final base = p.basename(shell);
  switch (base) {
    case 'fish':
      return p.join(home, '.config', 'fish', 'config.fish');
    case 'bash':
      return p.join(home, '.bashrc');
    case 'zsh':
      return p.join(home, '.zshrc');
    default:
      return p.join(home, macos ? '.zshrc' : '.bashrc');
  }
}

String shellPathBlock(String shell) {
  if (p.basename(shell) == 'fish') {
    return '$cliPathMarker\nfish_add_path --prepend \$HOME/.shepaw/bin\n';
  }
  return '$cliPathMarker\nexport PATH="\$HOME/.shepaw/bin:\$PATH"\n';
}

/// 已经有 [cliPathMarker] 就原样返回。
String ensureShellRc(String contents, String block) {
  if (contents.contains(cliPathMarker)) return contents;
  final trimmed = contents.trimRight();
  if (trimmed.isEmpty) return block;
  return '$trimmed\n\n$block';
}

bool windowsUserPathContains(String? userPath, String binDir) {
  if (userPath == null || userPath.isEmpty) return false;
  final needle = binDir.replaceAll('/', '\\').toLowerCase();
  return userPath.split(';').any(
        (part) => part.trim().toLowerCase() == needle,
      );
}

String windowsUserPathWithBin(String? userPath, String binDir) {
  if (windowsUserPathContains(userPath, binDir)) {
    return userPath ?? binDir;
  }
  if (userPath == null || userPath.trim().isEmpty) return binDir;
  return '$binDir;${userPath.trim()}';
}

/// 桌面端把安装包里的 `shepaw` 同步到固定目录，并保证终端能找到它。
///
/// 没选过主机位置时只放下二进制，不在这里启动 Hub。已在跑的 Hub 只有被升级时才重启。
class CliBundle {
  static Future<CliBundleResult> sync() async {
    if (!CliHost.localCliSupported) {
      return const CliBundleResult(action: BundledCliAction.absent);
    }
    final bundledPath = bundledCliCandidate(
      Platform.resolvedExecutable,
      operatingSystem: Platform.operatingSystem,
    );
    if (bundledPath == null || !File(bundledPath).existsSync()) {
      return const CliBundleResult(action: BundledCliAction.absent);
    }
    final installedPath = CliHost.installedBinaryFromEnv(
      Platform.environment,
      windows: Platform.isWindows,
    );
    if (installedPath == null) {
      throw StateError('没有找到 CLI 安装目录');
    }
    final installedFile = File(installedPath);
    final bundledVersion = await _readVersion(bundledPath);
    final installedVersion =
        installedFile.existsSync() ? await _readVersion(installedPath) : null;
    final action = planBundledCli(
      bundleExists: true,
      bundledVersion: bundledVersion,
      installedExists: installedFile.existsSync(),
      installedVersion: installedVersion,
    );
    var restarted = false;
    if (action == BundledCliAction.install ||
        action == BundledCliAction.upgrade) {
      final running = await CliHost.detect();
      final replacingRunning = action == BundledCliAction.upgrade &&
          running != null &&
          _sameBinary(running.binary, installedPath);
      if (replacingRunning) {
        await _stop(installedPath);
        await _waitStopped();
        restarted = true;
      }
      await _replaceExecutable(File(bundledPath), installedFile);
      if (restarted) await CliHost.start(installedPath);
    }
    final warning = await _ensureOnPath(p.dirname(installedPath));
    LoggerService().info(
      'cli bundle ${action.name}'
      '${bundledVersion == null ? '' : ' bundled=$bundledVersion'}'
      '${installedVersion == null ? '' : ' installed=$installedVersion'}'
      ' → $installedPath',
      tag: 'CliBundle',
    );
    return CliBundleResult(
      action: action,
      binary: installedPath,
      warning: warning,
    );
  }

  static bool _sameBinary(String a, String b) {
    try {
      return File(a).resolveSymbolicLinksSync() ==
          File(b).resolveSymbolicLinksSync();
    } catch (_) {
      return p.normalize(a) == p.normalize(b);
    }
  }

  static Future<void> _stop(String binary) async {
    final result = await Process.run(binary, const ['stop']);
    if (result.exitCode != 0) {
      final detail = result.stderr.toString().trim();
      throw StateError(detail.isEmpty ? 'shepaw stop 失败' : detail);
    }
  }

  static Future<void> _waitStopped() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      if (await CliHost.detect() == null) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw StateError('shepaw 还在运行，没有替换');
  }

  static Future<void> _replaceExecutable(File source, File dest) async {
    await dest.parent.create(recursive: true);
    final tmp = File('${dest.path}.tmp');
    if (tmp.existsSync()) tmp.deleteSync();
    await tmp.writeAsBytes(await source.readAsBytes(), flush: true);
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['755', tmp.path]);
      if (chmod.exitCode != 0) {
        throw StateError('chmod ${tmp.path} 失败');
      }
    }
    File? previous;
    if (dest.existsSync()) {
      previous = File('${dest.path}.prev');
      if (previous.existsSync()) previous.deleteSync();
      Object? lastError;
      for (var attempt = 0; attempt < 10; attempt++) {
        try {
          dest.renameSync(previous.path);
          lastError = null;
          break;
        } catch (error) {
          lastError = error;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      if (lastError != null) {
        throw StateError('替换 CLI 失败: $lastError');
      }
    }
    tmp.renameSync(dest.path);
    if (previous != null && previous.existsSync()) {
      try {
        previous.deleteSync();
      } catch (_) {}
    }
    if (Platform.isMacOS) {
      await Process.run('xattr', ['-d', 'com.apple.quarantine', dest.path]);
    }
  }

  static Future<String?> _ensureOnPath(String binDir) async {
    try {
      if (Platform.isWindows) {
        await _ensureWindowsPath(binDir);
      } else {
        await _ensurePosixPath();
      }
      return null;
    } catch (error) {
      return '$error';
    }
  }

  static Future<void> _ensurePosixPath() async {
    final home = CliHost.homeDirFromEnv(Platform.environment);
    if (home.isEmpty || home == '.') return;
    final shell = Platform.environment['SHELL'] ?? '';
    final rc = File(shellRcPath(
      home: home,
      shell: shell,
      macos: Platform.isMacOS,
    ));
    final current = rc.existsSync() ? await rc.readAsString() : '';
    final next = ensureShellRc(current, shellPathBlock(shell));
    if (next == current) return;
    await rc.parent.create(recursive: true);
    await rc.writeAsString(next);
  }

  static Future<void> _ensureWindowsPath(String binDir) async {
    final current = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "[Environment]::GetEnvironmentVariable('Path','User')",
      ],
    );
    if (current.exitCode != 0) {
      throw StateError('读不到用户 PATH');
    }
    final existing = current.stdout.toString().trim();
    final next = windowsUserPathWithBin(existing, binDir);
    if (next == existing) return;
    final updated = await Process.run(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "[Environment]::SetEnvironmentVariable('Path', \$env:SHEPAW_USER_PATH, 'User')",
      ],
      environment: {
        ...Platform.environment,
        'SHEPAW_USER_PATH': next,
      },
    );
    if (updated.exitCode != 0) {
      throw StateError('写用户 PATH 失败');
    }
  }

  static Future<String?> _readVersion(String binary) async {
    try {
      final process = await Process.start(binary, const ['version']);
      unawaited(process.stderr.drain<void>());
      final stdout = process.stdout.transform(utf8.decoder).join();
      final code = await process.exitCode.timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      final text = await stdout.timeout(
        const Duration(seconds: 1),
        onTimeout: () => '',
      );
      if (code != 0) return null;
      return parseCliVersion(text);
    } catch (_) {
      return null;
    }
  }
}
