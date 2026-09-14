import 'dart:convert';

import '../../clis/shepaw/shepaw_cli.dart';

/// 通过 CLI 执行一条 `events` 子命令并解析 JSON 结果。
///
/// 写操作（subscribe / unsubscribe / emit / ack）必须走 CLI 而不是直接调
/// `EventBus`：`EventSubscriptionConfigService.checkSubscribePermission` /
/// `checkEmitPermission` 只在命令内部执行，`--persist` 的 SQLite 落库也在
/// 命令里（`subscribe_command.dart` / `unsubscribe_command.dart`）。
/// 直接调 `EventBus.addSubscription` 会静默绕过 agent 权限闸门。
///
/// [isUiOperation] 只跳过**通用** CLI 闸门（`shepaw_cli.dart` 的
/// `checkPermission`），events 专属闸门照常生效。`execute` 自带 agentId 参数
/// 并在内部 `ChatAgentScope.runScoped`，调用方不需要自己包 Zone。
///
/// 永不抛异常：解析失败 / 执行异常都折叠成 `{'error': ...}`。
Future<Map<String, dynamic>> runEventsCli({
  required String subcommand,
  required String agentId,
  Map<String, String> flags = const {},
  bool isUiOperation = true,
}) async {
  try {
    final raw = await ShepawCLI.instance.execute(
      {
        'namespace': 'events',
        'subcommand': subcommand,
        'flags': flags,
      },
      agentId: agentId,
      isUiOperation: isUiOperation,
    );
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    return {'error': 'Unexpected CLI result: $raw'};
  } catch (e) {
    return {'error': e.toString()};
  }
}
