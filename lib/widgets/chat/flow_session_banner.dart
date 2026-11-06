import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/message.dart';
import '../../peer/services/hub_flow.dart';
import '../../screens/flow_run_screen.dart';
import '../../service_locator.dart' show getIt;
import '../../services/local_database_service.dart';

/// Test seam：查 agent 行的来源主机。线上走本机 RemoteAgent 表。
@visibleForTesting
Future<String> Function(String agentRowId)? debugFlowSourcePeerResolver;

/// Test seam：当前登录主机（回退路径）。
@visibleForTesting
Future<String> Function()? debugFlowActiveHost;

/// Test seam：拦截「查看运行」的跳转，记录实际用的 peer / runId。
@visibleForTesting
Future<void> Function(String peerId, String runId)? debugOpenFlowRun;

/// 从产生 `metadata.flow` 的那条消息的 agent 行恢复来源主机（A7-7）。
///
/// 双主机时 `activeHost()` 是「当前」主机，而会话可能是另一台主机发起的。
/// agent 行上的 `source_peer_id`（或 metadata 里的同名字段）才是这次运行的
/// 归属；查不到再让调用方退回 activeHost。
Future<String> resolveFlowOriginSourcePeer(String agentRowId) async {
  final override = debugFlowSourcePeerResolver;
  if (override != null) return (await override(agentRowId)).trim();
  final id = agentRowId.trim();
  if (id.isEmpty || !getIt.isRegistered<LocalDatabaseService>()) return '';
  try {
    final agent = await getIt<LocalDatabaseService>().getRemoteAgentById(id);
    if (agent == null) return '';
    final fromRow = agent.sourcePeerId?.trim() ?? '';
    if (fromRow.isNotEmpty) return fromRow;
    final fromMeta = agent.metadata['source_peer_id'];
    return fromMeta is String ? fromMeta.trim() : '';
  } catch (_) {
    // 数据库还没就绪不该挡住「查看运行」；交给 activeHost 兜底。
    return '';
  }
}

/// 从会话里的某条消息上认出「这是工作流发起的会话」。
///
/// 主机给流程 prompt 打的 `metadata.flow = {run_id, node_key, attempt}` 会随
/// `message.created` 一起落库；不需要新的协议字段，也不用记一张节点映射表。
class FlowSessionOrigin {
  const FlowSessionOrigin({
    required this.runId,
    required this.nodeKey,
    this.peerId = '',
    this.sourceAgentId = '',
  });

  final String runId;
  final String nodeKey;

  /// 已经能确定的来源主机 peer id（消息 metadata 直接带了 source_peer_id）。
  final String peerId;

  /// 该会话的 agent 行 id：用它查 `source_peer_id` 恢复来源主机（A7-7）。
  final String sourceAgentId;

  /// 横幅上只显示最后一段节点 id，完整 key（`outer/inner`）太长。
  String get label => nodeKey.isEmpty ? runId : nodeKey.split('/').last;
}

FlowSessionOrigin? flowSessionOriginOf(
  Iterable<Message> messages, {
  String agentRowId = '',
}) {
  final rowId = agentRowId.trim();
  for (final message in messages) {
    final flow = message.metadata?['flow'];
    if (flow is! Map) continue;
    final runId = flow['run_id']?.toString() ?? '';
    if (runId.isEmpty) continue;
    final rawPeer = message.metadata?['source_peer_id'];
    return FlowSessionOrigin(
      runId: runId,
      nodeKey: flow['node_key']?.toString() ?? '',
      peerId: rawPeer is String ? rawPeer.trim() : '',
      sourceAgentId: rowId.isNotEmpty ? rowId : message.senderId,
    );
  }
  return null;
}

/// O(1) 的轻量签名：消息列表实例、首尾两条消息对象，以及它们身上
/// `metadata.flow` 的对象/长度。给已有 prompt 原地补 `metadata.flow` 时
/// 签名会变，横幅就能出现；不用每次重建都遍历整张消息表。
int _flowMetadataSignature(List<Message> messages) {
  Object? flowAt(int index) => messages[index].metadata?['flow'];
  int flowLengthAt(int index) => messages[index].metadata?.length ?? 0;
  if (messages.isEmpty) return identityHashCode(messages);
  return Object.hash(
    identityHashCode(messages),
    identityHashCode(messages.first),
    identityHashCode(flowAt(0)),
    flowLengthAt(0),
    identityHashCode(messages.last),
    identityHashCode(flowAt(messages.length - 1)),
    flowLengthAt(messages.length - 1),
  );
}

/// 会话级缓存：消息列表没变就不重复全量扫描。
///
/// 聊天页每次重建（抽屉拖动、键盘、流式通知）都会调到这里。长 DM 里
/// [flowSessionOriginOf] 每次从头扫到尾纯属浪费；只有列表长度、最后一条 id、
/// 频道、调用方的 [metadataRevision] 或上面的轻量签名变了才重新扫描。
/// [metadataRevision] 给「中间某条消息的 metadata 被原地改写」留一条显式
/// 失效通道，避免为了正确性退化成每次全量扫描（A3-8）。
class FlowSessionOriginCache {
  FlowSessionOrigin? _origin;
  int _length = -1;
  String? _lastId;
  String _scope = '';
  String _agentRowId = '';
  int _metadataRevision = -1;
  int _metadataSignature = 0;

  /// 真正重新扫描的次数（测试用来确认缓存生效）。
  int scanCount = 0;

  FlowSessionOrigin? resolve(
    List<Message> messages, {
    String scope = '',
    int metadataRevision = 0,
    String agentRowId = '',
  }) {
    final length = messages.length;
    final lastId = length == 0 ? null : messages.last.id;
    final signature = _flowMetadataSignature(messages);
    if (length == _length &&
        lastId == _lastId &&
        scope == _scope &&
        agentRowId == _agentRowId &&
        metadataRevision == _metadataRevision &&
        signature == _metadataSignature) {
      return _origin;
    }
    _length = length;
    _lastId = lastId;
    _scope = scope;
    _agentRowId = agentRowId;
    _metadataRevision = metadataRevision;
    _metadataSignature = signature;
    scanCount++;
    _origin = flowSessionOriginOf(messages, agentRowId: agentRowId);
    return _origin;
  }
}

/// ChatScreen 顶部的一条轻量提示。不重建页面结构：只在消息列表上方多一行。
class FlowSessionBanner extends StatelessWidget {
  const FlowSessionBanner({super.key, required this.origin});

  final FlowSessionOrigin origin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.4),
      child: Row(
        children: [
          Icon(
            Icons.account_tree_outlined,
            size: 16,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.flow_sessionBanner(origin.label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton(
            key: const ValueKey('flow-session-view-run'),
            onPressed: () => unawaited(_openRun(context)),
            child: Text(l10n.flow_viewRun),
          ),
        ],
      ),
    );
  }

  Future<void> _openRun(BuildContext context) async {
    // A7-7：先看这条会话自己的来源主机，不要用「当前」主机去查别的主机发起
    // 的运行；拿不到来源才退回 activeHost。
    var peerId = origin.peerId.trim();
    if (peerId.isEmpty) {
      peerId = await resolveFlowOriginSourcePeer(origin.sourceAgentId);
    }
    if (peerId.isEmpty) {
      final activeHost = debugFlowActiveHost ?? HubFlow().activeHost;
      peerId = (await activeHost()).trim();
    }
    if (peerId.isEmpty || !context.mounted) return;
    final hook = debugOpenFlowRun;
    if (hook != null) {
      await hook(peerId, origin.runId);
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FlowRunScreen(peerId: peerId, runId: origin.runId),
    ));
  }
}
