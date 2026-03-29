import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/tool_config.dart';
import '../services/os_tool_registry.dart';
import '../services/tool_config_service.dart';

// ── 共享辅助函数 ─────────────────────────────────────────────────────────────

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

/// 工具配置管理屏幕
///
/// 提供对所有 CLI 工具的全局配置管理，包括：
/// - 查看工具配置状态
/// - 设置/删除 API Key
/// - 配置参数覆盖
/// - 启用/禁用工具
/// - 添加备注
class ToolConfigManagementScreen extends StatefulWidget {
  const ToolConfigManagementScreen({super.key});

  @override
  State<ToolConfigManagementScreen> createState() =>
      _ToolConfigManagementScreenState();
}

class _ToolConfigManagementScreenState
    extends State<ToolConfigManagementScreen> {
  final _service = ToolConfigService.instance;
  final _registry = OsToolRegistry.instance;

  /// 已配置工具映射: toolName -> ToolConfig
  Map<String, ToolConfig> _configs = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadConfigs();
  }

  Future<void> _loadConfigs() async {
    setState(() => _loading = true);
    final configs = await _service.getAllToolConfigs();
    setState(() {
      _configs = {for (final c in configs) c.toolName: c};
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final platform = _registry.currentPlatform;
    final toolsByCategory = <String, List<OsToolDefinition>>{};

    for (final tool in _registry.tools) {
      if (tool.supportedPlatforms.contains(platform)) {
        toolsByCategory.putIfAbsent(tool.category, () => []).add(tool);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tool Configuration'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadConfigs,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadConfigs,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // 统计卡片
                  _buildSummaryCard(colorScheme, toolsByCategory),
                  const SizedBox(height: 16),
                  // 按分类展示工具
                  ...toolsByCategory.entries.map((entry) {
                    return _buildCategorySection(
                        entry.key, entry.value, colorScheme);
                  }),
                ],
              ),
            ),
    );
  }

  // ── 统计卡片 ───────────────────────────────────────────────────────────────

  Widget _buildSummaryCard(
      ColorScheme colorScheme, Map<String, List<OsToolDefinition>> toolsByCategory) {
    final totalTools =
        toolsByCategory.values.fold<int>(0, (sum, list) => sum + list.length);
    final configuredCount = _configs.length;
    final withKeyCount = _configs.values.where((c) => c.hasApiKey).length;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildStat('Total Tools', '$totalTools', Icons.build, colorScheme),
            _buildStatDivider(colorScheme),
            _buildStat('Configured', '$configuredCount', Icons.settings,
                colorScheme),
            _buildStatDivider(colorScheme),
            _buildStat(
                'With API Key', '$withKeyCount', Icons.key, colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildStat(
      String label, String value, IconData icon, ColorScheme colorScheme) {
    return Column(
      children: [
        Icon(icon, size: 20, color: colorScheme.primary),
        const SizedBox(height: 4),
        Text(value,
            style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface)),
        Text(label,
            style: TextStyle(fontSize: 11, color: colorScheme.outline)),
      ],
    );
  }

  Widget _buildStatDivider(ColorScheme colorScheme) {
    return Container(
        height: 40, width: 1, color: colorScheme.outlineVariant);
  }

  // ── 分类区块 ───────────────────────────────────────────────────────────────

  Widget _buildCategorySection(
      String category, List<OsToolDefinition> tools, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Icon(_categoryIcon(category),
                  size: 16, color: colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                _categoryLabel(category),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.primary,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
        ...tools.map((tool) => _buildToolTile(tool, colorScheme)),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildToolTile(OsToolDefinition tool, ColorScheme colorScheme) {
    final config = _configs[tool.name];
    final hasConfig = config != null;
    final hasKey = config?.hasApiKey ?? false;
    final isEnabled = config?.enabled ?? true;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: hasConfig
              ? colorScheme.primary.withValues(alpha: 0.3)
              : colorScheme.outlineVariant,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _openToolConfigDialog(tool),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              // 工具图标
              Icon(
                _toolIconFor(tool.name),
                size: 18,
                color: isEnabled
                    ? colorScheme.onSurface
                    : colorScheme.outline.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 10),
              // 工具信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          tool.name,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: isEnabled
                                ? colorScheme.onSurface
                                : colorScheme.outline,
                          ),
                        ),
                        const SizedBox(width: 6),
                        _riskBadge(tool.defaultRiskLevel, colorScheme),
                      ],
                    ),
                    if (config?.note != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        config!.note!,
                        style: TextStyle(
                            fontSize: 11, color: colorScheme.outline),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              // 状态标志
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasKey)
                    Tooltip(
                      message: 'API Key configured',
                      child: Icon(Icons.key, size: 14, color: colorScheme.primary),
                    ),
                  if (config?.parameterOverrides != null) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: 'Parameter overrides set',
                      child: Icon(Icons.tune, size: 14, color: colorScheme.secondary),
                    ),
                  ],
                  const SizedBox(width: 8),
                  Icon(
                    Icons.chevron_right,
                    size: 16,
                    color: colorScheme.outline,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 配置编辑对话框 ─────────────────────────────────────────────────────────

  Future<void> _openToolConfigDialog(OsToolDefinition tool) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _ToolConfigSheet(
        tool: tool,
        initialConfig: _configs[tool.name],
        service: _service,
        onChanged: _loadConfigs,
      ),
    );
  }

  // ── 辅助方法 ───────────────────────────────────────────────────────────────

  Widget _riskBadge(String risk, ColorScheme colorScheme) {
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
        style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w500),
      ),
    );
  }

  IconData _categoryIcon(String category) => switch (category) {
        'command' => Icons.terminal,
        'file' => Icons.folder,
        'network' => Icons.wifi,
        'app' => Icons.apps,
        'clipboard' => Icons.content_paste,
        'process' => Icons.memory,
        'macos' => Icons.desktop_mac,
        _ => Icons.build,
      };

  String _categoryLabel(String category) => switch (category) {
        'command' => 'Command & System',
        'file' => 'File Operations',
        'network' => 'Network & Web',
        'app' => 'App & Browser',
        'clipboard' => 'Clipboard',
        'process' => 'Process Management',
        'macos' => 'macOS Exclusive',
        _ => category,
      };

}

