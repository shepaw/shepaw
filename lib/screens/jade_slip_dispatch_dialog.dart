import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/jade_slip.dart';
import '../models/remote_agent.dart';
import '../service_locator.dart';
import '../services/chat_service.dart';
import '../services/local_database_service.dart';
import '../services/local_user_identity.dart';
import '../services/she_service.dart';
import '../theme/app_theme.dart';
import '../utils/session_utils.dart';
import '../widgets/agent_list_avatar.dart';
import 'jade_slip_agent_picker.dart';
import 'jade_slip_dispatch.dart';

/// 确认弹层的结果：派给谁 + 派到哪条会话。
class JadeSlipDispatchChoice {
  const JadeSlipDispatchChoice({
    required this.agentId,
    required this.agentName,
    required this.avatar,
    required this.sessionTarget,
    this.channelId,
  });

  final String agentId;
  final String agentName;
  final String avatar;
  final JadeSlipSessionTarget sessionTarget;

  /// 仅 [JadeSlipSessionTarget.specific] 时非空。
  final String? channelId;
}

/// 派发前的确认弹层：目标 Agent、执行范围、目标会话都可改后确认。
///
/// 返回 null 表示用户取消。Agent 为空（玉简没指派）时原样返回空 id，
/// [dispatchJadeSlip] 会自己弹 Agent 选择器兜底。
Future<JadeSlipDispatchChoice?> showJadeSlipDispatchDialog(
  BuildContext context, {
  required JadeSlip slip,
  required List<RemoteAgent> agents,
  JadeSlipItem? focusItem,
}) {
  return showDialog<JadeSlipDispatchChoice>(
    context: context,
    builder: (_) => _JadeSlipDispatchDialog(
      slip: slip,
      agents: agents,
      focusItem: focusItem,
    ),
  );
}

class _JadeSlipDispatchDialog extends StatefulWidget {
  const _JadeSlipDispatchDialog({
    required this.slip,
    required this.agents,
    this.focusItem,
  });

  final JadeSlip slip;
  final List<RemoteAgent> agents;

  /// 非空表示只派发这一项（清单项菜单入口）。
  final JadeSlipItem? focusItem;

  @override
  State<_JadeSlipDispatchDialog> createState() =>
      _JadeSlipDispatchDialogState();
}

class _JadeSlipDispatchDialogState extends State<_JadeSlipDispatchDialog> {
  String? _pickedAgentId;
  String? _pickedAgentName;
  String? _pickedAvatar;

  JadeSlipSessionTarget _target = JadeSlipSessionTarget.current;
  String? _channelId;
  String? _latestChannelId;
  List<_SessionOption> _sessions = const [];
  bool _loadingSessions = false;

  String get _agentId => _pickedAgentId ?? widget.slip.assigneeAgentId;

  /// 当前选中的 Agent（id / 显示名 / 头像）。She 用本地化名，其余查列表。
  ({String id, String name, String avatar}) _agent(AppLocalizations l10n) {
    final id = _agentId;
    if (_pickedAgentId != null) {
      return (id: id, name: _pickedAgentName ?? id, avatar: _pickedAvatar ?? '');
    }
    if (id == SheService.sheId) {
      return (id: id, name: l10n.she_name, avatar: SheService.sheAvatar);
    }
    for (final agent in widget.agents) {
      if (agent.id == id) {
        return (id: id, name: agent.name, avatar: agent.avatar);
      }
    }
    return (
      id: id,
      name: id.isEmpty ? l10n.jadeSlip_assigneeNone : id,
      avatar: '',
    );
  }

  /// 交给 Agent 的范围：单项 / 待办 N 项 / 全部内容。
  String _scopeLabel(AppLocalizations l10n) {
    final slip = widget.slip;
    final focus = widget.focusItem;
    if (focus != null) return l10n.jadeSlip_handOffScopeItem(focus.text);
    if (slip.items.isEmpty) return l10n.jadeSlip_handOffScopeNoItems;
    final open = slip.openItems.length;
    return open == slip.itemCount
        ? l10n.jadeSlip_handOffScopeAll(slip.itemCount)
        : l10n.jadeSlip_handOffScopeOpen(open, slip.itemCount);
  }

  Future<void> _loadSessions(String agentId) async {
    setState(() => _loadingSessions = true);
    final chat = getIt<ChatService>();
    const userId = LocalUserIdentity.id;
    late final List<_SessionOption> options;
    String? latest;
    try {
      final channels = await chat.getAgentSessions(agentId: agentId);
      final times = await LocalDatabaseService()
          .getLatestMessageTimesByChannels(
        channels.map((c) => c.id).toList(),
      );
      latest = await chat.getLatestActiveChannelId(userId, agentId);
      options = [
        for (final c in channels)
          _SessionOption(channelId: c.id, lastAt: times[c.id]),
      ];
    } catch (_) {
      options = const [];
    }
    if (!mounted) return;
    setState(() {
      _sessions = options;
      _latestChannelId = latest;
      _loadingSessions = false;
      // 默认选最近活跃的那条，没有就选第一条。
      final preferred = options.any((o) => o.channelId == latest)
          ? latest
          : options.isEmpty
              ? null
              : options.first.channelId;
      if (_channelId == null || !options.any((o) => o.channelId == _channelId)) {
        _channelId = preferred;
      }
    });
  }

