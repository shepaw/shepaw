import 'package:flutter/material.dart';

import '../../models/remote_agent.dart';
import '../../widgets/avatar_image.dart';

/// 一个可分享 agent 的条目（名称 + 头像 + 是否默认勾选）。
class PeerShareAgentEntry {
  final String id;
  final String name;
  final String avatar;
  final String? bio;
  final bool initiallyShared;

  const PeerShareAgentEntry({
    required this.id,
    required this.name,
    required this.avatar,
    this.bio,
    this.initiallyShared = true,
  });

  factory PeerShareAgentEntry.fromAgent(RemoteAgent agent,
      {bool initiallyShared = true}) {
    return PeerShareAgentEntry(
      id: agent.id,
      name: agent.name,
      avatar: agent.avatar,
      bio: agent.bio,
      initiallyShared: initiallyShared,
    );
  }
}

/// 让用户确认把哪些本机 agent 分享给某台配对设备。
///
/// 返回 agentId → 是否分享 的决定；用户取消/关闭时返回 null（不写入决定）。
Future<Map<String, bool>?> showPeerAgentShareDialog({
  required BuildContext context,
  required String deviceName,
  required List<PeerShareAgentEntry> agents,
}) {
  return showDialog<Map<String, bool>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _PeerAgentShareDialog(
      deviceName: deviceName,
      agents: agents,
    ),
  );
}

class _PeerAgentShareDialog extends StatefulWidget {
  final String deviceName;
  final List<PeerShareAgentEntry> agents;

  const _PeerAgentShareDialog({
    required this.deviceName,
    required this.agents,
  });

  @override
  State<_PeerAgentShareDialog> createState() => _PeerAgentShareDialogState();
}

class _PeerAgentShareDialogState extends State<_PeerAgentShareDialog> {
  late final Map<String, bool> _selected = {
    for (final a in widget.agents) a.id: a.initiallyShared,
  };

  bool get _allSelected => _selected.values.every((v) => v);

  void _toggleAll(bool value) {
    setState(() {
      for (final key in _selected.keys) {
        _selected[key] = value;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final sharedCount = _selected.values.where((v) => v).length;

    return AlertDialog(
      title: const Text('分享 Agent'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '设备「${widget.deviceName}」已连接。请选择要分享给它的 Agent，对方将能通过它使用你选中的 Agent。',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _allSelected,
              onChanged: (v) => _toggleAll(v ?? false),
              title: const Text('全选'),
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.agents.length,
                itemBuilder: (context, index) {
                  final agent = widget.agents[index];
                  return CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _selected[agent.id] ?? false,
                    onChanged: (v) =>
                        setState(() => _selected[agent.id] = v ?? false),
                    secondary: _buildAvatar(agent.avatar),
                    title: Text(agent.name),
                    subtitle: (agent.bio != null && agent.bio!.isNotEmpty)
                        ? Text(agent.bio!,
                            maxLines: 1, overflow: TextOverflow.ellipsis)
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(Map<String, bool>.from(_selected)),
          child: Text(sharedCount > 0 ? '分享所选 ($sharedCount)' : '都不分享'),
        ),
      ],
    );
  }

  Widget _buildAvatar(String avatar) {
    final isPath = (avatar.startsWith('/') && !avatar.startsWith('http')) ||
        avatar.startsWith('http') ||
        AvatarImage.isAsset(avatar);
    if (isPath) {
      return AvatarImage(
        avatar: avatar,
        size: 36,
        borderRadius: 9,
        fallback: const Icon(Icons.smart_toy_outlined),
      );
    }
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.indigo[50],
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(avatar.isNotEmpty ? avatar : '🤖',
          style: const TextStyle(fontSize: 18)),
    );
  }
}