// ── 工具配置编辑 BottomSheet ─────────────────────────────────────────────────

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
  late bool _hasApiKey;
  late String? _note;
  late Map<String, dynamic> _paramOverrides;

  bool _saving = false;
  bool _loadingKey = true;
  String? _currentApiKey; // 用于显示（已遮蔽）

  final _noteController = TextEditingController();
  final _paramController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _enabled = widget.initialConfig?.enabled ?? true;
    _hasApiKey = widget.initialConfig?.hasApiKey ?? false;
    _note = widget.initialConfig?.note;
    _paramOverrides = Map.from(widget.initialConfig?.parameterOverrides ?? {});
    _noteController.text = _note ?? '';
    _paramController.text = widget.initialConfig?.parameterOverrides != null
        ? const JsonEncoder.withIndent('  ')
            .convert(widget.initialConfig!.parameterOverrides)
        : '';
    _loadApiKeyStatus();
  }

  @override
  void dispose() {
    _noteController.dispose();
    _paramController.dispose();
    super.dispose();
  }

  Future<void> _loadApiKeyStatus() async {
    final key = await widget.service.getToolApiKey(widget.tool.name);
    if (mounted) {
      setState(() {
        _currentApiKey = key;
        _hasApiKey = key != null && key.isNotEmpty;
        _loadingKey = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题栏
          Row(
            children: [
              Icon(_toolIconFor(widget.tool.name),
                  size: 20, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                widget.tool.name,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          Text(
            widget.tool.description,
            style: TextStyle(fontSize: 12, color: colorScheme.outline),
          ),
          const Divider(height: 24),

          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 启用开关
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Enable globally',
                        style: TextStyle(fontSize: 14)),
                    subtitle: Text(
                      'When disabled, agents cannot use this tool',
                      style: TextStyle(
                          fontSize: 12, color: colorScheme.outline),
                    ),
                    value: _enabled,
                    onChanged: (v) => setState(() => _enabled = v),
                  ),
                  const Divider(height: 16),

                  // API Key 部분
                  _buildApiKeySection(colorScheme),
                  const SizedBox(height: 16),

                  // 参数覆盖
                  _buildParamOverridesSection(colorScheme),
                  const SizedBox(height: 16),

                  // 备注
                  _buildNoteSection(colorScheme),
                  const SizedBox(height: 20),

                  // 操作按钮
                  _buildActionButtons(colorScheme),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── API Key 区块 ──────────────────────────────────────────────────────────

  Widget _buildApiKeySection(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.key, size: 16, color: colorScheme.primary),
            const SizedBox(width: 6),
            const Text('API Key',
                style:
                    TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            const Spacer(),
            if (_loadingKey)
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: (_hasApiKey ? colorScheme.primary : colorScheme.outline)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _hasApiKey ? 'Configured' : 'Not set',
                  style: TextStyle(
                    fontSize: 11,
                    color: _hasApiKey
                        ? colorScheme.primary
                        : colorScheme.outline,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (_hasApiKey && _currentApiKey != null)
          Text(
            '${_currentApiKey!.substring(0, _currentApiKey!.length.clamp(0, 8))}••••••••',
            style: TextStyle(
                fontSize: 12,
                color: colorScheme.outline,
                fontFamily: 'monospace'),
          ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: Icon(_hasApiKey ? Icons.edit : Icons.add, size: 16),
                label: Text(_hasApiKey ? 'Update Key' : 'Set Key'),
                onPressed: _showSetKeyDialog,
              ),
            ),
            if (_hasApiKey) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Delete API key',
                icon: Icon(Icons.delete_outline, color: colorScheme.error),
                onPressed: _confirmDeleteKey,
              ),
            ],
          ],
        ),
      ],
    );
  }

  // ── 参数覆盖区块 ───────────────────────────────────────────────────────────

  Widget _buildParamOverridesSection(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.tune, size: 16, color: colorScheme.secondary),
            const SizedBox(width: 6),
            const Text('Parameter Overrides',
                style:
                    TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
            const Spacer(),
            if (_paramOverrides.isNotEmpty)
              TextButton(
                style: TextButton.styleFrom(
                    foregroundColor: colorScheme.error,
                    textStyle: const TextStyle(fontSize: 12)),
                onPressed: () =>
                    setState(() => _paramOverrides = {}),
                child: const Text('Clear all'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Override default parameters when this tool is called',
          style: TextStyle(fontSize: 12, color: colorScheme.outline),
        ),
        const SizedBox(height: 8),
        // 现有参数列表
        if (_paramOverrides.isNotEmpty) ...[
          ..._paramOverrides.entries.map((e) => _buildParamChip(e, colorScheme)),
          const SizedBox(height: 8),
        ],
        // 添加参数按钮
        OutlinedButton.icon(
          icon: const Icon(Icons.add, size: 16),
          label: const Text('Add Parameter'),
          onPressed: _showAddParamDialog,
        ),
      ],
    );
  }

  Widget _buildParamChip(
      MapEntry<String, dynamic> entry, ColorScheme colorScheme) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Text(
            entry.key,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSecondaryContainer),
          ),
          const Text(' = ',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          Expanded(
            child: Text(
              entry.value.toString(),
              style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: colorScheme.onSecondaryContainer),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InkWell(
            onTap: () => setState(() => _paramOverrides.remove(entry.key)),
            child: Icon(Icons.close, size: 14, color: colorScheme.outline),
          ),
        ],
      ),
    );
  }

  // ── 备注区块 ──────────────────────────────────────────────────────────────

  Widget _buildNoteSection(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.note_outlined, size: 16, color: colorScheme.outline),
            const SizedBox(width: 6),
            const Text('Note',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _noteController,
          maxLines: 2,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            hintText: 'Optional note...',
            hintStyle:
                TextStyle(fontSize: 13, color: colorScheme.outline),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            contentPadding: const EdgeInsets.symmetric(
                horizontal: 12, vertical: 8),
            isDense: true,
          ),
        ),
      ],
    );
  }

  // ── 操作按钮 ──────────────────────────────────────────────────────────────

  Widget _buildActionButtons(ColorScheme colorScheme) {
    return Row(
      children: [
        if (widget.initialConfig != null)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: colorScheme.error),
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
      ],
    );
  }

  // ── 对话框 ────────────────────────────────────────────────────────────────

  Future<void> _showSetKeyDialog() async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Set API Key — ${widget.tool.name}'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API Key',
              hintText: 'Enter your API key',
              border: OutlineInputBorder(),
            ),
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
                Navigator.pop(ctx, controller.text);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result != null && result.isNotEmpty) {
      await widget.service.setToolApiKey(widget.tool.name, result);
      await _loadApiKeyStatus();
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
      await _loadApiKeyStatus();
    }
  }

  Future<void> _showAddParamDialog() async {
    final keyCtrl = TextEditingController();
    final valueCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Parameter Override'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: keyCtrl,
                decoration: const InputDecoration(
                  labelText: 'Parameter Name',
                  hintText: 'e.g. timeout',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Name required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: valueCtrl,
                decoration: const InputDecoration(
                  labelText: 'Value',
                  hintText: 'e.g. 60',
                  border: OutlineInputBorder(),
                  helperText: 'Numbers, booleans (true/false), or text',
                ),
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Value required' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                final k = keyCtrl.text.trim();
                final v = _parseParamValue(valueCtrl.text.trim());
                setState(() => _paramOverrides[k] = v);
                Navigator.pop(ctx);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
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

  // ── 保存 ──────────────────────────────────────────────────────────────────

  Future<void> _saveConfig() async {
    setState(() => _saving = true);
    try {
      final note = _noteController.text.trim();
      await widget.service.saveToolConfig(
        widget.tool.name,
        parameterOverrides: _paramOverrides.isEmpty ? null : _paramOverrides,
        clearParameterOverrides: _paramOverrides.isEmpty,
        enabled: _enabled,
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
  }  // end _ToolConfigSheetState
}
