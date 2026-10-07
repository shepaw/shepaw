import '../../generated/cli_spec/validator.dart';

/// App 调 Hub 的入口。Hub 不可达时停在只读结果，不在本机另做裁决。
class HubCommandClient {
  HubCommandClient({this.reachable = false});

  final bool reachable;

  HubCommandResult call(
    String command,
    Object? args, {
    String? device,
  }) {
    final check = validateCommand(command, args ?? <String, dynamic>{});
    if (!check.ok) {
      return HubCommandResult.fail(
        command,
        check.code ?? 'invalid_args',
        check.message ?? 'invalid args',
      );
    }
    if (!reachable) {
      return HubCommandResult.fail(
        command,
        'device_offline',
        'Hub 不可达，只能看本地缓存',
        readOnly: true,
        device: device,
      );
    }
    return HubCommandResult.fail(
      command,
      'internal',
      'Hub 传输还没接到这个客户端',
      device: device,
    );
  }
}

class HubCommandResult {
  const HubCommandResult({
    required this.ok,
    required this.command,
    this.code,
    this.message,
    this.readOnly = false,
    this.device,
  });

  final bool ok;
  final String command;
  final String? code;
  final String? message;
  final bool readOnly;
  final String? device;

  factory HubCommandResult.fail(
    String command,
    String code,
    String message, {
    bool readOnly = false,
    String? device,
  }) {
    return HubCommandResult(
      ok: false,
      command: command,
      code: code,
      message: message,
      readOnly: readOnly,
      device: device,
    );
  }
}
