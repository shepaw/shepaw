/// OS Tool Executor — cross-platform execution logic and risk classification.
///
/// Ported from `agents/mac_agent/mac_tools.py` to Dart, with cross-platform
/// support for macOS, Linux, Windows, Android, and iOS.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:url_launcher/url_launcher.dart';

import '../../../services/tool_config_service.dart';
import '../../../services/network/network_service.dart';

// ============================================================================
// Risk levels
// ============================================================================

enum RiskLevel { safe, lowRisk, highRisk }

// ============================================================================
// Constants
// ============================================================================

/// System paths considered dangerous to modify.
const _systemPathBlacklist = [
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
];

/// PIDs that must never be killed.
const _protectedPids = {0, 1};

/// Process names (lowercase) that must never be killed.
const _protectedProcessNames = {
  'kernel_task',
  'launchd',
  'windowserver',
  'loginwindow',
  'init',
  'systemd',
  'csrss',
  'wininit',
  'services',
  'lsass',
  'smss',
  'shepaw',
};

/// Shell commands considered read-only / safe.
const _safeShellCommands = {
  'ls', 'cat', 'head', 'tail', 'pwd', 'echo', 'whoami', 'hostname',
  'date', 'cal', 'uptime', 'uname', 'which', 'where', 'type',
  'wc', 'sort', 'uniq', 'cut', 'tr', 'grep', 'egrep', 'fgrep',
  'find', 'locate', 'file', 'stat', 'du', 'df', 'free',
  'ps', 'top', 'htop', 'id', 'groups', 'printenv', 'env',
  'sw_vers', 'system_profiler', 'sysctl', 'vm_stat',
  'diskutil', 'mdls', 'mdfind', 'xattr',
  'defaults read', 'launchctl list',
  // Windows
  'dir', 'ver', 'systeminfo', 'tasklist', 'ipconfig', 'netstat',
  'set', 'path', 'tree',
  // Network / process inspection
  'lsof', 'ss',
};

/// Shell patterns indicating high-risk operations.
const _highRiskShellPatterns = [
  'sudo', 'rm ', 'rm\t', 'rmdir',
  'mkfs', 'dd ', 'dd\t',
  'chmod', 'chown', 'chgrp',
  '> /', '>> /',
  'curl ', 'wget ',
  'pip install', 'npm install', 'brew install',
  'launchctl load', 'launchctl unload',
  'defaults write', 'defaults delete',
  'killall', 'kill ',
  'shutdown', 'reboot', 'halt',
  'networksetup',
  'dscl', 'security',
  // Windows
  'del ', 'rd ', 'rmdir ', 'format ',
  'reg delete', 'reg add',
  'net stop', 'net start',
  'sc delete',
];

/// AppleScript patterns indicating high-risk operations.
const _highRiskApplescriptPatterns = [
  'do shell script',
  'delete', 'remove',
  'quit', 'close',
  'set ', 'put ',
  'make new',
  'keystroke', 'key code',
  'click',
];

/// Maximum output size in bytes before truncation.
const _maxOutputSize = 10 * 1024; // 10 KB

// ============================================================================
// Risk classification
// ============================================================================

/// Check if a path is within a system-protected directory.
bool _isSystemPath(String path) {
  // Normalise: resolve `~` and get real path
  final expanded = path.startsWith('~')
      ? '${Platform.environment['HOME'] ?? ''}${path.substring(1)}'
      : path;
  final lower = expanded.toLowerCase();
  for (final p in _systemPathBlacklist) {
    if (lower.startsWith(p.toLowerCase())) return true;
  }
  return false;
}

/// Classify risk level of a tool call based on name and arguments.
RiskLevel classifyRisk(String toolName, Map<String, dynamic> args) {
  switch (toolName) {
    case 'shell_exec':
      return _classifyShellRisk(args['command'] as String? ?? '');
    case 'file_read':
      return RiskLevel.safe;
    case 'file_write':
      final path = args['path'] as String? ?? '';
      return _isSystemPath(path) ? RiskLevel.highRisk : RiskLevel.lowRisk;
    case 'file_delete':
      return RiskLevel.highRisk;
    case 'file_move':
      final src = args['source'] as String? ?? '';
      final dst = args['destination'] as String? ?? '';
      return (_isSystemPath(src) || _isSystemPath(dst))
          ? RiskLevel.highRisk
          : RiskLevel.lowRisk;
    case 'file_list':
      return RiskLevel.safe;
    case 'app_open':
      return RiskLevel.lowRisk;
    case 'url_open':
      return RiskLevel.lowRisk;
    case 'screenshot':
      return RiskLevel.safe;
    case 'clipboard_read':
      return RiskLevel.safe;
    case 'clipboard_write':
      return RiskLevel.lowRisk;
    case 'system_info':
      return RiskLevel.safe;
    case 'applescript_exec':
      return _classifyApplescriptRisk(args['script'] as String? ?? '');
    case 'process_list':
      return RiskLevel.safe;
    case 'process_kill':
      return RiskLevel.highRisk;
    case 'process_detail':
      return RiskLevel.safe;
    case 'network_connections':
      return RiskLevel.safe;
    default:
      return RiskLevel.highRisk;
  }
}

