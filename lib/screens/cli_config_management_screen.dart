import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../clis/cli_base.dart';
import '../clis/shepaw/shepaw_cli.dart' show ShepawCLI;
import '../clis/shepaw/context/context_namespace.dart';
import '../clis/shepaw/chat/chat_namespace.dart';
import '../clis/shepaw/tools_namespace.dart';
import '../clis/shepaw/skills_namespace.dart';
import '../clis/shepaw/meta/meta_namespace.dart';
import '../clis/shepaw/help_namespace.dart';
import '../clis/shepaw/os/os_cli_namespace.dart';
import '../clis/shepaw/context/context_namespace.dart' show ContextNamespace;
import '../models/cli_command_config.dart';
import '../models/cli_config_field.dart';
import '../models/tool_config.dart';
import '../services/cli_command_config_service.dart';
import '../services/os_tool_registry.dart';
import '../services/tool_config_service.dart';

// ─── 顶层命名空间描述 ──────────────────────────────────────────────────────────

class _NsDef {
  final String key;
  final String label;
  final String description;
  final IconData icon;
  final CliNamespace ns;

  const _NsDef({
    required this.key,
    required this.label,
    required this.description,
    required this.icon,
    required this.ns,
  });
}

List<_NsDef> get _topNamespaces => [
      _NsDef(
        key: 'context',
        label: 'Context',
        description: "She's internal state — profile, memory, agents",
        icon: Icons.account_circle_outlined,
        ns: ContextNamespace.instance,
      ),
      _NsDef(
        key: 'chat',
        label: 'Communication',
        description: 'Channels and message history',
        icon: Icons.chat_bubble_outline,
        ns: ChatNamespace.instance,
      ),
      _NsDef(
        key: 'tools',
        label: 'Tooling',
        description: 'Network and web tools',
        icon: Icons.build_outlined,
        ns: ToolsNamespace.instance,
      ),
      _NsDef(
        key: 'os',
        label: 'OS',
        description: 'Local OS tools — shell, file, app, clipboard, process',
        icon: Icons.computer_outlined,
        ns: OsCliNamespace.instance,
      ),
      _NsDef(
        key: 'skills',
        label: 'Skills',
        description: 'Loaded LLM skill library',
        icon: Icons.extension_outlined,
        ns: SkillsNamespace.instance,
      ),
      _NsDef(
        key: 'meta',
        label: 'Meta',
        description: 'System info and datetime utilities',
        icon: Icons.info_outlined,
        ns: MetaNamespace.instance,
      ),
      _NsDef(
        key: 'help',
        label: 'Help',
        description: 'Full CLI reference and examples',
        icon: Icons.help_outline,
        ns: HelpNamespace.instance,
      ),
    ];

// ─── 共享辅助 ──────────────────────────────────────────────────────────────────

IconData _toolIconFor(String toolName) => switch (toolName) {
      'shell_exec' => Icons.terminal,
      'system_info' => Icons.info_outline,
      'file_read' => Icons.description,
      'file_write' => Icons.edit_document,
      'file_delete' => Icons.delete_outline,
      'file_move' => Icons.drive_file_move_outline,
      'file_list' => Icons.folder_open,
      'web_search' => Icons.search,
      'web_fetch' => Icons.download,
      'url_open' => Icons.open_in_browser,
      'app_open' => Icons.apps,
      'screenshot' => Icons.screenshot_monitor,
      'clipboard_read' => Icons.content_paste,
      'clipboard_write' => Icons.content_copy,
      'process_list' => Icons.list_alt,
      'process_kill' => Icons.cancel_outlined,
      'applescript_exec' => Icons.code,
      _ => Icons.settings_outlined,
    };

dynamic _parseParamValue(String raw) {
  if (raw == 'true') return true;
  if (raw == 'false') return false;
  final intVal = int.tryParse(raw);
  if (intVal != null) return intVal;
  final doubleVal = double.tryParse(raw);
  if (doubleVal != null) return doubleVal;
  return raw;
}

// ── 判断某个命名空间是否是 Tooling（有工具配置管理）──────────────────────────
bool _isToolNamespace(CliNamespace ns) => ns is ToolsNamespace;

// ── 共享帮助对话框 ───────────────────────────────────────────────────────────────
/// 执行 --help 命令并在底部面板中显示帮助信息
Future<void> _showHelpSheet({
  required BuildContext context,
  required String namespace,
  String subcommand = '',
  required String title,
}) async {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _HelpSheet(
      namespace: namespace,
      subcommand: subcommand,
      title: title,
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Root Screen — Top-level namespace list
// ═══════════════════════════════════════════════════════════════════════════════

class CliConfigManagementScreen extends StatelessWidget {
  const CliConfigManagementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final defs = _topNamespaces;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.terminal, size: 20, color: colorScheme.primary),
            const SizedBox(width: 8),
            const Text('CLI Management'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline, size: 20),
            tooltip: 'shepaw help',
            onPressed: () => _showHelpSheet(
              context: context,
              namespace: 'help',
              title: 'ShepawCLI',
            ),
          ),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: defs.length,
        separatorBuilder: (_, __) => Divider(
          height: 1,
          indent: 16,
          endIndent: 16,
          color: colorScheme.outlineVariant,
        ),
        itemBuilder: (context, i) => _RootNsTile(def: defs[i]),
      ),
    );
  }
}

class _RootNsTile extends StatefulWidget {
  final _NsDef def;
  const _RootNsTile({required this.def});

  @override
  State<_RootNsTile> createState() => _RootNsTileState();
}

class _RootNsTileState extends State<_RootNsTile> {
  CliCommandConfig? _nsConfig;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final cfg = await CliCommandConfigService.instance.getConfig(widget.def.key);
    if (mounted) setState(() => _nsConfig = cfg);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final def = widget.def;

    // 计算条目数（命令数或子命名空间数）
    final cmdCount = def.ns.commands.length;
    final subNsCount = def.ns.subNamespaces.length;
    final countLabel = subNsCount > 0
        ? '$subNsCount namespaces'
        : '$cmdCount commands';

    final globalEnabled = _nsConfig?.globalEnabled ?? true;
    final sheOnly = _nsConfig?.sheOnly ?? false;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer
              .withValues(alpha: globalEnabled ? 1 : 0.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(def.icon, size: 20, color: colorScheme.onPrimaryContainer
            .withValues(alpha: globalEnabled ? 1 : 0.4)),
      ),
      title: Row(
        children: [
          Text(
            def.label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: globalEnabled ? colorScheme.onSurface : colorScheme.outline,
            ),
          ),
          if (!globalEnabled || sheOnly) ...[
            const SizedBox(width: 6),
            _NsStatusBadges(globalEnabled: globalEnabled, sheOnly: sheOnly),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            def.description,
            style: TextStyle(fontSize: 12, color: colorScheme.outline),
          ),
          const SizedBox(height: 2),
          Text(
            'shepaw ${def.key}',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: colorScheme.primary.withValues(alpha: 0.75),
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              countLabel,
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 2),
          IconButton(
            icon: Icon(Icons.settings_outlined, size: 18, color: colorScheme.outline),
            tooltip: 'Namespace Settings',
            visualDensity: VisualDensity.compact,
            onPressed: () async {
              await _NsConfigSheet.show(
                context: context,
                nsId: def.key,
                label: def.label,
                description: def.description,
                icon: def.icon,
              );
              _loadConfig();
            },
          ),
          Icon(Icons.chevron_right, color: colorScheme.outline),
        ],
      ),
      onTap: () {
        final isLeaf =
            def.ns.commands.isEmpty && def.ns.subNamespaces.isEmpty;
        if (isLeaf) {
          _CliDetailSheet.showForNamespace(
            context: context,
            nsKey: def.key,
            label: def.label,
            ns: def.ns,
          );
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => _NsPage(def: def)),
          ).then((_) => _loadConfig());
        }
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Generic Namespace Page
// Shows sub-namespaces (if any) then commands (if any)
// ═══════════════════════════════════════════════════════════════════════════════

