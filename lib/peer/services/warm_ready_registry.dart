import 'dart:async';

/// 主机预热完成的回执状态。
///
/// App 进入会话时发 `agent_session_warm`，主机后台起好 ACP 进程后广播
/// `agent.warm_ready`。这里按 (agent, session) 记下结果，供 UI / 发送流程
/// 查询「进程是否已经就绪」，不必盲等冷启动。
class WarmReadyRegistry {
  WarmReadyRegistry._();

  static final instance = WarmReadyRegistry._();

  final Map<String, bool> _ready = <String, bool>{};
  final StreamController<Map<String, bool>> _changes =
      StreamController<Map<String, bool>>.broadcast();

  Stream<Map<String, bool>> get changes => _changes.stream;

  static String key(String agentId, String sessionId) =>
      '$agentId::$sessionId';

  Map<String, bool> get snapshot => Map<String, bool>.unmodifiable(_ready);

  bool isReady(String agentId, String sessionId) =>
      _ready[key(agentId, sessionId)] == true;

  /// 重新发起预热前清掉旧状态，避免把上一次的 ready 当成这一次的。
  void clear(String agentId, String sessionId) {
    if (_ready.remove(key(agentId, sessionId)) != null) {
      _publish();
    }
  }

  void record(String agentId, String sessionId, bool ok) {
    if (agentId.isEmpty || sessionId.isEmpty) return;
    _ready[key(agentId, sessionId)] = ok;
    _publish();
  }

  void _publish() {
    if (!_changes.isClosed) _changes.add(snapshot);
  }
}
