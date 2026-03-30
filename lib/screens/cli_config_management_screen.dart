import 'package:flutter/material.dart';

import '../models/cli_config_field.dart';
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

/// CLI 工具配置管理屏幕
///
/// 展示所有 CLI 工具，按命名空间路径分组（tools / Network、tools / OS 等）。
///
/// 功能：
/// - 所有工具均可切换 **Enabled** 和 **She Only** 开关（直接持久化）
/// - 声明了 [OsToolDefinition.configSpec] 的工具显示"Configure"入口
///   → 打开动态表单 BottomSheet，根据 configSpec 自动渲染字段
class CliConfigManagementScreen extends StatefulWidget {
  const CliConfigManagementScreen({super.key});

  @override
  State<CliConfigManagementScreen> createState() =>
      _CliConfigManagementScreenState();
}

class _CliConfigManagementScreenState
    extends State<CliConfigManagementScreen> {
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

    // 按命名空间路径分组
    final toolsByNamespace = <String, List<OsToolDefinition>>{};
    for (final tool in _registry.tools) {
      if (tool.supportedPlatforms.contains(platform)) {
        final nsKey = tool.category == 'network' ? 'tools / Network' : 'tools / OS';
        toolsByNamespace.putIfAbsent(nsKey, () => []).add(tool);
      }
    }

    // 保证 Network 优先展示
    final sortedKeys = toolsByNamespace.keys.toList()
      ..sort((a, b) {
        if (a.contains('Network')) return -1;
        if (b.contains('Network')) return 1;
        return a.compareTo(b);
      });

    return Scaffold(
      appBar: AppBar(
        title: const Text('CLI Tool Configuration'),
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
                  _buildSummaryCard(colorScheme, toolsByNamespace),
                  const SizedBox(height: 16),
                  ...sortedKeys.map((key) => _buildNamespaceSection(
                      key, toolsByNamespace[key]!, colorScheme)),
                ],
              ),
            ),
    );
  }

  // ── 统计卡片 ───────────────────────────────────────────────────────────────

  Widget _buildSummaryCard(ColorScheme colorScheme,
      Map<String, List<OsToolDefinition>> toolsByNamespace) {
    final totalTools =
        toolsByNamespace.values.fold<int>(0, (sum, l) => sum + l.length);
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
            _buildStat('Total', '$totalTools', Icons.build_outlined, colorScheme),
            _buildStatDivider(colorScheme),
            _buildStat('Configured', '$configuredCount', Icons.settings, colorScheme),
            _buildStatDivider(colorScheme),
            _buildStat('API Keys', '$withKeyCount', Icons.key, colorScheme),
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

  Widget _buildStatDivider(ColorScheme colorScheme) =>
      Container(height: 40, width: 1, color: colorScheme.outlineVariant);

  // ── 命名空间区块 ──────────────────────────────────────────────────────────

  Widget _buildNamespaceSection(String nsKey,
      List<OsToolDefinition> tools, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              Icon(_namespaceIcon(nsKey), size: 14, color: colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                nsKey,
                style: TextStyle(
                  fontSize: 12,
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

  IconData _namespaceIcon(String nsKey) {
    if (nsKey.contains('Network')) return Icons.wifi;
    if (nsKey.contains('OS')) return Icons.computer;
    return Icons.folder_outlined;
  }

  // ── 工具行 ────────────────────────────────────────────────────────────────

  Widget _buildToolTile(OsToolDefinition tool, ColorScheme colorScheme) {
    final config = _configs[tool.name];
    final isEnabled = config?.enabled ?? true;
    final isSheOnly = config?.sheExclusive ?? tool.sheExclusive;
    final hasConfigSpec = tool.configSpec.isNotEmpty;
    final hasConfig = config != null;

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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
            // 工具名称 + 状态标记
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
                      if (config?.hasApiKey ?? false) ...[
                        const SizedBox(width: 4),
                        Tooltip(
                          message: 'API Key configured',
                          child: Icon(Icons.key,
                              size: 13, color: colorScheme.primary),
                        ),
                      ],
                      if (config?.parameterOverrides != null) ...[
                        const SizedBox(width: 4),
                        Tooltip(
                          message: 'Parameter overrides set',
                          child: Icon(Icons.tune,
                              size: 13, color: colorScheme.secondary),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            // 右侧操作区
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // She Only 标签/按钮
                _buildSheOnlyChip(tool, isSheOnly, colorScheme),
                const SizedBox(width: 8),
                // Enabled 开关
                SizedBox(
                  height: 24,
                  child: Switch.adaptive(
                    value: isEnabled,
                    onChanged: (v) => _toggleEnabled(tool.name, v),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                // Configure 按钮（仅有 configSpec 的工具显示）
                if (hasConfigSpec) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(Icons.tune, size: 18, color: colorScheme.primary),
                    tooltip: 'Configure',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _openConfigSheet(tool),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSheOnlyChip(
      OsToolDefinition tool, bool isSheOnly, ColorScheme colorScheme) {
    return GestureDetector(
      onTap: () => _toggleSheExclusive(tool.name, !isSheOnly),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
        style: TextStyle(
            fontSize: 10, color: color, fontWeight: FontWeight.w500),
      ),
    );
  }

  // ── 状态快捷更新 ───────────────────────────────────────────────────────────

  Future<void> _toggleEnabled(String toolName, bool enabled) async {
    await _service.saveToolConfig(toolName, enabled: enabled);
    await _loadConfigs();
  }

  Future<void> _toggleSheExclusive(String toolName, bool sheExclusive) async {
    await _service.saveToolConfig(toolName, sheExclusive: sheExclusive);
    await _loadConfigs();
  }

  // ── 配置 BottomSheet ───────────────────────────────────────────────────────

  Future<void> _openConfigSheet(OsToolDefinition tool) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _CliConfigSheet(
        tool: tool,
        initialConfig: _configs[tool.name],
        service: _service,
        onChanged: _loadConfigs,
      ),
    );
  }
}

// ── CLI 工具配置编辑 BottomSheet ─────────────────────────────────────────────

class _CliConfigSheet extends StatefulWidget {
  final OsToolDefinition tool;
  final ToolConfig? initialConfig;
  final ToolConfigService service;
  final VoidCallback onChanged;

  const _CliConfigSheet({
    required this.tool,
    required this.initialConfig,
    required this.service,
    required this.onChanged,
  });

  @override
  State<_CliConfigSheet> createState() => _CliConfigSheetState();
}

class _CliConfigSheetState extends State<_CliConfigSheet> {
  late bool _enabled;
  late bool _sheExclusive;
  late String? _note;
  late Map<String, dynamic> _paramOverrides;

  /// API Key 当前值（从 secure storage 加载，用于显示遮掩版本）
  String? _currentApiKey;
  bool _loadingKey = true;
  bool _saving = false;

  /// 非 apiKey 字段的表单控制器：fieldKey -> TextEditingController
  final Map<String, TextEditingController> _fieldControllers = {};
  /// boolean 字段的状态：fieldKey -> bool
  final Map<String, bool> _boolFields = {};
  /// select 字段的当前值：fieldKey -> String
  final Map<String, String?> _selectFields = {};

  final _noteController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final config = widget.initialConfig;
    _enabled = config?.enabled ?? true;
    _sheExclusive = config?.sheExclusive ?? widget.tool.sheExclusive;
    _note = config?.note;
    _paramOverrides = Map.from(config?.parameterOverrides ?? {});
    _noteController.text = _note ?? '';

    // 初始化 configSpec 字段控制器
    for (final field in widget.tool.configSpec) {
      if (field.type == CliConfigFieldType.apiKey) continue;
      if (field.type == CliConfigFieldType.boolean) {
        final val = _paramOverrides[field.key];
        _boolFields[field.key] =
            val is bool ? val : (field.defaultValue is bool ? field.defaultValue as bool : false);
      } else if (field.type == CliConfigFieldType.select) {
        final val = _paramOverrides[field.key];
        _selectFields[field.key] =
            val is String ? val : (field.defaultValue as String?);
      } else {
        final val = _paramOverrides[field.key];
        final text = val != null
            ? val.toString()
            : (field.defaultValue != null ? field.defaultValue.toString() : '');
        _fieldControllers[field.key] = TextEditingController(text: text);
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
    if (mounted) {
      setState(() {
        _currentApiKey = key;
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
          // 标题
          Row(
            children: [
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
                  // 全局开关区
                  _buildTogglesSection(colorScheme),
                  const Divider(height: 24),

                  // 动态配置字段
                  ..._buildConfigFields(colorScheme),

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

  // ── 开关区 ────────────────────────────────────────────────────────────────

  Widget _buildTogglesSection(ColorScheme colorScheme) {
    return Column(
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Enable globally',
              style: TextStyle(fontSize: 14)),
          subtitle: Text(
            'When disabled, agents cannot use this tool',
            style: TextStyle(fontSize: 12, color: colorScheme.outline),
          ),
          value: _enabled,
          onChanged: (v) => setState(() => _enabled = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Row(
            children: [
              const Text('She only', style: TextStyle(fontSize: 14)),
              const SizedBox(width: 6),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: colorScheme.tertiary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'She',
                  style: TextStyle(
                      fontSize: 10,
                      color: colorScheme.tertiary,
                      fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
          subtitle: Text(
            'When enabled, only She can use this tool (not other agents)',
            style: TextStyle(fontSize: 12, color: colorScheme.outline),
          ),
          value: _sheExclusive,
          onChanged: (v) => setState(() => _sheExclusive = v),
        ),
      ],
    );
  }

  // ── 动态配置字段渲染 ───────────────────────────────────────────────────────

  List<Widget> _buildConfigFields(ColorScheme colorScheme) {
    final widgets = <Widget>[];
    for (final field in widget.tool.configSpec) {
      widgets.add(_buildField(field, colorScheme));
      widgets.add(const SizedBox(height: 16));
    }
    return widgets;
  }

  Widget _buildField(CliConfigField field, ColorScheme colorScheme) {
    return switch (field.type) {
      CliConfigFieldType.apiKey => _buildApiKeyField(field, colorScheme),
      CliConfigFieldType.boolean => _buildBooleanField(field, colorScheme),
      CliConfigFieldType.select => _buildSelectField(field, colorScheme),
      _ => _buildTextInputField(field, colorScheme),
    };
  }

  // API Key 字段
  Widget _buildApiKeyField(CliConfigField field, ColorScheme colorScheme) {
    final hasKey = _currentApiKey != null && _currentApiKey!.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.key, size: 16, color: colorScheme.primary),
            const SizedBox(width: 6),
            Text(field.label,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500)),
            if (field.required) ...[
              const SizedBox(width: 4),
              Text('*',
                  style: TextStyle(
                      fontSize: 14, color: colorScheme.error)),
            ],
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
                  color: (hasKey ? colorScheme.primary : colorScheme.outline)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  hasKey ? 'Configured' : 'Not set',
                  style: TextStyle(
                    fontSize: 11,
                    color: hasKey ? colorScheme.primary : colorScheme.outline,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          field.description,
          style: TextStyle(fontSize: 12, color: colorScheme.outline),
        ),
        if (hasKey && _currentApiKey != null) ...[
          const SizedBox(height: 6),
          Text(
            '${_currentApiKey!.substring(0, _currentApiKey!.length.clamp(0, 8))}••••••••',
            style: TextStyle(
                fontSize: 12,
                color: colorScheme.outline,
                fontFamily: 'monospace'),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
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
                icon:
                    Icon(Icons.delete_outline, color: colorScheme.error),
                onPressed: _confirmDeleteKey,
              ),
            ],
          ],
        ),
      ],
    );
  }

  // Boolean 字段
  Widget _buildBooleanField(CliConfigField field, ColorScheme colorScheme) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(field.label, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        field.description,
        style: TextStyle(fontSize: 12, color: colorScheme.outline),
      ),
      value: _boolFields[field.key] ?? false,
      onChanged: (v) => setState(() => _boolFields[field.key] = v),
    );
  }

  // Select 字段
  Widget _buildSelectField(CliConfigField field, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(field.label,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500)),
            if (field.required) ...[
              const SizedBox(width: 4),
              Text('*',
                  style: TextStyle(
                      fontSize: 14, color: colorScheme.error)),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          field.description,
          style: TextStyle(fontSize: 12, color: colorScheme.outline),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _selectFields[field.key],
          decoration: InputDecoration(
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            isDense: true,
          ),
          items: (field.options ?? [])
              .map((o) => DropdownMenuItem(value: o, child: Text(o)))
              .toList(),
          onChanged: (v) => setState(() => _selectFields[field.key] = v),
        ),
      ],
    );
  }

  // 文本/数字输入字段
  Widget _buildTextInputField(CliConfigField field, ColorScheme colorScheme) {
    final ctrl = _fieldControllers[field.key]!;
    final isNumeric = field.type == CliConfigFieldType.integer ||
        field.type == CliConfigFieldType.doubleNum;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(field.label,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500)),
            if (field.required) ...[
              const SizedBox(width: 4),
              Text('*',
                  style: TextStyle(
                      fontSize: 14, color: colorScheme.error)),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          field.description,
          style: TextStyle(fontSize: 12, color: colorScheme.outline),
        ),
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
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            isDense: true,
          ),
        ),
      ],
    );
  }

  // ── 备注区块 ──────────────────────────────────────────────────────────────

  Widget _buildNoteSection(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.note_outlined,
                size: 16, color: colorScheme.outline),
            const SizedBox(width: 6),
            const Text('Note',
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w500)),
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
                borderRadius: BorderRadius.circular(8)),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
            style: TextButton.styleFrom(
                foregroundColor: colorScheme.error),
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

  // ── 保存 ──────────────────────────────────────────────────────────────────

  Future<void> _saveConfig() async {
    setState(() => _saving = true);
    try {
      // 收集非 apiKey 字段的值到 parameterOverrides
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
          if (text.isNotEmpty) {
            newOverrides[field.key] = _parseParamValue(text);
          }
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