class _NsPage extends StatefulWidget {
  final _NsDef def;
  const _NsPage({super.key, required this.def});

  @override
  State<_NsPage> createState() => _NsPageState();
}

class _NsPageState extends State<_NsPage> {
  // Only needed for tool commands
  final _service = ToolConfigService.instance;
  Map<String, ToolConfig> _configs = {};
  bool _loading = true;

  // 命名空间级别配置
  CliCommandConfig? _nsConfig;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() => _loading = true);
    final configs = await _service.getAllToolConfigs();
    final nsConfig = await CliCommandConfigService.instance.getConfig(widget.def.key);
    if (mounted) {
      setState(() {
        _configs = {for (final c in configs) c.toolName: c};
        _nsConfig = nsConfig;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final ns = widget.def.ns;
    final subNs = ns.subNamespaces;
    final cmds = ns.commands;
    final isTool = _isToolNamespace(ns);

    final nsGlobalEnabled = _nsConfig?.globalEnabled ?? true;
    final nsSheOnly = _nsConfig?.sheOnly ?? false;

    if (_loading && isTool) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.def.label)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.def.label),
            if (!nsGlobalEnabled || nsSheOnly) ...[
              const SizedBox(width: 8),
              _NsStatusBadges(globalEnabled: nsGlobalEnabled, sheOnly: nsSheOnly),
            ],
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline, size: 20),
            tooltip: 'shepaw ${widget.def.key} --help',
            onPressed: () => _showHelpSheet(
              context: context,
              namespace: widget.def.key,
              title: widget.def.label,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            tooltip: 'Namespace Settings',
            onPressed: () async {
              await _NsConfigSheet.show(
                context: context,
                nsId: widget.def.key,
                label: widget.def.label,
                description: widget.def.description,
                icon: widget.def.icon,
              );
              _loadAll();
            },
          ),
          if (isTool)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
              onPressed: _loadAll,
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadAll,
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            // ── 当前命名空间自身的限制横幅 ──────────────────────────────
            if (!nsGlobalEnabled || nsSheOnly)
              _AncestorRestrictionBanner(
                restrictingId: widget.def.key,
                restrictingConfig: _nsConfig!,
              ),
            // ── 子命名空间区块 ──────────────────────────────────────────────
            if (subNs.isNotEmpty) ...[
              _SectionHeader(label: 'Namespaces', colorScheme: colorScheme),
              ...subNs.entries.map((e) => _SubNsTile(
                    parentKey: widget.def.key,
                    subKey: e.key,
                    subNs: e.value,
                    configs: _configs,
                    onRefresh: _loadAll,
                  )),
            ],

            // ── 扁平命令区块 ────────────────────────────────────────────────
            if (cmds.isNotEmpty) ...[
              if (subNs.isNotEmpty)
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: colorScheme.outlineVariant,
                ),
              _SectionHeader(label: 'Commands', colorScheme: colorScheme),
              ...cmds.entries.map((e) => _CommandTile(
                    nsKey: widget.def.key,
                    cmd: e.value,
                    configs: _configs,
                    onRefresh: _loadAll,
                  )),
            ],
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Sub-namespace tile — navigates to a sub-namespace page
// ═══════════════════════════════════════════════════════════════════════════════

class _SubNsTile extends StatefulWidget {
  final String parentKey;
  final String subKey;
  final CliNamespace subNs;
  final Map<String, ToolConfig> configs;
  final VoidCallback onRefresh;

  const _SubNsTile({
    required this.parentKey,
    required this.subKey,
    required this.subNs,
    required this.configs,
    required this.onRefresh,
  });

  @override
  State<_SubNsTile> createState() => _SubNsTileState();
}

class _SubNsTileState extends State<_SubNsTile> {
  CliCommandConfig? _nsConfig;

  String get _nsId => '${widget.parentKey}.${widget.subKey}';

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final cfg = await CliCommandConfigService.instance.getConfig(_nsId);
    if (mounted) setState(() => _nsConfig = cfg);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final cmdCount = widget.subNs.commands.length;
    final subNsCount = widget.subNs.subNamespaces.length;
    final countLabel =
        subNsCount > 0 ? '$subNsCount namespaces' : '$cmdCount commands';