RiskLevel _classifyShellRisk(String command) {
  final cmdLower = command.trim().toLowerCase();

  // High-risk patterns first
  for (final pattern in _highRiskShellPatterns) {
    if (cmdLower.contains(pattern)) return RiskLevel.highRisk;
  }

  // Pipes / redirections to system paths
  if (command.contains('|')) {
    final lowerParts = ['/system', '/library', '/usr', '/bin', r'c:\windows'];
    for (final p in lowerParts) {
      if (cmdLower.contains(p)) return RiskLevel.highRisk;
    }
  }

  // Check base command against safe list
  final parts = command.trim().split(RegExp(r'\s+'));
  if (parts.isNotEmpty && _safeShellCommands.contains(parts[0])) {
    return RiskLevel.safe;
  }
  // Two-word safe commands
  if (parts.length >= 2) {
    final twoWord = '${parts[0]} ${parts[1]}'.toLowerCase();
    if (_safeShellCommands.contains(twoWord)) return RiskLevel.safe;
  }

  return RiskLevel.lowRisk;
}

RiskLevel _classifyApplescriptRisk(String script) {
  final lower = script.toLowerCase();
  for (final p in _highRiskApplescriptPatterns) {
    if (lower.contains(p)) return RiskLevel.highRisk;
  }
  return RiskLevel.lowRisk;
}

// ============================================================================
// Human-readable risk description (for confirmation dialogs)
// ============================================================================

/// Generate a human-readable description for the confirmation dialog.
String getRiskDescription(RiskLevel risk, String toolName, Map<String, dynamic> args) {
  switch (toolName) {
    case 'shell_exec':
      return 'Execute shell command: `${args['command'] ?? ''}`';
    case 'file_write':
      return 'Write to file: ${args['path'] ?? ''}';
    case 'file_delete':
      final recursive = args['recursive'] == true;
      return "Delete ${recursive ? 'directory (recursive)' : 'file'}: ${args['path'] ?? ''}";
    case 'file_move':
      return 'Move: ${args['source'] ?? ''} → ${args['destination'] ?? ''}';
    case 'applescript_exec':
      final script = args['script'] as String? ?? '';
      final preview = script.length > 100 ? '${script.substring(0, 100)}...' : script;
      return 'Execute AppleScript: $preview';
    case 'process_kill':
      final pid = args['pid'] ?? '';
      final force = args['force'] == true;
      return 'Kill process PID $pid${force ? ' (SIGKILL / force)' : ' (SIGTERM)'}';
    default:
      final argStr = jsonEncode(args);
      final truncated = argStr.length > 200 ? '${argStr.substring(0, 200)}...' : argStr;
      return 'Execute $toolName with args: $truncated';
  }
}

// ============================================================================
// Output truncation
// ============================================================================

String _truncate(String text, [int maxSize = _maxOutputSize]) {
  final bytes = utf8.encode(text);
  if (bytes.length <= maxSize) return text;
  final truncated = utf8.decode(bytes.sublist(0, maxSize), allowMalformed: true);
  return '$truncated\n\n[Output truncated: ${bytes.length} bytes total, showing first $maxSize bytes]';
}

// ============================================================================
// Tool execution
// ============================================================================

/// Execute an OS tool by name. Returns a JSON-serialisable result map.
///
/// Before execution, global [ToolConfigService] is consulted to:
/// 1. Apply parameter overrides (e.g. custom timeout).
/// 2. Inject API key for tools that require one (e.g. web_search).
Future<Map<String, dynamic>> runTool(
  String toolName,
  Map<String, dynamic> args,
) async {
  try {
    // ── 注入全局工具配置 ──────────────────────────────────────────────────────
    final resolvedArgs = await _injectToolConfig(toolName, args);

    switch (toolName) {
      case 'shell_exec':
        return await _execShell(resolvedArgs);
      case 'file_read':
        return await _execFileRead(resolvedArgs);
      case 'file_write':
        return await _execFileWrite(resolvedArgs);
      case 'file_delete':
        return await _execFileDelete(resolvedArgs);
      case 'file_move':
        return await _execFileMove(resolvedArgs);
      case 'file_list':
        return await _execFileList(resolvedArgs);
      case 'app_open':
        return await _execAppOpen(resolvedArgs);
      case 'url_open':
        return await _execUrlOpen(resolvedArgs);
      case 'screenshot':
        return await _execScreenshot(resolvedArgs);
      case 'clipboard_read':
        return await _execClipboardRead(resolvedArgs);
      case 'clipboard_write':
        return await _execClipboardWrite(resolvedArgs);
      case 'system_info':
        return await _execSystemInfo(resolvedArgs);
      case 'applescript_exec':
        return await _execApplescript(resolvedArgs);
      case 'process_list':
        return await _execProcessList(resolvedArgs);
      case 'process_kill':
        return await _execProcessKill(resolvedArgs);
      case 'process_detail':
        return await _execProcessDetail(resolvedArgs);
      case 'network_connections':
        return await _execNetworkConnections(resolvedArgs);
      case 'web_search':
        final query = resolvedArgs['query'] as String? ?? '';
        final limit = (resolvedArgs['limit'] as int?) ?? 10;
        return await NetworkService.instance.webSearch.search(query, limit: limit);
      case 'web_fetch':
        final url = resolvedArgs['url'] as String? ?? '';
        final format = (resolvedArgs['format'] as String?) ?? 'markdown';
        final timeoutSecs = (resolvedArgs['timeout'] as int?) ?? 30;
        return await NetworkService.instance.webFetch.fetchContent(url,
            format: format, timeoutSecs: timeoutSecs);
      default:
        return {'success': false, 'error': 'Unknown tool: $toolName'};
    }
  } catch (e) {
    return {'success': false, 'error': 'Tool execution error: $e'};
  }
}

