import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../models/message.dart';
import '../../peer/services/hub_flow.dart';
import '../../screens/flow_run_screen.dart';

/// 从会话里的某条消息上认出「这是工作流发起的会话」。
///
/// 主机给流程 prompt 打的 `metadata.flow = {run_id, node_key, attempt}` 会随
/// `message.created` 一起落库；不需要新的协议字段，也不用记一张节点映射表。
class FlowSessionOrigin {
  const FlowSessionOrigin({required this.runId, required this.nodeKey});

  final String runId;
  final String nodeKey;

  /// 横幅上只显示最后一段节点 id，完整 key（`outer/inner`）太长。
  String get label => nodeKey.isEmpty ? runId : nodeKey.split('/').last;
}

FlowSessionOrigin? flowSessionOriginOf(Iterable<Message> messages) {
  for (final message in messages) {
    final flow = message.metadata?['flow'];
    if (flow is! Map) continue;
    final runId = flow['run_id']?.toString() ?? '';
    if (runId.isEmpty) continue;
    return FlowSessionOrigin(
      runId: runId,
      nodeKey: flow['node_key']?.toString() ?? '',
    );
  }
  return null;
}

/// 会话级缓存：消息列表没变就不重复全量扫描。
///
/// 聊天页每次重建（抽屉拖动、键盘、流式通知）都会调到这里。长 DM 里
/// [flowSessionOriginOf] 每次从头扫到尾纯属浪费；只有列表长度、最后一条 id
/// 或频道变了才可能影响结果。
class FlowSessionOriginCache {
  FlowSessionOrigin? _origin;
  int _length = -1;
  String? _lastId;
  String _scope = '';

  /// 真正重新扫描的次数（测试用来确认缓存生效）。
  int scanCount = 0;

  FlowSessionOrigin? resolve(
    List<Message> messages, {
    String scope = '',
  }) {
    final length = messages.length;
    final lastId = length == 0 ? null : messages.last.id;
    if (length == _length && lastId == _lastId && scope == _scope) {
      return _origin;
    }
    _length = length;
    _lastId = lastId;
    _scope = scope;
    scanCount++;
    _origin = flowSessionOriginOf(messages);
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
    final peerId = await HubFlow().activeHost();
    if (peerId.isEmpty || !context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => FlowRunScreen(peerId: peerId, runId: origin.runId),
    ));
  }
}