    // 选取图标
    final icon = _subNsIcon(widget.subKey);
    final globalEnabled = _nsConfig?.globalEnabled ?? true;
    final sheOnly = _nsConfig?.sheOnly ?? false;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: colorScheme.secondaryContainer
              .withValues(alpha: globalEnabled ? 1 : 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child:
            Icon(icon, size: 18, color: colorScheme.onSecondaryContainer
                .withValues(alpha: globalEnabled ? 1 : 0.4)),
      ),
      title: Row(
        children: [
          Text(
            _capitalize(widget.subKey),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: globalEnabled ? colorScheme.onSurface : colorScheme.outline,
            ),
          ),
          if (!globalEnabled || sheOnly) ...[
            const SizedBox(width: 6),
            _NsStatusBadges(globalEnabled: globalEnabled, sheOnly: sheOnly),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 1),
          Text(
            widget.subNs.description,
            style: TextStyle(fontSize: 12, color: colorScheme.outline),
          ),
          const SizedBox(height: 1),
          Text(
            'shepaw ${widget.parentKey} ${widget.subKey}.*',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: colorScheme.primary.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              countLabel,
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 2),
          IconButton(
            icon: Icon(Icons.settings_outlined, size: 16, color: colorScheme.outline),
            tooltip: 'Sub-namespace Settings',
            visualDensity: VisualDensity.compact,
            onPressed: () async {
              await _NsConfigSheet.show(
                context: context,
                nsId: _nsId,
                label: _capitalize(widget.subKey),
                description: widget.subNs.description,
                icon: icon,
              );
              _loadConfig();
            },
          ),
          Icon(Icons.chevron_right, size: 18, color: colorScheme.outline),
        ],
      ),
      onTap: () {
        final isLeaf =
            widget.subNs.commands.isEmpty && widget.subNs.subNamespaces.isEmpty;
        if (isLeaf) {
          _CliDetailSheet.showForNamespace(
            context: context,
            nsKey: '${widget.parentKey} ${widget.subKey}',
            label: _capitalize(widget.subKey),
            ns: widget.subNs,
          );
        } else {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => _SubNsPage(
                parentKey: widget.parentKey,
                subKey: widget.subKey,
                subNs: widget.subNs,
                configs: widget.configs,
                onRefresh: widget.onRefresh,
              ),
            ),
          ).then((_) => _loadConfig());
        }
      },
    );
  }

  IconData _subNsIcon(String key) => switch (key) {
        'profile' => Icons.person_outline,
        'memory' => Icons.psychology_outlined,
        'agents' => Icons.smart_toy_outlined,
        'system' => Icons.computer,
        'os' => Icons.computer,
        'network' => Icons.wifi,
        _ => Icons.folder_outlined,
      };

  String _capitalize(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Sub-namespace Page — shows commands within a sub-namespace
// ═══════════════════════════════════════════════════════════════════════════════

class _SubNsPage extends StatefulWidget {
  final String parentKey;
  final String subKey;
  final CliNamespace subNs;
  final Map<String, ToolConfig> configs;
  final VoidCallback onRefresh;

  const _SubNsPage({
    super.key,
    required this.parentKey,
    required this.subKey,
    required this.subNs,
    required this.configs,
    required this.onRefresh,
  });

  @override
  State<_SubNsPage> createState() => _SubNsPageState();
}

class _SubNsPageState extends State<_SubNsPage> {
  // 当前子命名空间自身的配置
  CliCommandConfig? _nsConfig;
  // 祖先限制
  ({String id, CliCommandConfig config})? _ancestor;

  String get _nsId => '${widget.parentKey}.${widget.subKey}';

  String get _title {
    final s = widget.subKey;
    return s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
  }

  @override
  void initState() {
    super.initState();
    _loadConfigs();
  }

  Future<void> _loadConfigs() async {
    final nsConfig = await CliCommandConfigService.instance.getConfig(_nsId);
    final ancestor = await CliCommandConfigService.instance.findRestrictingAncestor(_nsId);
    if (mounted) {
      setState(() {
        _nsConfig = nsConfig;
        _ancestor = ancestor;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final cmds = widget.subNs.commands;
    final nestedNs = widget.subNs.subNamespaces;

    final nsGlobalEnabled = _nsConfig?.globalEnabled ?? true;
    final nsSheOnly = _nsConfig?.sheOnly ?? false;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_title),
            if (!nsGlobalEnabled || nsSheOnly) ...[
              const SizedBox(width: 8),
              _NsStatusBadges(globalEnabled: nsGlobalEnabled, sheOnly: nsSheOnly),
            ],
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline, size: 20),
            tooltip: 'shepaw ${widget.parentKey} ${widget.subKey} --help',
            onPressed: () => _showHelpSheet(
              context: context,
              namespace: widget.parentKey,
              subcommand: widget.subKey,
              title: _title,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 20),
            tooltip: 'Sub-namespace Settings',
            onPressed: () async {
              await _NsConfigSheet.show(
                context: context,
                nsId: _nsId,
                label: _title,
                description: widget.subNs.description,
                icon: Icons.folder_outlined,
              );
              _loadConfigs();
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // ── 祖先限制横幅 ─────────────────────────────────────────────
          if (_ancestor != null)
            _AncestorRestrictionBanner(
              restrictingId: _ancestor!.id,
              restrictingConfig: _ancestor!.config,
            ),
          // ── 当前层级限制横幅 ──────────────────────────────────────────
          if (_ancestor == null && (!nsGlobalEnabled || nsSheOnly))
            _AncestorRestrictionBanner(
              restrictingId: _nsId,
              restrictingConfig: _nsConfig!,
            ),

          // 嵌套子命名空间（如 meta > system）
          if (nestedNs.isNotEmpty) ...[
            _SectionHeader(label: 'Namespaces', colorScheme: colorScheme),
            ...nestedNs.entries.map((e) => _SubNsTile(
                  parentKey: '${widget.parentKey} ${widget.subKey}',
                  subKey: e.key,
                  subNs: e.value,
                  configs: widget.configs,
                  onRefresh: widget.onRefresh,
                )),
          ],

          // 命令列表
          if (cmds.isNotEmpty) ...[
            if (nestedNs.isNotEmpty)
              Divider(height: 1, indent: 16, endIndent: 16, color: colorScheme.outlineVariant),
            _SectionHeader(label: 'Commands', colorScheme: colorScheme),
            ...cmds.entries.map((e) => _CommandTile(
                  nsKey: '${widget.parentKey} ${widget.subKey}',
                  cmd: e.value,
                  configs: widget.configs,
                  onRefresh: widget.onRefresh,
                )),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Command Tile — shows a single CLI command with enabled/sheOnly/configure
// ═══════════════════════════════════════════════════════════════════════════════

class _CommandTile extends StatefulWidget {
  final String nsKey;
  final CliCommand cmd;
  final Map<String, ToolConfig> configs;
  final VoidCallback onRefresh;

  const _CommandTile({
    required this.nsKey,
    required this.cmd,
    required this.configs,
    required this.onRefresh,
  });

  @override
  State<_CommandTile> createState() => _CommandTileState();
}

class _CommandTileState extends State<_CommandTile> {
  CliCommandConfig? _cliConfig;
  // 祖先限制信息
  ({String id, CliCommandConfig config})? _ancestor;

  // 只有 OsToolDefinition 对应的工具命令才有配置管理
  OsToolDefinition? _toolDef() {
    try {
      return OsToolRegistry.instance.tools.firstWhere((t) => t.name == widget.cmd.name);
    } catch (_) {
      return null;
    }
  }

  String get _commandId {
    final parts = widget.nsKey.trim().split(' ');
    final namespace = parts.first;
    final subPrefix = parts.length > 1 ? parts.sublist(1).join('.') + '.' : '';
    return '$namespace.$subPrefix${widget.cmd.name}';
  }

  @override
  void initState() {
    super.initState();
    _loadCliConfig();
  }

  Future<void> _loadCliConfig() async {
    final toolDef = _toolDef();
    // OS 工具命令用 ToolConfigService，其他 CLI 命令用 CliCommandConfigService
    if (toolDef == null) {
      final cfg = await CliCommandConfigService.instance.getConfig(_commandId);
      final ancestor = await CliCommandConfigService.instance.findRestrictingAncestor(_commandId);
      if (mounted) setState(() { _cliConfig = cfg; _ancestor = ancestor; });
    } else {
      // 工具命令也要检查祖先限制
      final ancestor = await CliCommandConfigService.instance.findRestrictingAncestor(_commandId);
      if (mounted) setState(() => _ancestor = ancestor);
    }
  }

  Future<void> _toggleGlobal() async {
    final current = _cliConfig?.globalEnabled ?? true;
    final updated = await CliCommandConfigService.instance
        .saveConfig(_commandId, globalEnabled: !current);
    if (mounted) setState(() => _cliConfig = updated);
  }

  Future<void> _toggleSheOnly() async {
    final current = _cliConfig?.sheOnly ?? false;
    final updated = await CliCommandConfigService.instance
        .saveConfig(_commandId, sheOnly: !current);
    if (mounted) setState(() => _cliConfig = updated);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final service = ToolConfigService.instance;
    final toolDef = _toolDef();
    final config = toolDef != null ? widget.configs[toolDef.name] : null;
    final isEnabled = config?.enabled ?? true;
    final isSheOnly = config?.sheExclusive ?? toolDef?.sheExclusive ?? false;
    final hasConfigSpec = toolDef != null && toolDef.configSpec.isNotEmpty;
    // 获取 flags 文档以判断该命令是否有参数
    final help = widget.cmd.getHelp();
    final flags = help['flags'] as Map?;
    final hasFlags = flags != null && flags.isNotEmpty;

    // CLI 命令（非 OS 工具）的配置状态
    final cliGlobalEnabled = _cliConfig?.globalEnabled ?? true;
    final cliSheOnly = _cliConfig?.sheOnly ?? false;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          leading: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: (toolDef != null
                      ? colorScheme.primaryContainer
                      : colorScheme.surfaceContainerHighest)
                  .withValues(alpha: (toolDef != null ? isEnabled : cliGlobalEnabled) ? 1 : 0.5),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              toolDef != null
                  ? _toolIconFor(toolDef.name)
                  : Icons.code_outlined,
              size: 16,
              color: toolDef != null
                  ? colorScheme.onPrimaryContainer
                      .withValues(alpha: isEnabled ? 1 : 0.4)
                  : colorScheme.onSurfaceVariant
                      .withValues(alpha: cliGlobalEnabled ? 1 : 0.4),
            ),
          ),
          title: Row(
            children: [
              Text(
                widget.cmd.name,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  fontFamily: toolDef != null ? null : 'monospace',
                  color: (toolDef != null ? isEnabled : cliGlobalEnabled)
                      ? colorScheme.onSurface
                      : colorScheme.outline,
                ),
              ),
              const SizedBox(width: 6),
              // 风险等级标签（工具专属）
              if (toolDef != null)
                _RiskBadge(risk: toolDef.defaultRiskLevel),
              // API Key 图标
              if (config?.hasApiKey ?? false) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: 'API Key configured',
                  child: Icon(Icons.key, size: 12, color: colorScheme.primary),
                ),
              ],
              // 参数覆盖图标
              if (config?.parameterOverrides != null) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Overrides set',
                  child: Icon(Icons.tune, size: 12, color: colorScheme.secondary),
                ),
              ],
              // flags 提示（非工具命令）
              if (toolDef == null && hasFlags) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: 'Has ${flags?.length} flag(s)',
                  child: Icon(Icons.flag_outlined,
                      size: 12, color: colorScheme.outline),
                ),
              ],
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.cmd.description,
                  style: TextStyle(fontSize: 11, color: colorScheme.outline),
                ),
                // 祖先限制提示
                if (_ancestor != null) ...[
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Icon(
                        !_ancestor!.config.globalEnabled
                            ? Icons.block
                            : Icons.lock_outline,
                        size: 11,
                        color: !_ancestor!.config.globalEnabled
                            ? colorScheme.error
                            : colorScheme.tertiary,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          !_ancestor!.config.globalEnabled
                              ? 'Disabled by parent: ${_ancestor!.id}'
                              : 'She-only by parent: ${_ancestor!.id}',
                          style: TextStyle(
                            fontSize: 10,
                            color: !_ancestor!.config.globalEnabled
                                ? colorScheme.error
                                : colorScheme.tertiary,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          trailing: toolDef != null
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // She Only chip
                    _buildSheOnlyChip(toolDef, isSheOnly, colorScheme, service, widget.onRefresh, context),
                    const SizedBox(width: 6),
                    // Enabled switch
                    SizedBox(
                      height: 24,
                      child: Switch.adaptive(
                        value: isEnabled,
                        onChanged: (v) async {
                          await service.saveToolConfig(toolDef.name, enabled: v);
                          widget.onRefresh();
                        },
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ),
                    // Configure button
                    if (hasConfigSpec) ...[
                      const SizedBox(width: 2),
                      IconButton(
                        icon: Icon(Icons.tune,
                            size: 17, color: colorScheme.primary),
                        tooltip: 'Configure',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _openConfigSheet(context, toolDef),
                      ),
                    ],
                  ],
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // CLI 命令：展示配置徽章（可快速切换）
                    _CliConfigBadges(
                      globalEnabled: cliGlobalEnabled,
                      sheOnly: cliSheOnly,
                      onToggleGlobal: _toggleGlobal,
                      onToggleSheOnly: _toggleSheOnly,
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right, size: 18, color: colorScheme.outlineVariant),
                  ],
                ),
          onTap: () => _CliDetailSheet.showForCommand(
            context: context,
            nsKey: widget.nsKey,
            cmd: widget.cmd,
          ),
        ),
        Divider(
          height: 1,
          indent: 16,
          endIndent: 16,
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ],
    );
  }

  Widget _buildSheOnlyChip(
    OsToolDefinition tool,
    bool isSheOnly,
    ColorScheme colorScheme,
    ToolConfigService service,
    VoidCallback onRefresh,
    BuildContext context,
  ) {
    return GestureDetector(
      onTap: () async {
        await service.saveToolConfig(tool.name, sheExclusive: !isSheOnly);
        onRefresh();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: isSheOnly
              ? colorScheme.tertiary.withValues(alpha: 0.15)
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isSheOnly
                ? colorScheme.tertiary.withValues(alpha: 0.5)
                : colorScheme.outlineVariant,
          ),
        ),
        child: Text(
          'She only',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: isSheOnly ? colorScheme.tertiary : colorScheme.outline,
          ),
        ),
      ),
    );
  }

  Future<void> _openConfigSheet(
      BuildContext context, OsToolDefinition tool) async {
    final config = widget.configs[tool.name];
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _ToolConfigSheet(
        tool: tool,
        initialConfig: config,
        service: ToolConfigService.instance,
        onChanged: widget.onRefresh,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// _NsStatusBadges — 小型状态标签（用在 _RootNsTile / _SubNsTile 标题后）
// ═══════════════════════════════════════════════════════════════════════════════

class _NsStatusBadges extends StatelessWidget {
  final bool globalEnabled;
  final bool sheOnly;
  const _NsStatusBadges({required this.globalEnabled, required this.sheOnly});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!globalEnabled)
          _miniTag('OFF', cs.error, cs),
        if (sheOnly) ...[
          if (!globalEnabled) const SizedBox(width: 3),
          _miniTag('She', cs.tertiary, cs),
        ],
      ],
    );
  }

  Widget _miniTag(String label, Color color, ColorScheme cs) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// _AncestorRestrictionBanner — 祖先限制信息横幅
