import '../../clis/shepaw/os/os_executor.dart' as os_exec;
import '../../generated/cli_spec/validator.dart';

/// 设备上的最后一道防线：复验参数，拒绝还没有本机确认界面的 critical 命令，
/// 其余交给现有 OS 执行器（里面还有沙箱策略）。
class DeviceCommandRunner {
  DeviceCommandRunner({
    Future<Map<String, dynamic>> Function(String tool, Map<String, dynamic> args)?
        execute,
  }) : _execute = execute ?? os_exec.runTool;

  final Future<Map<String, dynamic>> Function(
    String tool,
    Map<String, dynamic> args,
  ) _execute;

  Future<Map<String, dynamic>> handle(Map<String, dynamic> frame) async {
    final callId = (frame['call_id'] as String?) ?? '';
    final command = (frame['command'] as String?)?.trim() ?? '';
    if (command.isEmpty) {
      return _error(callId, 'invalid_args', 'missing command');
    }
    final check = validateCommand(command, frame['args'] ?? <String, dynamic>{});
    if (!check.ok) {
      return _error(callId, check.code ?? 'invalid_args', check.message ?? 'invalid args');
    }
    if (commandField(command, 'risk') == 'critical') {
      return _error(
        callId,
        'device_permission_missing',
        '这台设备还不能在本地确认 critical 命令',
      );
    }
    final tool = _toolName(command);
    if (tool == null) {
      return _error(callId, 'device_unsupported', '这台设备没有 $command 的执行器');
    }
    final args = <String, dynamic>{};
    check.args?.forEach((key, value) {
      if (value != null) args[key] = value;
    });
    final raw = await _execute(tool, args);
    if (raw['sandbox_denied'] == true) {
      return _error(
        callId,
        'forbidden',
        (raw['error'] as String?) ?? 'OS sandbox denied',
      );
    }
    if (raw['success'] == false) {
      return _error(
        callId,
        'internal',
        (raw['error'] as String?) ?? 'device command failed',
      );
    }
    return {
      'type': 'cmd.result',
      'call_id': callId,
      'ok': true,
      'data': raw,
    };
  }
}

Object? commandField(String id, String field) {
  final commands = commandCatalog()['commands'];
  if (commands is! List) return null;
  for (final item in commands) {
    if (item is Map && item['id'] == id) return item[field];
  }
  return null;
}

String? _toolName(String command) {
  const tools = {
    'os.file.read': 'file_read',
    'os.file.write': 'file_write',
    'os.file.delete': 'file_delete',
    'os.file.move': 'file_move',
    'os.file.list': 'file_list',
    'os.command.exec': 'shell_exec',
    'os.command.sysinfo': 'system_info',
    'os.process.list': 'process_list',
    'os.process.kill': 'process_kill',
    'os.process.detail': 'process_detail',
    'os.process.connections': 'network_connections',
    'os.app.open': 'app_open',
    'os.app.url': 'url_open',
    'os.app.screenshot': 'screenshot',
    'os.clipboard.read': 'clipboard_read',
    'os.clipboard.write': 'clipboard_write',
    'os.location.get': 'location_get',
    'os.location.status': 'location_status',
    'os.macos.exec': 'applescript_exec',
  };
  return tools[command];
}

Map<String, dynamic> _error(String callId, String code, String message) {
  return {
    'type': 'cmd.result',
    'call_id': callId,
    'ok': false,
    'error': {'code': code, 'message': message, 'retryable': false},
  };
}
