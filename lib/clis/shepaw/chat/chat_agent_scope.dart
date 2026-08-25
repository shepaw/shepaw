import 'dart:async';

import '../../../services/she_service.dart';

/// 当前 CLI 执行上下文（由 [ShepawCLI.execute] 在每次调用前注入）。
///
/// 供 `store write` 等命令解析 runtime 落点：
/// `runtime/<agentOrGroup>/<channel>/[wf_…__step_…/]artifacts/...`
///
/// 三个字段是 **Zone-scoped** 的：每次 [ChatAgentScope.runScoped] 在独立
/// Zone 内执行命令，getter 优先读该 Zone 的值。群聊编排循环用 `Future.wait`
/// 并发执行多名成员的工具调用，原先静态可变全局会被并发覆盖（串号/串群）；
/// 现在每次 execute 各带自己的 Zone，互不干扰。Zone 之外（如顶层手动 CLI）
/// 回退到 She 默认值。
class ChatAgentScope {
  static const _agentIdKey = 'chat.agentId';
  static const _channelIdKey = 'chat.channelId';
  static const _runtimeOwnerIdKey = 'chat.runtimeOwnerId';

  /// 当前执行命令的 Agent ID；Zone 外默认 She。
  static String get agentId =>
      Zone.current[_agentIdKey] as String? ?? SheService.sheId;

  /// 当前对话频道；空字符串表示未知。
  static String get channelId => Zone.current[_channelIdKey] as String? ?? '';

  /// 非空时 `store write` 强制写入该 runtime owner（群 id），
  /// 避免成员落到自己的 `runtime/<agentId>/`。
  static String get runtimeOwnerId =>
      Zone.current[_runtimeOwnerIdKey] as String? ?? '';

  /// 在隔离 Zone 中执行 [body]，并把当前执行者上下文写入该 Zone。
  ///
  /// 命令的整棵调用树（含异步等待、`store write` 的落盘解析）都继承该
  /// Zone，读取点拿到各自调用方的上下文；并发调用各占一个 Zone，互不覆盖。
  static Future<R> runScoped<R>({
    required String agentId,
    String channelId = '',
    String runtimeOwnerId = '',
    required Future<R> Function() body,
  }) {
    return runZoned<Future<R>>(
      body,
      zoneValues: {
        _agentIdKey: agentId,
        _channelIdKey: channelId,
        _runtimeOwnerIdKey: runtimeOwnerId,
      },
    );
  }
}