// ═══════════════════════════════════════════════════════════════════════════════

class _AncestorRestrictionBanner extends StatelessWidget {
  final String restrictingId;
  final CliCommandConfig restrictingConfig;

  const _AncestorRestrictionBanner({
    required this.restrictingId,
    required this.restrictingConfig,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final messages = <_BannerMessage>[];

    if (!restrictingConfig.globalEnabled) {
      messages.add(_BannerMessage(
        icon: Icons.block,
        color: cs.error,
        containerColor: cs.errorContainer,
        onContainerColor: cs.onErrorContainer,
        text: 'Namespace "$restrictingId" is disabled — commands below are unavailable',
      ));
    }
    if (restrictingConfig.sheOnly) {
      messages.add(_BannerMessage(
        icon: Icons.lock_outline,
        color: cs.tertiary,
        containerColor: cs.tertiaryContainer,
        onContainerColor: cs.onTertiaryContainer,
        text: 'Namespace "$restrictingId" is She-only — other agents cannot access these commands',
      ));
    }

    return Column(
      children: messages.map((m) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: m.containerColor.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: m.color.withValues(alpha: 0.3)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(m.icon, size: 16, color: m.color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  m.text,
                  style: TextStyle(fontSize: 12, color: m.onContainerColor),
                ),
              ),
            ],
          ),
        ),
      )).toList(),
    );
  }
}

class _BannerMessage {
  final IconData icon;
  final Color color;
  final Color containerColor;
  final Color onContainerColor;
  final String text;
  const _BannerMessage({
    required this.icon,
    required this.color,
    required this.containerColor,
    required this.onContainerColor,
    required this.text,
  });
}

// ═══════════════════════════════════════════════════════════════════════════════
// _NsConfigSheet — 命名空间级别配置底部弹窗
// ═══════════════════════════════════════════════════════════════════════════════

class _NsConfigSheet extends StatefulWidget {
  final String nsId;
  final String label;
  final String description;
  final IconData icon;

  const _NsConfigSheet({
    required this.nsId,
    required this.label,
    required this.description,
    required this.icon,
  });

  static Future<void> show({
    required BuildContext context,
    required String nsId,
    required String label,
    required String description,
    required IconData icon,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _NsConfigSheet(
        nsId: nsId,
        label: label,
        description: description,
        icon: icon,
      ),
    );
  }

  @override
  State<_NsConfigSheet> createState() => _NsConfigSheetState();
}

