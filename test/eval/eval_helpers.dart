import 'package:shepaw/models/message.dart';
import 'package:shepaw/models/remote_agent.dart';

/// Shared factories for offline capability eval scenarios.
Message evalMsg({
  required String id,
  required String content,
  bool isAgent = false,
  String name = 'U',
}) {
  return Message(
    id: id,
    content: content,
    timestampMs: DateTime.now().millisecondsSinceEpoch,
    from: MessageFrom(
      id: isAgent ? 'agent' : 'user',
      type: isAgent ? 'agent' : 'user',
      name: name,
    ),
    type: MessageType.text,
  );
}

RemoteAgent evalAgent({
  required Map<String, dynamic> metadata,
  String id = 'eval-agent',
  String name = 'EvalAgent',
}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  return RemoteAgent(
    id: id,
    name: name,
    token: '',
    endpoint: '',
    protocol: ProtocolType.acp,
    connectionType: ConnectionType.websocket,
    status: AgentStatus.online,
    capabilities: const [],
    metadata: metadata,
    createdAt: now,
    updatedAt: now,
  );
}