  void _selectTarget(JadeSlipSessionTarget target) {
    setState(() => _target = target);
    if (target == JadeSlipSessionTarget.specific &&
        _sessions.isEmpty &&
        !_loadingSessions) {
      unawaited(_loadSessions(_agentId));
    }
  }

  Future<void> _pickAgent() async {
    final picked = await showJadeSlipAgentPicker(
      context,
      agents: widget.agents,
      currentAgentId: _agentId,
    );
    if (picked == null || picked.id.isEmpty || !mounted) return;
    setState(() {
      _pickedAgentId = picked.id;
      _pickedAgentName = picked.name;
      _pickedAvatar = picked.avatar;
      // 换了 Agent，历史会话与已选会话都失效。
      _sessions = const [];
      _channelId = null;
      _latestChannelId = null;
    });
    if (_target == JadeSlipSessionTarget.specific) {
      unawaited(_loadSessions(picked.id));
    }
  }

  void _confirm() {
    final agent = _agent(AppLocalizations.of(context));
    Navigator.pop(
      context,
      JadeSlipDispatchChoice(
        agentId: agent.id,
        agentName: agent.name,
        avatar: agent.avatar,
        sessionTarget: _target,
        channelId:
            _target == JadeSlipSessionTarget.specific ? _channelId : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final agent = _agent(l10n);

    return AlertDialog(
      title: Text(l10n.jadeSlip_handOffTitle),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label(l10n.jadeSlip_handOffAgent, theme, scheme),
              const SizedBox(height: 6),
              _agentRow(agent, l10n, theme, scheme),
              const SizedBox(height: 16),
              _label(l10n.jadeSlip_handOffScope, theme, scheme),
              const SizedBox(height: 6),
              Text(
                _scopeLabel(l10n),
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
              ),
              const SizedBox(height: 16),
              _label(l10n.jadeSlip_handOffSession, theme, scheme),
              const SizedBox(height: 6),
              _sessionOption(
                label: l10n.jadeSlip_sessionCurrent,
                hint: l10n.jadeSlip_sessionCurrentHint,
                selected: _target == JadeSlipSessionTarget.current,
                onTap: () => _selectTarget(JadeSlipSessionTarget.current),
                theme: theme,
                scheme: scheme,
              ),
              _sessionOption(
                label: l10n.jadeSlip_sessionFresh,
                hint: l10n.jadeSlip_sessionFreshHint,
                selected: _target == JadeSlipSessionTarget.fresh,
                onTap: () => _selectTarget(JadeSlipSessionTarget.fresh),
                theme: theme,
                scheme: scheme,
              ),
              _sessionOption(
                label: l10n.jadeSlip_sessionPick,
                hint: l10n.jadeSlip_sessionPickHint,
                selected: _target == JadeSlipSessionTarget.specific,
                onTap: () => _selectTarget(JadeSlipSessionTarget.specific),
                theme: theme,
                scheme: scheme,
              ),
              if (_target == JadeSlipSessionTarget.specific) ...[
                const SizedBox(height: 4),
                _sessionList(l10n, theme, scheme),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.common_cancel),
        ),
        FilledButton(
          onPressed: _confirm,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
          ),
          child: Text(l10n.jadeSlip_run),
        ),
      ],
    );
  }

  Widget _label(String text, ThemeData theme, ColorScheme scheme) => Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
      );

  Widget _agentRow(
    ({String id, String name, String avatar}) agent,
    AppLocalizations l10n,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    final hasAgent = agent.id.isNotEmpty;
    return Row(
      children: [
        AgentListAvatar(avatar: agent.avatar, name: agent.name, size: 32),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            agent.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(
              fontWeight: FontWeight.w500,
              color: hasAgent ? scheme.onSurface : scheme.onSurfaceVariant,
            ),
          ),
        ),
        TextButton(
          onPressed: () => unawaited(_pickAgent()),
          child: Text(l10n.common_modify),
        ),
      ],
    );
  }

  Widget _sessionOption({
    required String label,
    required String hint,
    required bool selected,
    required VoidCallback onTap,
    required ThemeData theme,
    required ColorScheme scheme,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 18,
              color: selected ? AppColors.primary : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  Text(
                    hint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sessionList(
    AppLocalizations l10n,
    ThemeData theme,
    ColorScheme scheme,
  ) {
    if (_loadingSessions) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_sessions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          l10n.jadeSlip_sessionEmpty,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final option in _sessions)
            InkWell(
              onTap: () => setState(() => _channelId = option.channelId),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
                child: Row(
                  children: [
                    Icon(
                      option.channelId == _channelId
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 16,
                      color: option.channelId == _channelId
                          ? AppColors.primary
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      SessionUtils.shortSessionId(option.channelId),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (option.channelId == _latestChannelId) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          l10n.jadeSlip_sessionCurrentTag,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 10,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ],
                    const Spacer(),
                    Text(
                      _sessionTime(option.lastAt, l10n),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _sessionTime(DateTime? at, AppLocalizations l10n) {
    if (at == null) return l10n.jadeSlip_sessionNoMessage;
    final now = DateTime.now();
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    if (at.year == now.year && at.month == now.month && at.day == now.day) {
      return '$hh:$mm';
    }
    return '${at.month}/${at.day} $hh:$mm';
  }
}

class _SessionOption {
  const _SessionOption({required this.channelId, required this.lastAt});

  final String channelId;
  final DateTime? lastAt;
}