class _NsConfigSheetState extends State<_NsConfigSheet> {
  CliCommandConfig? _config;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final cfg = await CliCommandConfigService.instance.getConfig(widget.nsId);
    if (mounted) setState(() { _config = cfg; _loading = false; });
  }

  Future<void> _setGlobalEnabled(bool v) async {
    final updated = await CliCommandConfigService.instance
        .saveConfig(widget.nsId, globalEnabled: v);
    if (mounted) setState(() => _config = updated);
  }

  Future<void> _setSheOnly(bool v) async {
    final updated = await CliCommandConfigService.instance
        .saveConfig(widget.nsId, sheOnly: v);
    if (mounted) setState(() => _config = updated);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final globalEnabled = _config?.globalEnabled ?? true;
    final sheOnly = _config?.sheOnly ?? false;

    // 层级信息
    final depth = widget.nsId.split('.').length;
    final levelLabel = depth == 1 ? 'Top-level Namespace' : 'Sub-namespace';
    final scopeLabel = 'Affects all commands under "${widget.nsId}.*"';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ───────────────────────────────────────────────────
          Row(children: [
            Icon(widget.icon, size: 20, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${widget.label} Settings',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              visualDensity: VisualDensity.compact,
              onPressed: () => Navigator.pop(context),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            widget.description,
            style: TextStyle(fontSize: 12, color: cs.outline),
          ),
          const SizedBox(height: 4),
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                levelLabel,
                style: TextStyle(fontSize: 10, color: cs.onPrimaryContainer, fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              widget.nsId,
              style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: cs.primary),
            ),
          ]),
          const SizedBox(height: 16),
          Divider(height: 1, color: cs.outlineVariant),
          const SizedBox(height: 12),

          if (_loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else ...[
            // ── Global Enabled Switch ─────────────────────────────────
            Container(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SwitchListTile.adaptive(
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                title: const Text('Global Enabled', style: TextStyle(fontSize: 13)),
                subtitle: Text(
                  globalEnabled
                      ? 'All agents can use commands in this namespace'
                      : 'All commands in this namespace are disabled',
                  style: TextStyle(fontSize: 11, color: cs.outline),
                ),
                value: globalEnabled,
                onChanged: _setGlobalEnabled,
              ),
            ),
            const SizedBox(height: 8),

            // ── She Only Switch ───────────────────────────────────────
            Container(
              decoration: BoxDecoration(
                color: sheOnly
                    ? cs.tertiaryContainer.withValues(alpha: 0.3)
                    : cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: sheOnly
                    ? Border.all(color: cs.tertiary.withValues(alpha: 0.4))
                    : null,
              ),
              child: SwitchListTile.adaptive(
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                title: Row(children: [
                  const Text('She Only', style: TextStyle(fontSize: 13)),
                  if (sheOnly) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: cs.tertiary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: cs.tertiary.withValues(alpha: 0.5)),
                      ),
                      child: Text(
                        'She only',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: cs.tertiary,
                        ),
                      ),
                    ),
                  ],
                ]),
                subtitle: Text(
                  sheOnly
                      ? 'Other agents cannot use commands in this namespace'
                      : 'All agents can use commands in this namespace',
                  style: TextStyle(fontSize: 11, color: cs.outline),
                ),
                value: sheOnly,
                activeTrackColor: cs.tertiary,
                onChanged: globalEnabled ? _setSheOnly : null,
              ),
            ),
            const SizedBox(height: 16),

            // ── Scope Info ────────────────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: cs.primary.withValues(alpha: 0.2)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 15, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      scopeLabel,
                      style: TextStyle(fontSize: 11, color: cs.onPrimaryContainer),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// _CliDetailSheet — universal command/namespace detail + execute panel
// ═══════════════════════════════════════════════════════════════════════════════

class _CliDetailSheet extends StatefulWidget {
  /// Title shown in the header
  final String title;
  /// Icon shown in the header
  final IconData icon;
  /// Help map from getHelp() or similar
  final Map<String, dynamic> help;
  /// Async executor: called when user taps "Run", receives extra flags from user input
  final Future<String> Function(Map<String, String> extraFlags) execute;
  /// 命令 ID（用于加载/保存全局启用/She专属配置），如 'context.profile.query'
  final String commandId;

  const _CliDetailSheet({
    required this.title,
    required this.icon,
    required this.help,
    required this.execute,
    required this.commandId,
  });

  // ── Convenience constructors ──────────────────────────────────────────────

  static void showForCommand({
    required BuildContext context,
    required String nsKey,
    required CliCommand cmd,
  }) {
    final help = cmd.getHelp();
    // nsKey like "context profile" → split → namespace + subcommand
    final parts = nsKey.trim().split(' ');
    final namespace = parts.first;
    final subPrefix = parts.length > 1 ? parts.sublist(1).join(' ') + '.' : '';
    final subcommand = '$subPrefix${cmd.name}';
    final commandId = '$namespace.$subcommand';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CliDetailSheet(
        title: cmd.name,
        icon: Icons.code_outlined,
        help: help,
        commandId: commandId,
        execute: (extraFlags) => ShepawCLI.instance.execute({
          'namespace': namespace,
          'subcommand': subcommand,
          'flags': extraFlags,
        }),
      ),
    );
  }

  static void showForNamespace({
    required BuildContext context,
    required String nsKey,
    required String label,
    required CliNamespace ns,
  }) {
    final help = ns.getHelp();
    final parts = nsKey.trim().split(' ');
    final namespace = parts.first;
    final subcommand = parts.length > 1 ? parts.sublist(1).join('.') : '';
    final commandId = subcommand.isNotEmpty ? '$namespace.$subcommand' : namespace;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _CliDetailSheet(
        title: label,
        icon: Icons.terminal,
        help: help,
        commandId: commandId,
        execute: (extraFlags) => ShepawCLI.instance.execute({
          'namespace': namespace,
          'subcommand': subcommand,
          'flags': extraFlags,
        }),
      ),
    );
  }

  @override
  State<_CliDetailSheet> createState() => _CliDetailSheetState();
}

class _CliDetailSheetState extends State<_CliDetailSheet> {
  bool _running = false;
  String? _result;
  bool _resultIsError = false;

  // ── 命令配置（全局启用 / She 专属）─────────────────────────────────────────
  CliCommandConfig? _config;
  bool _configLoading = true;