/// 将工具全局配置注入到调用参数中。
///
/// 优先级：args 调用参数 > parameterOverrides（调用时的参数优先，
/// 允许 LLM 在特定场景下传入不同值）。
/// API Key 则总是从安全存储注入（不允许 LLM 覆盖）。
Future<Map<String, dynamic>> _injectToolConfig(
    String toolName, Map<String, dynamic> args) async {
  try {
    final configService = ToolConfigService.instance;
    final config = await configService.getToolConfig(toolName);

    // 1. 参数覆盖：仅填充 args 中不存在的 key
    Map<String, dynamic> resolved = Map.from(args);
    if (config?.parameterOverrides != null) {
      for (final entry in config!.parameterOverrides!.entries) {
        resolved.putIfAbsent(entry.key, () => entry.value);
      }
    }

    // 2. API Key 注入（强制覆盖，不允许 LLM 传入密钥）
    if (config?.hasApiKey == true) {
      final apiKey = await configService.getToolApiKey(toolName);
      if (apiKey != null && apiKey.isNotEmpty) {
        resolved['api_key'] = apiKey;
      }
    }

    return resolved;
  } catch (_) {
    // 配置注入失败不影响工具执行
    return args;
  }
}

// ---------------------------------------------------------------------------
// shell_exec
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execShell(Map<String, dynamic> args) async {
  final command = args['command'] as String? ?? '';
  final timeoutSecs = (args['timeout'] as int?) ?? 30;
  final timeout = Duration(seconds: timeoutSecs.clamp(1, 300));
  final workingDir = args['working_dir'] as String? ??
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      '.';

  try {
    ProcessResult result;
    if (Platform.isWindows) {
      result = await Process.run(
        'cmd',
        ['/c', command],
        workingDirectory: workingDir,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
    } else {
      result = await Process.run(
        '/bin/sh',
        ['-c', command],
        workingDirectory: workingDir,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout);
    }

    return {
      'success': result.exitCode == 0,
      'exit_code': result.exitCode,
      'stdout': _truncate(result.stdout as String),
      'stderr': _truncate(result.stderr as String),
    };
  } on ProcessException catch (e) {
    return {'success': false, 'error': e.toString()};
  } catch (e) {
    if (e.toString().contains('TimeoutException')) {
      return {'success': false, 'error': 'Command timed out after ${timeout.inSeconds}s'};
    }
    return {'success': false, 'error': e.toString()};
  }
}

// ---------------------------------------------------------------------------
// file_read
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execFileRead(Map<String, dynamic> args) async {
  final path = _expandHome(args['path'] as String? ?? '');
  final maxBytes = (args['max_bytes'] as int?) ?? _maxOutputSize;

  final file = File(path);
  if (!await file.exists()) {
    return {'success': false, 'error': 'File not found: $path'};
  }
  final stat = await file.stat();
  if (stat.type != FileSystemEntityType.file) {
    return {'success': false, 'error': 'Not a file: $path'};
  }

  try {
    final bytes = await file.readAsBytes();
    final content = utf8.decode(
      bytes.length > maxBytes ? bytes.sublist(0, maxBytes) : bytes,
      allowMalformed: true,
    );
    final result = <String, dynamic>{
      'success': true,
      'path': path,
      'size': bytes.length,
      'content': content,
    };
    if (bytes.length > maxBytes) {
      result['truncated'] = true;
      result['note'] = 'File is ${bytes.length} bytes, showing first $maxBytes bytes';
    }
    return result;
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

// ---------------------------------------------------------------------------
// file_write
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execFileWrite(Map<String, dynamic> args) async {
  final path = _expandHome(args['path'] as String? ?? '');
  final content = args['content'] as String? ?? '';
  final append = args['append'] as bool? ?? false;

  try {
    final file = File(path);
    await file.parent.create(recursive: true);
    if (append) {
      await file.writeAsString(content, mode: FileMode.append);
    } else {
      await file.writeAsString(content);
    }
    return {
      'success': true,
      'path': path,
      'bytes_written': utf8.encode(content).length,
      'mode': append ? 'append' : 'write',
    };
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

// ---------------------------------------------------------------------------
// file_delete
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execFileDelete(Map<String, dynamic> args) async {
  final path = _expandHome(args['path'] as String? ?? '');
  final recursive = args['recursive'] as bool? ?? false;

  try {
    final type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.notFound) {
      return {'success': false, 'error': 'Path not found: $path'};
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: recursive);
    } else {
      await File(path).delete();
    }
    return {'success': true, 'path': path, 'deleted': true};
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

// ---------------------------------------------------------------------------
// file_move
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execFileMove(Map<String, dynamic> args) async {
  final source = _expandHome(args['source'] as String? ?? '');
  final destination = _expandHome(args['destination'] as String? ?? '');

  try {
    final type = await FileSystemEntity.type(source);
    if (type == FileSystemEntityType.notFound) {
      return {'success': false, 'error': 'Source not found: $source'};
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(source).rename(destination);
    } else {
      await File(source).rename(destination);
    }
    return {'success': true, 'source': source, 'destination': destination};
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

// ---------------------------------------------------------------------------
// file_list
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execFileList(Map<String, dynamic> args) async {
  final path = _expandHome(args['path'] as String? ?? '');
  final showHidden = args['show_hidden'] as bool? ?? false;
  final detail = args['detail'] as bool? ?? false;

  final dir = Directory(path);
  if (!await dir.exists()) {
    return {'success': false, 'error': 'Directory not found: $path'};
  }

  try {
    final entities = await dir.list().toList();
    var names = entities.map((e) => e.path.split(Platform.pathSeparator).last).toList();
    if (!showHidden) {
      names = names.where((n) => !n.startsWith('.')).toList();
    }
    names.sort();

    if (detail) {
      final detailed = <Map<String, dynamic>>[];
      for (final name in names) {
        final entityPath = '${dir.path}${Platform.pathSeparator}$name';
        try {
          final stat = await FileStat.stat(entityPath);
          detailed.add({
            'name': name,
            'type': stat.type == FileSystemEntityType.directory ? 'directory' : 'file',
            'size': stat.size,
            'modified': stat.modified.millisecondsSinceEpoch / 1000,
          });
        } catch (_) {
          detailed.add({'name': name, 'type': 'unknown'});
        }
      }
      return {'success': true, 'path': path, 'entries': detailed, 'count': detailed.length};
    } else {
      return {'success': true, 'path': path, 'entries': names, 'count': names.length};
    }
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

// ---------------------------------------------------------------------------
// app_open
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execAppOpen(Map<String, dynamic> args) async {
  final appName = args['app_name'] as String? ?? '';
  try {
    ProcessResult result;
    if (Platform.isMacOS) {
      result = await Process.run('open', ['-a', appName]);
    } else if (Platform.isLinux) {
      result = await Process.run('xdg-open', [appName]);
    } else if (Platform.isWindows) {
      result = await Process.run('cmd', ['/c', 'start', '', appName]);
    } else {
      return {'success': false, 'error': 'app_open not supported on this platform'};
    }

    if (result.exitCode == 0) {
      return {'success': true, 'app': appName, 'message': 'Opened $appName'};
    }
    return {'success': false, 'error': (result.stderr as String).trim()};
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

// ---------------------------------------------------------------------------
// url_open
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execUrlOpen(Map<String, dynamic> args) async {
  final url = args['url'] as String? ?? '';
  try {
    final uri = Uri.parse(url);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (launched) {
      return {'success': true, 'url': url, 'message': 'Opened $url'};
    }
    return {'success': false, 'error': 'Failed to open URL: $url'};
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

// ---------------------------------------------------------------------------
// screenshot
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execScreenshot(Map<String, dynamic> args) async {
  final region = args['region'] as String? ?? 'full';
  final savePath = args['save_path'] as String?;

  final outputPath = savePath ?? '${Directory.systemTemp.path}/screenshot_${DateTime.now().millisecondsSinceEpoch}.png';

  try {
    if (Platform.isMacOS) {
      final cmd = ['screencapture'];
      if (region == 'window') {
        cmd.add('-w');
      } else if (region != 'full' && region.contains(',')) {
        cmd.addAll(['-R', region]);
      }
      cmd.add(outputPath);
      await Process.run(cmd[0], cmd.sublist(1))
          .timeout(const Duration(seconds: 10));
    } else if (Platform.isLinux) {
      // Try gnome-screenshot first, fall back to scrot
      try {
        await Process.run('gnome-screenshot', ['-f', outputPath])
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        await Process.run('scrot', [outputPath])
            .timeout(const Duration(seconds: 10));
      }
    } else if (Platform.isWindows) {
      // PowerShell screenshot
      final psScript = '''
Add-Type -AssemblyName System.Windows.Forms
[System.Windows.Forms.Screen]::PrimaryScreen | ForEach-Object {
  \$bitmap = New-Object System.Drawing.Bitmap(\$_.Bounds.Width, \$_.Bounds.Height)
  \$graphics = [System.Drawing.Graphics]::FromImage(\$bitmap)
  \$graphics.CopyFromScreen(\$_.Bounds.Location, [System.Drawing.Point]::Empty, \$_.Bounds.Size)
  \$bitmap.Save('$outputPath')
}
''';
      await Process.run('powershell', ['-Command', psScript])
          .timeout(const Duration(seconds: 10));
    } else {
      return {'success': false, 'error': 'screenshot not supported on this platform'};
    }

    final file = File(outputPath);
    if (await file.exists()) {
      final size = await file.length();
      return {'success': true, 'path': outputPath, 'size': size, 'message': 'Screenshot saved ($size bytes)'};
    }
    return {'success': false, 'error': 'Screenshot file not created'};
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

// ---------------------------------------------------------------------------
// clipboard_read
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execClipboardRead(Map<String, dynamic> args) async {
  try {
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      // Use platform-native commands for desktop
      ProcessResult result;
      if (Platform.isMacOS) {
        result = await Process.run('pbpaste', []);
      } else if (Platform.isLinux) {
        result = await Process.run('xclip', ['-selection', 'clipboard', '-o']);
      } else {
        result = await Process.run(
            'powershell', ['-Command', 'Get-Clipboard']);
      }
      final content = (result.stdout as String?) ?? '';
      return {
        'success': true,
        'content': _truncate(content),
        'length': content.length,
      };
    } else {
      // Mobile: use Flutter Clipboard API
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final content = data?.text ?? '';
      return {
        'success': true,
        'content': _truncate(content),
        'length': content.length,
      };
    }
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

// ---------------------------------------------------------------------------
// clipboard_write
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execClipboardWrite(Map<String, dynamic> args) async {
  final text = args['text'] as String? ?? '';
  try {
    if (Platform.isMacOS || Platform.isLinux || Platform.isWindows) {
      if (Platform.isMacOS) {
        final process = await Process.start('pbcopy', []);
        process.stdin.write(text);
        await process.stdin.close();
        await process.exitCode;
      } else if (Platform.isLinux) {
        final process =
            await Process.start('xclip', ['-selection', 'clipboard']);
        process.stdin.write(text);
        await process.stdin.close();
        await process.exitCode;
      } else {
        await Process.run(
          'powershell',
          ['-Command', 'Set-Clipboard', '-Value', text],
        );
      }
    } else {
      await Clipboard.setData(ClipboardData(text: text));
    }
    return {'success': true, 'length': text.length, 'message': 'Text copied to clipboard'};
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

// ---------------------------------------------------------------------------
// system_info
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execSystemInfo(Map<String, dynamic> args) async {
  final category = args['category'] as String? ?? 'overview';

  try {
    final info = <String, dynamic>{'success': true, 'category': category};

    if (category == 'overview') {
      info['hostname'] = Platform.localHostname;
      info['os'] = Platform.operatingSystem;
      info['os_version'] = Platform.operatingSystemVersion;
      info['dart_version'] = Platform.version;
      info['locale'] = Platform.localeName;
      info['number_of_processors'] = Platform.numberOfProcessors;

      if (!Platform.isAndroid && !Platform.isIOS) {
        final uptime = await _runSimple('uptime');
        if (uptime != null) info['uptime'] = uptime.trim();
      }
    } else if (category == 'cpu') {
      info['number_of_processors'] = Platform.numberOfProcessors;
      if (Platform.isMacOS) {
        info['cpu_name'] = (await _runSimple('sysctl -n machdep.cpu.brand_string'))?.trim();
      } else if (Platform.isLinux) {
        info['cpu_info'] = (await _runSimple("grep 'model name' /proc/cpuinfo | head -1"))?.trim();
      }
    } else if (category == 'memory') {
      if (Platform.isMacOS) {
        final mem = await _runSimple('sysctl -n hw.memsize');
        if (mem != null) {
          final bytes = int.tryParse(mem.trim()) ?? 0;
          info['total_bytes'] = bytes;
          info['total_gb'] = (bytes / (1024 * 1024 * 1024)).toStringAsFixed(2);
        }
      } else if (Platform.isLinux) {
        info['meminfo'] = (await _runSimple('free -h'))?.trim();
      } else if (Platform.isWindows) {
        info['meminfo'] = (await _runSimple('systeminfo | findstr Memory'))?.trim();
      }
    } else if (category == 'disk') {
      if (Platform.isWindows) {
        info['disk'] = (await _runSimple('wmic logicaldisk get size,freespace,caption'))?.trim();
      } else {
        info['disk'] = (await _runSimple('df -h'))?.trim();
      }
    } else if (category == 'network') {
      if (Platform.isMacOS || Platform.isLinux) {
        info['ip'] = (await _runSimple("ifconfig | grep 'inet ' | grep -v 127.0.0.1"))?.trim();
      } else if (Platform.isWindows) {
        info['ip'] = (await _runSimple('ipconfig'))?.trim();
      }
    } else if (category == 'battery') {
      if (Platform.isMacOS) {
        info['battery'] = (await _runSimple('pmset -g batt'))?.trim();
      }
    } else if (category == 'displays') {
      if (Platform.isMacOS) {
        info['displays'] = _truncate(
            (await _runSimple('system_profiler SPDisplaysDataType 2>/dev/null'))?.trim() ?? '');
      }
    }

    return info;
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

// ---------------------------------------------------------------------------
// applescript_exec
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execApplescript(Map<String, dynamic> args) async {
  final script = args['script'] as String? ?? '';
  try {
    final result = await Process.run('osascript', ['-e', script])
        .timeout(const Duration(seconds: 30));

    final stdout = _truncate(result.stdout as String);
    final stderr = (result.stderr as String).trim();

    if (result.exitCode == 0) {
      return {'success': true, 'output': stdout};
    }
    return {'success': false, 'error': stderr, 'output': stdout};
  } catch (e) {
    if (e.toString().contains('TimeoutException')) {
      return {'success': false, 'error': 'AppleScript timed out'};
    }
    return {'success': false, 'error': e.toString()};
  }
}

// ---------------------------------------------------------------------------
// process_list
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execProcessList(Map<String, dynamic> args) async {
  final filter = (args['filter'] as String?)?.toLowerCase();
  final sortBy = args['sort_by'] as String? ?? 'cpu';
  final limit = (args['limit'] as int?) ?? 50;

  try {
    List<Map<String, dynamic>> processes;

    if (Platform.isWindows) {
      final result = await Process.run(
        'powershell',
        ['-Command', 'Get-Process | Select-Object Id,ProcessName,CPU,WorkingSet64 | ConvertTo-Json'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 15));
      if (result.exitCode != 0) {
        return {'success': false, 'error': (result.stderr as String).trim()};
      }
      processes = _parseWindowsProcessJson(result.stdout as String);
    } else {
      final result = await Process.run(
        '/bin/sh',
        ['-c', 'ps aux'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 15));
      if (result.exitCode != 0) {
        return {'success': false, 'error': (result.stderr as String).trim()};
      }
      processes = _parsePsAux(result.stdout as String);
    }

    // Filter
    if (filter != null && filter.isNotEmpty) {
      processes = processes
          .where((p) => (p['name'] as String? ?? '').toLowerCase().contains(filter))
          .toList();
    }

    // Sort
    processes.sort((a, b) {
      switch (sortBy) {
        case 'memory':
          return ((b['memory_percent'] as num?) ?? 0)
              .compareTo((a['memory_percent'] as num?) ?? 0);
        case 'pid':
          return ((a['pid'] as int?) ?? 0).compareTo((b['pid'] as int?) ?? 0);
        case 'name':
          return (a['name'] as String? ?? '')
              .compareTo(b['name'] as String? ?? '');
        case 'cpu':
        default:
          return ((b['cpu_percent'] as num?) ?? 0)
              .compareTo((a['cpu_percent'] as num?) ?? 0);
      }
    });

    // Limit
    if (processes.length > limit) {
      processes = processes.sublist(0, limit);
    }

    return {
      'success': true,
      'count': processes.length,
      'processes': processes,
    };
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

List<Map<String, dynamic>> _parsePsAux(String output) {
  final lines = output.split('\n');
  if (lines.length < 2) return [];
  final results = <Map<String, dynamic>>[];
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    // ps aux columns: USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 11) continue;
    results.add({
      'user': parts[0],
      'pid': int.tryParse(parts[1]) ?? 0,
      'cpu_percent': double.tryParse(parts[2]) ?? 0.0,
      'memory_percent': double.tryParse(parts[3]) ?? 0.0,
      'rss_kb': int.tryParse(parts[5]) ?? 0,
      'name': parts.sublist(10).join(' ').split('/').last.split(' ').first,
      'command': parts.sublist(10).join(' '),
    });
  }
  return results;
}

List<Map<String, dynamic>> _parseWindowsProcessJson(String jsonStr) {
  try {
    final decoded = jsonDecode(jsonStr);
    final list = decoded is List ? decoded : [decoded];
    return list.map<Map<String, dynamic>>((item) {
      final m = item as Map<String, dynamic>;
      return {
        'pid': m['Id'] ?? 0,
        'name': m['ProcessName'] ?? '',
        'cpu_percent': (m['CPU'] as num?)?.toDouble() ?? 0.0,
        'memory_percent': 0.0,
        'rss_kb': ((m['WorkingSet64'] as num?) ?? 0) ~/ 1024,
      };
    }).toList();
  } catch (_) {
    return [];
  }
}

// ---------------------------------------------------------------------------
// process_kill
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execProcessKill(Map<String, dynamic> args) async {
  final pid = args['pid'] as int? ?? -1;
  final force = args['force'] as bool? ?? false;

  if (pid < 0) {
    return {'success': false, 'error': 'Invalid PID: $pid'};
  }

  // Check protected PIDs
  if (_protectedPids.contains(pid)) {
    return {'success': false, 'error': 'Cannot kill protected system process (PID $pid)'};
  }

  // Resolve process name and check protected names
  try {
    String? processName;
    if (Platform.isWindows) {
      final info = await Process.run(
        'powershell',
        ['-Command', 'Get-Process -Id $pid -ErrorAction SilentlyContinue | Select-Object ProcessName | ConvertTo-Json'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 5));
      if (info.exitCode == 0) {
        try {
          final decoded = jsonDecode(info.stdout as String);
          processName = (decoded as Map<String, dynamic>)['ProcessName'] as String?;
        } catch (_) {}
      }
    } else {
      final info = await Process.run(
        '/bin/sh',
        ['-c', 'ps -p $pid -o comm='],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 5));
      if (info.exitCode == 0) {
        processName = (info.stdout as String).trim().split('/').last;
      }
    }

    if (processName != null &&
        _protectedProcessNames.contains(processName.toLowerCase())) {
      return {
        'success': false,
        'error': 'Cannot kill protected system process: $processName (PID $pid)',
      };
    }

    // Kill the process
    ProcessResult result;
    if (Platform.isWindows) {
      result = await Process.run(
        'powershell',
        ['-Command', 'Stop-Process -Id $pid${force ? ' -Force' : ''} -ErrorAction Stop'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 10));
    } else {
      final signal = force ? '-9' : '-TERM';
      result = await Process.run(
        'kill',
        [signal, '$pid'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 10));
    }

    if (result.exitCode == 0) {
      return {
        'success': true,
        'pid': pid,
        'signal': force ? 'SIGKILL' : 'SIGTERM',
        'process_name': processName,
        'message': 'Sent ${force ? 'SIGKILL' : 'SIGTERM'} to process $pid${processName != null ? ' ($processName)' : ''}',
      };
    }
    return {
      'success': false,
      'error': (result.stderr as String).trim(),
    };
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

// ---------------------------------------------------------------------------
// process_detail
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execProcessDetail(Map<String, dynamic> args) async {
  final pid = args['pid'] as int? ?? -1;
  if (pid < 0) {
    return {'success': false, 'error': 'Invalid PID: $pid'};
  }

  try {
    if (Platform.isWindows) {
      final result = await Process.run(
        'powershell',
        ['-Command', 'Get-Process -Id $pid -ErrorAction Stop | Select-Object Id,ProcessName,CPU,WorkingSet64,StartTime,Path | ConvertTo-Json'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 10));
      if (result.exitCode != 0) {
        return {'success': false, 'error': (result.stderr as String).trim()};
      }
      try {
        final decoded = jsonDecode(result.stdout as String) as Map<String, dynamic>;
        return {
          'success': true,
          'pid': decoded['Id'],
          'name': decoded['ProcessName'],
          'cpu': decoded['CPU'],
          'memory_bytes': decoded['WorkingSet64'],
          'start_time': decoded['StartTime']?.toString(),
          'path': decoded['Path'],
        };
      } catch (_) {
        return {'success': true, 'raw': _truncate(result.stdout as String)};
      }
    } else {
      // Unix: ps + lsof
      final psResult = await Process.run(
        '/bin/sh',
        ['-c', 'ps -p $pid -o pid,user,%cpu,%mem,rss,lstart,command'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 10));

      if (psResult.exitCode != 0) {
        return {'success': false, 'error': 'Process not found (PID $pid)'};
      }

      final detail = _parsePsDetail(psResult.stdout as String, pid);

      // Try lsof for open files (best-effort)
      final lsofResult = await Process.run(
        '/bin/sh',
        ['-c', 'lsof -p $pid 2>/dev/null | head -20'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 5));
      if (lsofResult.exitCode == 0) {
        final lsofOutput = (lsofResult.stdout as String).trim();
        if (lsofOutput.isNotEmpty) {
          detail['open_files_preview'] = _truncate(lsofOutput, 2048);
        }
      }

      return {'success': true, ...detail};
    }
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

Map<String, dynamic> _parsePsDetail(String output, int pid) {
  final lines = output.split('\n');
  if (lines.length < 2) return {'pid': pid};
  final line = lines[1].trim();
  if (line.isEmpty) return {'pid': pid};
  // ps -o pid,user,%cpu,%mem,rss,lstart,command
  final parts = line.split(RegExp(r'\s+'));
  if (parts.length < 7) return {'pid': pid, 'raw': line};
  return {
    'pid': int.tryParse(parts[0]) ?? pid,
    'user': parts[1],
    'cpu_percent': double.tryParse(parts[2]) ?? 0.0,
    'memory_percent': double.tryParse(parts[3]) ?? 0.0,
    'rss_kb': int.tryParse(parts[4]) ?? 0,
    // lstart is multi-word, e.g. "Thu Feb 27 10:30:00 2026"
    'start_time': parts.length > 9 ? parts.sublist(5, 10).join(' ') : parts[5],
    'command': parts.length > 10
        ? parts.sublist(10).join(' ')
        : parts.last,
  };
}

// ---------------------------------------------------------------------------
// network_connections
// ---------------------------------------------------------------------------

Future<Map<String, dynamic>> _execNetworkConnections(Map<String, dynamic> args) async {
  final pid = args['pid'] as int?;

  try {
    List<Map<String, dynamic>> connections;

    if (Platform.isWindows) {
      final result = await Process.run(
        'powershell',
        ['-Command', 'Get-NetTCPConnection | Select-Object LocalAddress,LocalPort,RemoteAddress,RemotePort,State,OwningProcess | ConvertTo-Json'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 15));
      if (result.exitCode != 0) {
        return {'success': false, 'error': (result.stderr as String).trim()};
      }
      connections = _parseWindowsNetJson(result.stdout as String);
    } else if (Platform.isMacOS) {
      final pidFlag = pid != null ? ' -p $pid' : '';
      final result = await Process.run(
        '/bin/sh',
        ['-c', 'lsof -i -n -P$pidFlag 2>/dev/null'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 15));
      if (result.exitCode != 0 && (result.stdout as String).trim().isEmpty) {
        return {'success': true, 'count': 0, 'connections': <Map<String, dynamic>>[]};
      }
      connections = _parseLsofNetwork(result.stdout as String);
    } else {
      // Linux: ss
      final result = await Process.run(
        '/bin/sh',
        ['-c', 'ss -tunap 2>/dev/null'],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 15));
      if (result.exitCode != 0) {
        return {'success': false, 'error': (result.stderr as String).trim()};
      }
      connections = _parseSsOutput(result.stdout as String);
    }

    // Filter by PID if requested (for Windows & Linux where we parsed all)
    if (pid != null && !Platform.isMacOS) {
      connections = connections
          .where((c) => c['pid'] == pid)
          .toList();
    }

    return {
      'success': true,
      'count': connections.length,
      'connections': connections,
    };
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

List<Map<String, dynamic>> _parseLsofNetwork(String output) {
  final lines = output.split('\n');
  if (lines.length < 2) return [];
  final results = <Map<String, dynamic>>[];
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 9) continue;
    // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
    results.add({
      'process': parts[0],
      'pid': int.tryParse(parts[1]) ?? 0,
      'user': parts[2],
      'type': parts.length > 7 ? parts[7] : '',
      'name': parts.last,
    });
  }
  return results;
}

List<Map<String, dynamic>> _parseSsOutput(String output) {
  final lines = output.split('\n');
  if (lines.length < 2) return [];
  final results = <Map<String, dynamic>>[];
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.isEmpty) continue;
    final parts = line.split(RegExp(r'\s+'));
    if (parts.length < 5) continue;
    // Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process
    int? parsedPid;
    if (parts.length > 6) {
      final pidMatch = RegExp(r'pid=(\d+)').firstMatch(parts.last);
      if (pidMatch != null) parsedPid = int.tryParse(pidMatch.group(1)!);
    }
    results.add({
      'protocol': parts[0],
      'state': parts[1],
      'local': parts.length > 4 ? parts[4] : '',
      'remote': parts.length > 5 ? parts[5] : '',
      'pid': parsedPid,
    });
  }
  return results;
}

List<Map<String, dynamic>> _parseWindowsNetJson(String jsonStr) {
  try {
    final decoded = jsonDecode(jsonStr);
    final list = decoded is List ? decoded : [decoded];
    return list.map<Map<String, dynamic>>((item) {
      final m = item as Map<String, dynamic>;
      return {
        'local': '${m['LocalAddress']}:${m['LocalPort']}',
        'remote': '${m['RemoteAddress']}:${m['RemotePort']}',
        'state': m['State']?.toString() ?? '',
        'pid': m['OwningProcess'] ?? 0,
      };
    }).toList();
  } catch (_) {
    return [];
  }
}

// ============================================================================
// Helpers
// ============================================================================

String _expandHome(String path) {
  if (path.startsWith('~')) {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
    return '$home${path.substring(1)}';
  }
  return path;
}

Future<String?> _runSimple(String command) async {
  try {
    ProcessResult result;
    if (Platform.isWindows) {
      result = await Process.run('cmd', ['/c', command],
              stdoutEncoding: utf8, stderrEncoding: utf8)
          .timeout(const Duration(seconds: 10));
    } else {
      result = await Process.run('/bin/sh', ['-c', command],
              stdoutEncoding: utf8, stderrEncoding: utf8)
          .timeout(const Duration(seconds: 10));
    }
    if (result.exitCode == 0) return result.stdout as String;
  } catch (_) {}
  return null;
}
