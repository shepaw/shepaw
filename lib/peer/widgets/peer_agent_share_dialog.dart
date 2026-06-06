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

/// 内嵌用的 agent 分享勾选列表（供配对确认弹窗等场景复用）。
class PeerAgentShareSelector extends StatefulWidget {
  final List<PeerShareAgentEntry> agents;
  final Map<String, bool> initialSelection;
  final ValueChanged<Map<String, bool>> onChanged;

  const PeerAgentShareSelector({
    super.key,
    required this.agents,
    required this.initialSelection,
    required this.onChanged,
  });

  @override
  State<PeerAgentShareSelector> createState() => _PeerAgentShareSelectorState();
}

class _PeerAgentShareSelectorState extends State<PeerAgentShareSelector> {
  late Map<String, bool> _selected =
      Map<String, bool>.from(widget.initialSelection);

  bool get _allSelected =>
      widget.agents.isNotEmpty && _selected.values.every((v) => v);

  void _notify() => widget.onChanged(Map<String, bool>.from(_selected));

  void _toggleAll(bool value) {
    setState(() {
      for (final a in widget.agents) {
        _selected[a.id] = value;
      }
    });
    _notify();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _allSelected,
          onChanged: (v) => _toggleAll(v ?? false),
          title: const Text('全选'),
        ),
        const Divider(height: 1),
        ...widget.agents.map((agent) {
          return CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _selected[agent.id] ?? false,
            onChanged: (v) {
              setState(() => _selected[agent.id] = v ?? false);
              _notify();
            },
            secondary: _buildAvatar(agent.avatar),
            title: Text(agent.name),
            subtitle: (agent.bio != null && agent.bio!.isNotEmpty)
                ? Text(agent.bio!, maxLines: 1, overflow: TextOverflow.ellipsis)
                : null,
          );
        }),
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