  // ── 参数输入框 ────────────────────────────────────────────────────────────
  final TextEditingController _flagsController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _flagsController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final config = await CliCommandConfigService.instance.getConfig(widget.commandId);
    if (mounted) {
      setState(() {
        _config = config;
        _configLoading = false;
      });
    }
  }

  Future<void> _setGlobalEnabled(bool v) async {
    final updated = await CliCommandConfigService.instance
        .saveConfig(widget.commandId, globalEnabled: v);
    if (mounted) setState(() => _config = updated);
  }

  Future<void> _setSheOnly(bool v) async {
    final updated = await CliCommandConfigService.instance
        .saveConfig(widget.commandId, sheOnly: v);
    if (mounted) setState(() => _config = updated);
  }

  /// 解析用户在输入框中输入的 flags 文本
  /// 支持格式：每行 `--key value` 或 `key=value` 或 `key value`
  Map<String, String> _parseInputFlags(String text) {
    final result = <String, String>{};
    if (text.trim().isEmpty) return result;

    final lines = text.split('\n');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // --key value 格式
      final dashMatch = RegExp(r'^--?(\S+)\s+(.+)$').firstMatch(trimmed);
      if (dashMatch != null) {
        result[dashMatch.group(1)!] = dashMatch.group(2)!.trim();
        continue;
      }

      // key=value 格式
      final eqMatch = RegExp(r'^(\S+)=(.+)$').firstMatch(trimmed);
      if (eqMatch != null) {
        result[eqMatch.group(1)!] = eqMatch.group(2)!.trim();
        continue;
      }

      // key value 格式（空格分隔）
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final key = parts.first.replaceAll(RegExp(r'^--?'), '');
        result[key] = parts.sublist(1).join(' ');
      }
    }
    return result;
  }

  Future<void> _run() async {
    setState(() { _running = true; _result = null; });
    try {
      final extraFlags = _parseInputFlags(_flagsController.text);
      final raw = await widget.execute(extraFlags);
      // Pretty-print JSON if possible
      try {
        final decoded = jsonDecode(raw);
        _result = const JsonEncoder.withIndent('  ').convert(decoded);
        _resultIsError = decoded is Map && decoded.containsKey('error');
      } catch (_) {
        _result = raw;
        _resultIsError = false;
      }
    } catch (e) {
      _result = e.toString();
      _resultIsError = true;
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final help = widget.help;
    final flags = (help['flags'] as Map?)?.cast<String, dynamic>();
    final usage = help['usage'] as String?;
    final description = help['description'] as String?;
    final examples = help['examples'] as List?;
    final hasFlags = flags != null && flags.isNotEmpty;

    final globalEnabled = _config?.globalEnabled ?? true;
    final sheOnly = _config?.sheOnly ?? false;

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      maxChildSize: 0.95,
      minChildSize: 0.35,
      expand: false,
      builder: (ctx, scrollCtrl) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: ListView(
          controller: scrollCtrl,
          children: [
            // ── Header ────────────────────────────────────────────────────
            Row(children: [
              Icon(widget.icon, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.title,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.pop(ctx),
              ),
            ]),

            if (description != null) ...[
              const SizedBox(height: 4),
              Text(description,
                  style: TextStyle(fontSize: 12, color: cs.outline)),
            ],

            // ── Usage ─────────────────────────────────────────────────────
            if (usage != null) ...[
              const SizedBox(height: 10),
              _CodeBlock(text: usage, cs: cs),
            ],

            // ── Flags ─────────────────────────────────────────────────────
            if (flags != null && flags.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Flags',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface)),
              const SizedBox(height: 8),
              ...flags.entries.map((e) => _FlagRow(
                    flagName: e.key,
                    flagDef: e.value as Map?,
                    cs: cs,
                  )),
            ],

            // ── Examples ─────────────────────────────────────────────────
            if (examples != null && examples.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Examples',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface)),
              const SizedBox(height: 6),
              ...examples.map((ex) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: _CodeBlock(text: '$ex', cs: cs),
                  )),
            ],

            // ── 参数输入框 ────────────────────────────────────────────────
            const SizedBox(height: 20),
            Divider(height: 1, color: cs.outlineVariant),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.input, size: 14, color: cs.outline),
                const SizedBox(width: 6),
                Text(
                  'Parameters',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '(optional)',
                  style: TextStyle(fontSize: 11, color: cs.outline),
                ),
                if (hasFlags) ...[
                  const Spacer(),
                  Text(
                    '${flags!.length} flag(s) available',
                    style: TextStyle(fontSize: 10, color: cs.outline),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _flagsController,
              maxLines: null,
              minLines: 3,
              style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: hasFlags
                    ? '--${flags!.keys.first} value\n--flag2 value2'
                    : 'No flags available for this command',
                hintStyle: TextStyle(fontSize: 11, color: cs.outlineVariant),
                filled: true,
                fillColor: cs.surfaceContainerHighest,
                contentPadding: const EdgeInsets.all(12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: cs.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: cs.outlineVariant),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: cs.primary),
                ),
              ),
              enabled: hasFlags,
            ),
            if (hasFlags) ...[
              const SizedBox(height: 4),
              Text(
                'Each line: --flag value  or  flag=value',
                style: TextStyle(fontSize: 10, color: cs.outline),
              ),
            ],

            // ── Run button ────────────────────────────────────────────────
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  icon: _running
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: cs.onPrimary))
                      : const Icon(Icons.play_arrow, size: 18),
                  label: Text(_running ? 'Running…' : 'Run'),
                  onPressed: _running ? null : _run,
                ),
              ),
            ]),

            // ── Result ────────────────────────────────────────────────────
            if (_result != null) ...[
              const SizedBox(height: 12),
              Row(children: [
                Icon(
                  _resultIsError ? Icons.error_outline : Icons.check_circle_outline,
                  size: 14,
                  color: _resultIsError ? cs.error : cs.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  _resultIsError ? 'Error' : 'Result',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _resultIsError ? cs.error : cs.primary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.copy, size: 15),
                  tooltip: 'Copy',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _result!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('Copied to clipboard'),
                        behavior: SnackBarBehavior.floating,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              ]),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _resultIsError
                      ? cs.errorContainer.withValues(alpha: 0.4)
                      : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _resultIsError
                        ? cs.error.withValues(alpha: 0.3)
                        : cs.outlineVariant,
                  ),
                ),
                child: SelectableText(
                  _result!,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: _resultIsError ? cs.onErrorContainer : cs.onSurface,
                  ),
                ),
              ),
            ],

            // ── 命令配置（全局启用 / She 专属）────────────────────────────
            const SizedBox(height: 20),
            Divider(height: 1, color: cs.outlineVariant),
            const SizedBox(height: 10),
            Text(
              'Command Settings',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.outline,
              ),
            ),
            const SizedBox(height: 8),
            if (_configLoading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: cs.outline),
                  ),
                ),
              )
            else ...[
              // 全局启用开关
              Container(
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SwitchListTile.adaptive(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  title: const Text('Global Enabled', style: TextStyle(fontSize: 13)),
                  subtitle: Text(
                    globalEnabled
                        ? 'All agents can use this command'
                        : 'Command is disabled globally',
                    style: TextStyle(fontSize: 11, color: cs.outline),
                  ),
                  value: globalEnabled,
                  onChanged: _setGlobalEnabled,
                ),
              ),
              const SizedBox(height: 6),
              // She 专属开关
              Container(
                decoration: BoxDecoration(
                  color: sheOnly
                      ? cs.tertiaryContainer.withValues(alpha: 0.3)
                      : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: sheOnly
                      ? Border.all(color: cs.tertiary.withValues(alpha: 0.4))
                      : null,
                ),
                child: SwitchListTile.adaptive(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  title: Row(
                    children: [
                      const Text('She Only', style: TextStyle(fontSize: 13)),
                      if (sheOnly) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: cs.tertiary.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: cs.tertiary.withValues(alpha: 0.5)),
                          ),
                          child: Text(
                            'She only',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: cs.tertiary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    sheOnly
                        ? 'Other agents cannot use this command'
                        : 'All agents can use this command',
                    style: TextStyle(fontSize: 11, color: cs.outline),
                  ),
                  value: sheOnly,
                  activeTrackColor: cs.tertiary,
                  onChanged: globalEnabled ? _setSheOnly : null,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _CliConfigBadges — 可复用的配置状态徽章组（全局启用 + She 专属）
// 支持点击快速切换，disabled 时只展示静态状态
// ─────────────────────────────────────────────────────────────────────────────

class _CliConfigBadges extends StatelessWidget {
  final bool globalEnabled;
  final bool sheOnly;
  /// 为 null 时徽章只读，不可点击
  final VoidCallback? onToggleGlobal;
  final VoidCallback? onToggleSheOnly;

  const _CliConfigBadges({
    required this.globalEnabled,
    required this.sheOnly,
    this.onToggleGlobal,
    this.onToggleSheOnly,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── She Only 徽章 ────────────────────────────────────────────────
        _badge(
          label: 'She',
          active: sheOnly,
          activeColor: cs.tertiary,
          inactiveColor: cs.outline,
          tooltip: sheOnly ? 'She only — tap to remove restriction' : 'All agents — tap to restrict to She',
          onTap: onToggleSheOnly,
          cs: cs,
        ),
        const SizedBox(width: 4),
        // ── 全局启用开关 ─────────────────────────────────────────────────
        _badge(
          label: globalEnabled ? 'ON' : 'OFF',
          active: globalEnabled,
          activeColor: cs.primary,
          inactiveColor: cs.error,
          tooltip: globalEnabled ? 'Enabled — tap to disable' : 'Disabled — tap to enable',
          onTap: onToggleGlobal,
          cs: cs,
        ),
      ],
    );
  }

  Widget _badge({
    required String label,
    required bool active,
    required Color activeColor,
    required Color inactiveColor,
    required String tooltip,
    required VoidCallback? onTap,
    required ColorScheme cs,
  }) {
    final color = active ? activeColor : inactiveColor;
    final child = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: active
            ? color.withValues(alpha: 0.12)
            : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: active ? color.withValues(alpha: 0.5) : cs.outlineVariant,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: active ? color : cs.outline,
          letterSpacing: 0.3,
        ),
      ),
    );

    if (onTap == null) return Tooltip(message: label, child: child);
    return Tooltip(
      message: tooltip,
      child: GestureDetector(onTap: onTap, child: child),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// _HelpSheet — 执行 --help 并展示结果的底部面板
// ═══════════════════════════════════════════════════════════════════════════════

class _HelpSheet extends StatefulWidget {
  final String namespace;
  final String subcommand;
  final String title;

  const _HelpSheet({
    required this.namespace,
    required this.subcommand,
    required this.title,
  });

  @override
  State<_HelpSheet> createState() => _HelpSheetState();
}

class _HelpSheetState extends State<_HelpSheet> {
  bool _loading = true;
  String? _result;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    _runHelp();
  }

  Future<void> _runHelp() async {
    setState(() { _loading = true; _result = null; });
    try {
      final raw = await ShepawCLI.instance.execute({
        'namespace': widget.namespace,
        'subcommand': widget.subcommand,
        'flags': {'help': ''},
      });
      try {
        final decoded = jsonDecode(raw);
        _result = const JsonEncoder.withIndent('  ').convert(decoded);
        _isError = decoded is Map && decoded.containsKey('error');
      } catch (_) {
        _result = raw;
        _isError = false;
      }
    } catch (e) {
      _result = e.toString();
      _isError = true;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 构建帮助命令显示文本
  String get _commandText {
    final sb = StringBuffer('shepaw');
    if (widget.namespace.isNotEmpty) {
      sb.write(' ${widget.namespace}');
    }
    if (widget.subcommand.isNotEmpty) {
      sb.write(' ${widget.subcommand}');
    }
    sb.write(' --help');
    return sb.toString();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      maxChildSize: 0.95,
      minChildSize: 0.35,
      expand: false,
      builder: (ctx, scrollCtrl) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: ListView(
          controller: scrollCtrl,
          children: [
            // ── Header ────────────────────────────────────────────────────
            Row(children: [
              Icon(Icons.help_outline, size: 20, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${widget.title} — Help',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.pop(ctx),
              ),
            ]),

            const SizedBox(height: 8),

            // ── 命令预览 ──────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: cs.primary.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(Icons.terminal, size: 14, color: cs.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SelectableText(
                      _commandText,
                      style: TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                        color: cs.primary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.refresh, size: 16, color: cs.primary),
                    tooltip: 'Re-run',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: _loading ? null : _runHelp,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // ── 结果区域 ──────────────────────────────────────────────────
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_result != null) ...[
              // 结果头部
              Row(children: [
                Icon(
                  _isError ? Icons.error_outline : Icons.check_circle_outline,
                  size: 14,
                  color: _isError ? cs.error : cs.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  _isError ? 'Error' : 'Help Output',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _isError ? cs.error : cs.primary,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.copy, size: 15),
                  tooltip: 'Copy',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _result!));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Copied to clipboard'),
                        behavior: SnackBarBehavior.floating,
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                ),
              ]),
              const SizedBox(height: 4),
              // 结果内容
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _isError
                      ? cs.errorContainer.withValues(alpha: 0.4)
                      : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _isError
                        ? cs.error.withValues(alpha: 0.3)
                        : cs.outlineVariant,
                  ),
                ),
                child: SelectableText(
                  _result!,
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: _isError ? cs.onErrorContainer : cs.onSurface,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Code block widget ──────────────────────────────────────────────────────────

class _CodeBlock extends StatelessWidget {
  final String text;
  final ColorScheme cs;
  const _CodeBlock({required this.text, required this.cs});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          fontSize: 11,
          fontFamily: 'monospace',
          color: cs.onSurfaceVariant,
        ),
      ),
    );
  }
}

