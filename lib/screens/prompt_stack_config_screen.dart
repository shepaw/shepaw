import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/prompt_stack_config.dart';
import '../widgets/form_bottom_bar.dart';

/// Full-page editor for [PromptStackConfig], persisted on the agent via the
/// caller (`metadata['prompt_stack_config']`).
class PromptStackConfigScreen extends StatefulWidget {
  final PromptStackConfig initial;
  final bool isShe;

  const PromptStackConfigScreen({
    super.key,
    required this.initial,
    required this.isShe,
  });

  @override
  State<PromptStackConfigScreen> createState() =>
      _PromptStackConfigScreenState();
}

class _PromptStackConfigScreenState extends State<PromptStackConfigScreen> {
  late PromptStackConfig _config;

  @override
  void initState() {
    super.initState();
    _config = widget.initial;
  }

  String _tr(String zh, String en) {
    final code = Localizations.localeOf(context).languageCode;
    return code.startsWith('zh') ? zh : en;
  }

  PromptStackConfig get _defaults =>
      widget.isShe ? PromptStackConfig.forShe : PromptStackConfig.forOtherAgent;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(_tr('提示词栈', 'Prompt Stack')),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: () {
              setState(() => _config = _defaults);
            },
            child: Text(_tr('恢复默认', 'Reset')),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                Text(
                  _tr(
                    '控制注入系统提示词的各层内容与工具文档。保存后写入 Agent 元数据。',
                    'Control which layers are injected into the system prompt. Saved into agent metadata.',
                  ),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                _sectionCard(
                  title: _tr('通用', 'General'),
                  children: [
                    _switch(
                      title: _tr('身份块', 'Identity'),
                      subtitle: _tr('Agent 名称身份提示', 'Agent name identity block'),
                      value: _config.includeIdentity,
                      onChanged: (v) => setState(
                        () => _config = _config.copyWith(includeIdentity: v),
                      ),
                    ),
                    _switch(
                      title: _tr('描述 / 人设', 'Description'),
                      subtitle: _tr(
                        'She 核心人设或其他 Agent 的 system_prompt',
                        'She core identity or agent system_prompt',
                      ),
                      value: _config.includeDescription,
                      onChanged: (v) => setState(
                        () => _config = _config.copyWith(includeDescription: v),
                      ),
                    ),
                    _switch(
                      title: _tr('会话自定义提示', 'Custom session prompt'),
                      subtitle: _tr(
                        'DM 频道用户自定义 system prompt',
                        'Per-DM channel custom system prompt',
                      ),
                      value: _config.includeCustomPrompt,
                      onChanged: (v) => setState(
                        () =>
                            _config = _config.copyWith(includeCustomPrompt: v),
                      ),
                    ),
                    _switch(
                      title: _tr('轻量模式', 'Lightweight mode'),
                      subtitle: _tr(
                        '强制 Soul/记忆为仅 URI，并减少认知块以省 token',
                        'Force Soul/memory to URI-only and skip heavy blocks',
                      ),
                      value: _config.lightweightMode,
                      onChanged: (v) => setState(
                        () => _config = _config.copyWith(lightweightMode: v),
                      ),
                    ),
                    if (!widget.isShe) ...[
                      _dropdown(
                        label: _tr('Soul 注入', 'Soul inject'),
                        value: _config.soulInjectMode,
                        items: {
                          CognitionInjectMode.full: _tr(
                            '全文内嵌（默认）',
                            'Embed full text (default)',
                          ),
                          CognitionInjectMode.uriOnly: _tr(
                            '仅 URI（按需 store read）',
                            'URI only (store read on demand)',
                          ),
                        },
                        onChanged: (v) {
                          if (v == null) return;
                          setState(
                            () => _config =
                                _config.copyWith(soulInjectMode: v),
                          );
                        },
                      ),
                      _dropdown(
                        label: _tr('记忆注入', 'Memory inject'),
                        value: _config.memoryInjectMode,
                        items: {
                          CognitionInjectMode.full: _tr(
                            '内嵌最近 N 条（默认）',
                            'Embed recent N (default)',
                          ),
                          CognitionInjectMode.uriOnly: _tr(
                            '仅 URI（按需读取）',
                            'URI only (read on demand)',
                          ),
                        },
                        onChanged: (v) {
                          if (v == null) return;
                          setState(
                            () => _config =
                                _config.copyWith(memoryInjectMode: v),
                          );
                        },
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 12),
                _sectionCard(
                  title: _tr('工具层', 'Tools'),
                  children: [
                    _switch(
                      title: 'UI tools',
                      subtitle: _tr(
                        '确认卡、选择器等交互组件',
                        'Confirmation cards, selectors, etc.',
                      ),
                      value: _config.tools.includeUI,
                      onChanged: (v) => setState(
                        () => _config = _config.copyWith(
                          tools: _config.tools.copyWith(includeUI: v),
                        ),
                      ),
                    ),
                    _switch(
                      title: 'OS tools',
                      subtitle: _tr('本机文件 / shell 等', 'Local file / shell tools'),
                      value: _config.tools.includeOsTools,
                      onChanged: (v) => setState(
                        () => _config = _config.copyWith(
                          tools: _config.tools.copyWith(includeOsTools: v),
                        ),
                      ),
                    ),
                    if (!widget.isShe && _config.tools.includeOsTools)
                      _dropdown(
                        label: _tr('OS 工具文档模式', 'OS tools docs mode'),
                        value: _config.tools.osToolsMode,
                        items: const {
                          'cli_reference': 'cli_reference',
                          'expanded': 'expanded',
                        },
                        onChanged: (v) {
                          if (v == null) return;
                          setState(
                            () => _config = _config.copyWith(
                              tools: _config.tools.copyWith(osToolsMode: v),
                            ),
                          );
                        },
                      ),
                    if (_config.tools.osToolsMode == 'expanded' || widget.isShe)
                      _dropdown(
                        label: _tr('工具描述详细度', 'Tool description level'),
                        value: _config.tools.toolDescriptionLevel,
                        items: const {
                          'names_only': 'names_only',
                          'summary': 'summary',
                          'full': 'full',
                        },
                        onChanged: (v) {
                          if (v == null) return;
                          setState(
                            () => _config = _config.copyWith(
                              tools: _config.tools
                                  .copyWith(toolDescriptionLevel: v),
                            ),
                          );
                        },
                      ),
                    _switch(
                      title: 'Skills',
                      value: _config.tools.includeSkills,
                      onChanged: (v) => setState(
                        () => _config = _config.copyWith(
                          tools: _config.tools.copyWith(includeSkills: v),
                        ),
                      ),
                    ),
                    _switch(
                      title: 'Tool models',
                      value: _config.tools.includeToolModels,
                      onChanged: (v) => setState(
                        () => _config = _config.copyWith(
                          tools: _config.tools.copyWith(includeToolModels: v),
                        ),
                      ),
                    ),
                    _switch(
                      title: 'shepaw CLI tool',
                      subtitle: _tr(
                        '作为可调用 function tool 注入',
                        'Inject shepaw as a callable function tool',
                      ),
                      value: _config.tools.includeShepawCli,
                      onChanged: (v) => setState(
                        () => _config = _config.copyWith(
                          tools: _config.tools.copyWith(includeShepawCli: v),
                        ),
                      ),
                    ),
                    if (!widget.isShe)
                      _switch(
                        title: 'shepaw meta CLI guidance',
                        subtitle: _tr(
                          '非 She：提示可用 meta/tools 自发现',
                          'Non-She: meta/tools self-discovery guidance',
                        ),
                        value: _config.tools.includeShepawMetaCli,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            tools: _config.tools
                                .copyWith(includeShepawMetaCli: v),
                          ),
                        ),
                      ),
                  ],
                ),
                if (widget.isShe) ...[
                  const SizedBox(height: 12),
                  _sectionCard(
                    title: _tr('She 灵宠层', 'She spirit pet'),
                    children: [
                      _switch(
                        title: _tr('She 记忆', 'She memory'),
                        value: _config.she.includeSheMemory,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she: _config.she.copyWith(includeSheMemory: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: _tr('自我认知', 'Self cognition'),
                        value: _config.she.includeSheSelfCognition,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she: _config.she
                                .copyWith(includeSheSelfCognition: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: _tr('用户认知', 'User cognition'),
                        value: _config.she.includeUserCognition,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she: _config.she.copyWith(includeUserCognition: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: _tr('用户理解策略', 'User strategy'),
                        value: _config.she.includeUserStrategy,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she: _config.she.copyWith(includeUserStrategy: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: _tr('用户画像快照', 'Profile snapshot'),
                        value: _config.she.includeProfileSnapshot,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she:
                                _config.she.copyWith(includeProfileSnapshot: v),
                          ),
                        ),
                      ),
                      if (_config.she.includeProfileSnapshot)
                        _dropdown(
                          label: _tr('画像详细度', 'Snapshot level'),
                          value: _config.she.profileSnapshotLevel,
                          items: const {
                            'core': 'core',
                            'extended': 'extended',
                            'full': 'full',
                          },
                          onChanged: (v) {
                            if (v == null) return;
                            setState(
                              () => _config = _config.copyWith(
                                she: _config.she
                                    .copyWith(profileSnapshotLevel: v),
                              ),
                            );
                          },
                        ),
                      _switch(
                        title: _tr('初次见面指引', 'First meeting'),
                        value: _config.she.includeFirstMeeting,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she: _config.she.copyWith(includeFirstMeeting: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: _tr('会话结束写回', 'Session-end writeback'),
                        value: _config.she.includeSessionEnd,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she: _config.she.copyWith(includeSessionEnd: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: _tr('元认知能力索引', 'Meta cognition'),
                        value: _config.she.includeMetaCognition,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she: _config.she.copyWith(includeMetaCognition: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: _tr('1:1 工作流/建群 playbook', 'DM playbooks'),
                        subtitle: _tr(
                          '默认关闭；复杂请求用 shepaw workflow / group --help',
                          'Off by default; discover via shepaw workflow / group --help',
                        ),
                        value: _config.she.includeDmPlaybooks,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she: _config.she.copyWith(includeDmPlaybooks: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: _tr('Agent 花名册', 'Agents roster'),
                        value: _config.she.includeAgentsRoster,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she: _config.she.copyWith(includeAgentsRoster: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: _tr('跨设备摘要', 'Paired-device digests'),
                        value: _config.she.includeExternalDigests,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she:
                                _config.she.copyWith(includeExternalDigests: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: _tr('CLI 摘要模式', 'CLI summary mode'),
                        value: _config.she.shepawCliSummaryMode,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she:
                                _config.she.copyWith(shepawCliSummaryMode: v),
                          ),
                        ),
                      ),
                      const Divider(height: 24),
                      Text(
                        _tr('shepaw 子命令文档开关', 'shepaw command docs'),
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      _switch(
                        title: 'profile',
                        value: _config.she.enableProfileCommand,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she: _config.she.copyWith(enableProfileCommand: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: 'memory',
                        value: _config.she.enableMemoryCommand,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she: _config.she.copyWith(enableMemoryCommand: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: 'agents chat',
                        value: _config.she.enableAgentChatCommand,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she:
                                _config.she.copyWith(enableAgentChatCommand: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: 'messages',
                        value: _config.she.enableMessagesCommand,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            she: _config.she.copyWith(enableMessagesCommand: v),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                if (!widget.isShe) ...[
                  const SizedBox(height: 12),
                  _sectionCard(
                    title: _tr('Agent 上下文层', 'Agent context'),
                    children: [
                      _switch(
                        title: _tr('用户简介', 'User profile'),
                        value: _config.agent.includeUserProfile,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            agent:
                                _config.agent.copyWith(includeUserProfile: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: _tr('Agent 记忆', 'Agent memory'),
                        value: _config.agent.includeAgentMemory,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            agent:
                                _config.agent.copyWith(includeAgentMemory: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: _tr('自我认知', 'Self cognition'),
                        value: _config.agent.includeAgentSelfCognition,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            agent: _config.agent
                                .copyWith(includeAgentSelfCognition: v),
                          ),
                        ),
                      ),
                      _switch(
                        title: _tr('用户认知', 'User cognition'),
                        value: _config.agent.includeAgentUserCognition,
                        onChanged: (v) => setState(
                          () => _config = _config.copyWith(
                            agent: _config.agent
                                .copyWith(includeAgentUserCognition: v),
                          ),
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_tr('记忆条数上限', 'Memory limit')),
                        subtitle: Text('${_config.agent.memoryLimit}'),
                        trailing: SizedBox(
                          width: 140,
                          child: Slider(
                            min: 0,
                            max: 50,
                            divisions: 50,
                            value: _config.agent.memoryLimit
                                .clamp(0, 50)
                                .toDouble(),
                            label: '${_config.agent.memoryLimit}',
                            onChanged: (v) => setState(
                              () => _config = _config.copyWith(
                                agent: _config.agent
                                    .copyWith(memoryLimit: v.round()),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          FormBottomBar(
            child: FormPrimaryButton(
              onPressed: () => Navigator.pop(context, _config),
              icon: Icons.save,
              label: l10n.common_save,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required List<Widget> children,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _switch({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _dropdown({
    required String label,
    required String value,
    required Map<String, String> items,
    required ValueChanged<String?> onChanged,
  }) {
    final safeValue = items.containsKey(value) ? value : items.keys.first;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            isExpanded: true,
            value: safeValue,
            items: items.entries
                .map(
                  (e) => DropdownMenuItem(
                    value: e.key,
                    child: Text(e.value),
                  ),
                )
                .toList(),
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }
}