// ── Flag row widget ────────────────────────────────────────────────────────────

class _FlagRow extends StatelessWidget {
  final String flagName;
  final Map? flagDef;
  final ColorScheme cs;
  const _FlagRow({required this.flagName, required this.flagDef, required this.cs});

  @override
  Widget build(BuildContext context) {
    final desc = flagDef?['description'] as String? ?? '';
    final req = flagDef?['required'] == true;
    final type = flagDef?['type'] as String? ?? 'string';
    final defaultVal = flagDef?['default'];
    final enumVals = flagDef?['enum'] as List?;
    final example = flagDef?['example'] as String?;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            constraints: const BoxConstraints(minWidth: 110),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: req ? cs.errorContainer : cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              '--$flagName',
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
                color: req ? cs.onErrorContainer : cs.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(spacing: 4, runSpacing: 2, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(type,
                        style: TextStyle(
                            fontSize: 10, color: cs.onPrimaryContainer)),
                  ),
                  if (req)
                    Text('required',
                        style: TextStyle(fontSize: 10, color: cs.error)),
                  if (defaultVal != null)
                    Text('default: $defaultVal',
                        style: TextStyle(fontSize: 10, color: cs.outline)),
                ]),
                if (desc.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(desc,
                      style: TextStyle(fontSize: 12, color: cs.onSurface)),
                ],
                if (enumVals != null) ...[
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 4,
                    children: enumVals
                        .map((v) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: cs.tertiaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text('$v',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: cs.onTertiaryContainer)),
                            ))
                        .toList(),
                  ),
                ],
                if (example != null) ...[
                  const SizedBox(height: 3),
                  Text('e.g. $example',
                      style: TextStyle(
                          fontSize: 10,
                          color: cs.outline,
                          fontStyle: FontStyle.italic)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 风险标签 ───────────────────────────────────────────────────────────────────

class _RiskBadge extends StatelessWidget {
  final String risk;
  const _RiskBadge({required this.risk});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (label, color) = switch (risk) {
      'safe' => ('safe', colorScheme.primary),
      'lowRisk' => ('low', colorScheme.tertiary),
      'highRisk' => ('high', colorScheme.error),
      _ => (risk, colorScheme.outline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 10, color: color, fontWeight: FontWeight.w500),
      ),
    );
  }
}

// ─── 区块标题 ───────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String label;
  final ColorScheme colorScheme;
  const _SectionHeader({required this.label, required this.colorScheme});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: colorScheme.primary,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tool Config BottomSheet (工具专属配置表单)
// ═══════════════════════════════════════════════════════════════════════════════

class _ToolConfigSheet extends StatefulWidget {
  final OsToolDefinition tool;
  final ToolConfig? initialConfig;
  final ToolConfigService service;
  final VoidCallback onChanged;

  const _ToolConfigSheet({
    required this.tool,
    required this.initialConfig,
    required this.service,
    required this.onChanged,
  });

  @override
  State<_ToolConfigSheet> createState() => _ToolConfigSheetState();
}

class _ToolConfigSheetState extends State<_ToolConfigSheet> {
  late bool _enabled;
  late bool _sheExclusive;
  late Map<String, dynamic> _paramOverrides;

  String? _currentApiKey;
  bool _loadingKey = true;
  bool _saving = false;

  final Map<String, TextEditingController> _fieldControllers = {};
  final Map<String, bool> _boolFields = {};
  final Map<String, String?> _selectFields = {};
  final _noteController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final c = widget.initialConfig;
    _enabled = c?.enabled ?? true;
    _sheExclusive = c?.sheExclusive ?? widget.tool.sheExclusive;
    _paramOverrides = Map.from(c?.parameterOverrides ?? {});
    _noteController.text = c?.note ?? '';

    for (final field in widget.tool.configSpec) {
      if (field.type == CliConfigFieldType.apiKey) continue;
      if (field.type == CliConfigFieldType.boolean) {
        final val = _paramOverrides[field.key];
        _boolFields[field.key] = val is bool
            ? val
            : (field.defaultValue is bool ? field.defaultValue as bool : false);
      } else if (field.type == CliConfigFieldType.select) {
        final val = _paramOverrides[field.key];
        _selectFields[field.key] =
            val is String ? val : (field.defaultValue as String?);
      } else {
        final val = _paramOverrides[field.key];
        _fieldControllers[field.key] = TextEditingController(
          text: val?.toString() ??
              (field.defaultValue != null
                  ? field.defaultValue.toString()
                  : ''),
        );
      }
    }
    _loadApiKey();
  }

  @override
  void dispose() {
    _noteController.dispose();
    for (final c in _fieldControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadApiKey() async {
    final key = await widget.service.getToolApiKey(widget.tool.name);
    if (mounted) setState(() { _currentApiKey = key; _loadingKey = false; });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        left: 20, right: 20, top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(_toolIconFor(widget.tool.name),
                size: 20, color: colorScheme.primary),
            const SizedBox(width: 8),
            Text(widget.tool.name,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w600)),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
          ]),
          Text(widget.tool.description,
              style: TextStyle(fontSize: 12, color: colorScheme.outline)),
          const Divider(height: 24),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToggles(colorScheme),
                  const Divider(height: 24),
                  ..._buildConfigFields(colorScheme),
                  _buildNoteSection(colorScheme),
                  const SizedBox(height: 20),
                  _buildActions(colorScheme),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToggles(ColorScheme cs) => Column(children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Enable globally', style: TextStyle(fontSize: 14)),
          subtitle: Text('When disabled, agents cannot use this tool',
              style: TextStyle(fontSize: 12, color: cs.outline)),
          value: _enabled,
          onChanged: (v) => setState(() => _enabled = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Row(children: [
            const Text('She only', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: cs.tertiary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('She',
                  style: TextStyle(
                      fontSize: 10,
                      color: cs.tertiary,
                      fontWeight: FontWeight.w500)),
            ),
          ]),
          subtitle: Text(
              'Only She can use this tool (not other agents)',
              style: TextStyle(fontSize: 12, color: cs.outline)),
          value: _sheExclusive,
          onChanged: (v) => setState(() => _sheExclusive = v),
        ),
      ]);

  List<Widget> _buildConfigFields(ColorScheme cs) {
    final widgets = <Widget>[];
    for (final field in widget.tool.configSpec) {
      widgets.add(_buildField(field, cs));
      widgets.add(const SizedBox(height: 16));
    }
    return widgets;
  }

  Widget _buildField(CliConfigField field, ColorScheme cs) =>
      switch (field.type) {
        CliConfigFieldType.apiKey => _buildApiKeyField(field, cs),
        CliConfigFieldType.boolean => _buildBoolField(field, cs),
        CliConfigFieldType.select => _buildSelectField(field, cs),
        _ => _buildTextField(field, cs),
      };

  Widget _buildApiKeyField(CliConfigField field, ColorScheme cs) {
    final hasKey = (_currentApiKey?.isNotEmpty) == true;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.key, size: 16, color: cs.primary),
        const SizedBox(width: 6),
        Text(field.label,
            style:
                const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
        if (field.required) ...[
          const SizedBox(width: 4),
          Text('*', style: TextStyle(fontSize: 14, color: cs.error)),
        ],
        const Spacer(),
        if (_loadingKey)
          const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
        else
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: (hasKey ? cs.primary : cs.outline).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(hasKey ? 'Configured' : 'Not set',
                style: TextStyle(
                    fontSize: 11,
                    color: hasKey ? cs.primary : cs.outline,
                    fontWeight: FontWeight.w500)),
          ),
      ]),
      const SizedBox(height: 4),
      Text(field.description,
          style: TextStyle(fontSize: 12, color: cs.outline)),
      if (hasKey && _currentApiKey != null) ...[
        const SizedBox(height: 6),
        Text(
            '${_currentApiKey!.substring(0, _currentApiKey!.length.clamp(0, 8))}••••••••',
            style: TextStyle(
                fontSize: 12,
                color: cs.outline,
                fontFamily: 'monospace')),
      ],
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: Icon(hasKey ? Icons.edit : Icons.add, size: 16),
            label: Text(hasKey ? 'Update Key' : 'Set Key'),
            onPressed: _showSetKeyDialog,
          ),
        ),
        if (hasKey) ...[
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Delete API key',
            icon: Icon(Icons.delete_outline, color: cs.error),
            onPressed: _confirmDeleteKey,
          ),
        ],
      ]),
    ]);
  }

  Widget _buildBoolField(CliConfigField field, ColorScheme cs) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(field.label, style: const TextStyle(fontSize: 14)),
        subtitle: Text(field.description,
            style: TextStyle(fontSize: 12, color: cs.outline)),
        value: _boolFields[field.key] ?? false,
        onChanged: (v) => setState(() => _boolFields[field.key] = v),
      );

  Widget _buildSelectField(CliConfigField field, ColorScheme cs) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(field.label,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w500)),
          if (field.required) ...[
            const SizedBox(width: 4),
            Text('*', style: TextStyle(fontSize: 14, color: cs.error)),
          ],
        ]),
        const SizedBox(height: 4),
        Text(field.description,
            style: TextStyle(fontSize: 12, color: cs.outline)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _selectFields[field.key],
          decoration: InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            isDense: true,
          ),
          items: (field.options ?? [])
              .map((o) => DropdownMenuItem(value: o, child: Text(o)))
              .toList(),
          onChanged: (v) => setState(() => _selectFields[field.key] = v),
        ),
      ]);

  Widget _buildTextField(CliConfigField field, ColorScheme cs) {
    final ctrl = _fieldControllers[field.key]!;
    final isNumeric = field.type == CliConfigFieldType.integer ||
        field.type == CliConfigFieldType.doubleNum;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(field.label,
            style:
                const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
        if (field.required) ...[
          const SizedBox(width: 4),
          Text('*', style: TextStyle(fontSize: 14, color: cs.error)),
        ],
      ]),
      const SizedBox(height: 4),
      Text(field.description,
          style: TextStyle(fontSize: 12, color: cs.outline)),
      const SizedBox(height: 8),
      TextField(
        controller: ctrl,
        keyboardType: isNumeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText:
              field.defaultValue != null ? field.defaultValue.toString() : '',
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          isDense: true,
        ),
      ),
    ]);
  }

  Widget _buildNoteSection(ColorScheme cs) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.note_outlined, size: 16, color: cs.outline),
          const SizedBox(width: 6),
          const Text('Note',
              style:
                  TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
        ]),
        const SizedBox(height: 8),
        TextField(
          controller: _noteController,
          maxLines: 2,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: 'Optional note...',
            hintStyle: TextStyle(fontSize: 13, color: cs.outline),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            isDense: true,
          ),
        ),
      ]);

  Widget _buildActions(ColorScheme cs) => Row(children: [
        if (widget.initialConfig != null)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: cs.error),
            onPressed: _confirmDeleteConfig,
            child: const Text('Delete Config'),
          ),
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _saving ? null : _saveConfig,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Save'),
        ),
      ]);

  Future<void> _showSetKeyDialog() async {
    final ctrl = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Set API Key — ${widget.tool.name}'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: ctrl,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: 'Enter your API key',
                border: OutlineInputBorder()),
            validator: (v) =>
                (v == null || v.isEmpty) ? 'API key cannot be empty' : null,
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, ctrl.text);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await widget.service.setToolApiKey(widget.tool.name, result);
      await _loadApiKey();
    }
  }

  Future<void> _confirmDeleteKey() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete API Key'),
        content: Text(
            'Remove the API key for ${widget.tool.name}? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.service.deleteToolApiKey(widget.tool.name);
      await _loadApiKey();
    }
  }

  Future<void> _confirmDeleteConfig() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Configuration'),
        content: Text(
            'Delete all configuration for ${widget.tool.name}? The API key will also be removed.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.service.deleteToolConfig(widget.tool.name);
      if (mounted) {
        Navigator.pop(context);
        widget.onChanged();
      }
    }
  }

  Future<void> _saveConfig() async {
    setState(() => _saving = true);
    try {
      final newOverrides = <String, dynamic>{};
      for (final field in widget.tool.configSpec) {
        if (field.type == CliConfigFieldType.apiKey) continue;
        if (field.type == CliConfigFieldType.boolean) {
          final val = _boolFields[field.key];
          if (val != null) newOverrides[field.key] = val;
        } else if (field.type == CliConfigFieldType.select) {
          final val = _selectFields[field.key];
          if (val != null) newOverrides[field.key] = val;
        } else {
          final text = _fieldControllers[field.key]?.text.trim() ?? '';
          if (text.isNotEmpty) newOverrides[field.key] = _parseParamValue(text);
        }
      }
      final note = _noteController.text.trim();
      await widget.service.saveToolConfig(
        widget.tool.name,
        parameterOverrides: newOverrides.isEmpty ? null : newOverrides,
        clearParameterOverrides: newOverrides.isEmpty,
        enabled: _enabled,
        sheExclusive: _sheExclusive,
        note: note.isEmpty ? null : note,
        clearNote: note.isEmpty,
      );
      if (mounted) {
        Navigator.pop(context);
        widget.onChanged();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
