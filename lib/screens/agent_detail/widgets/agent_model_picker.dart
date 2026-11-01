import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../models/model_definition.dart';
import '../../../models/remote_agent.dart';
import '../../../peer/host_she_turn.dart';
import '../../../widgets/chat/cursor_model_panel.dart';
import '../../model_management_screen.dart';
import '../agent_detail_kind.dart';
import '../agent_runtime_controller.dart';

/// 模型选择（编辑页）。三类 agent 共用同一份 UI，只有「选择时调哪个接口」不同，
/// 分支收在 [AgentRuntimeController.selectModel] 里。
class AgentModelPicker extends StatelessWidget {
  const AgentModelPicker({
    super.key,
    required this.controller,
    required this.onFailure,
  });

  final AgentRuntimeController controller;
  final void Function(AgentActionFailure failure) onFailure;

  Future<void> _select(String? value, BuildContext context) async {
    if (value == null) return;
    final failure = await controller.selectModel(value);
    if (failure != null && context.mounted) onFailure(failure);
  }

  Future<void> _setOption(
    String option,
    String value,
    BuildContext context,
  ) async {
    final failure = await controller.setModelOption(option, value);
    if (failure != null && context.mounted) onFailure(failure);
  }

  /// 惜宝：往储物袋名单里加一条并选中。名单各端共用，密钥留在主机。
  Future<void> _addSheModel(BuildContext context) async {
    final result = await Navigator.push<ModelDefinition>(
      context,
      MaterialPageRoute(
        builder: (_) => ModelEditScreen(catalog: _sheCatalog()),
      ),
    );
    if (result == null || !context.mounted) return;
    final failure = await controller.addSheModel(
      displayName: result.displayName,
      model: result.route.model ?? '',
      baseUrl: result.route.apiBase ?? '',
      apiKey: result.route.apiKey ?? '',
    );
    if (failure != null && context.mounted) onFailure(failure);
  }

  List<SheCatalogEntry> _sheCatalog() => [
        for (final model in controller.models)
          SheCatalogEntry(
            model: model.description,
            baseUrl: model.baseUrl,
            hasApiKey: model.hasApiKey,
          ),
      ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final models = controller.models;
    final effectiveCurrent = controller.currentModel ??
        (models.length == 1 ? models.first.value : null);
    final dropdownValue = effectiveCurrent != null &&
            models.any((m) => m.value == effectiveCurrent)
        ? effectiveCurrent
        : null;
    final isShe = controller.kind == AgentDetailKind.she;

    final String hint;
    if (!controller.modelsSwitchable) {
      hint = l10n.chat_modelConfiguredOnComputer;
    } else if (!controller.peerLinkUp && models.isNotEmpty) {
      hint = l10n.chat_peerDeviceOffline;
    } else {
      hint = l10n.agentDetail_switchModelHint;
    }

    Widget body;
    if (controller.modelsIssue == AgentRuntimeIssue.unsupported &&
        models.isEmpty) {
      body = Text(
        l10n.agentDetail_noModels,
        style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
      );
    } else if (models.isEmpty && controller.modelsLoading) {
      body = const SizedBox.shrink();
    } else if (!controller.modelsSwitchable) {
      body = Text(
        dropdownValue == null
            ? l10n.chat_mainModelUnset
            : models
                .firstWhere(
                  (m) => m.value == dropdownValue,
                  orElse: () => models.first,
                )
                .displayName,
        style: const TextStyle(fontSize: 14),
      );
    } else if (controller.modelsParameterized) {
      body = CursorModelSettings(
        models: models,
        currentModel: dropdownValue,
        optionValues: controller.modelOptionValues,
        modelLabel: l10n.agentDetail_model,
        enabled: !controller.modelsBusy && controller.peerLinkUp,
        onFastChanged: (enabled) =>
            unawaited(_setOption('fast', enabled ? 'true' : 'false', context)),
        onOptionChanged: (option, value) =>
            unawaited(_setOption(option, value, context)),
        onModelChanged: (value) => unawaited(_select(value, context)),
      );
    } else {
      body = DropdownButtonFormField<String>(
        value: dropdownValue,
        isExpanded: true,
        decoration: InputDecoration(
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          filled: true,
          fillColor: colorScheme.surface,
        ),
        hint: Text(l10n.chat_mainModelUnset),
        items: [
          for (final m in models)
            DropdownMenuItem<String>(
              value: m.value,
              child: Text(m.displayName, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: controller.modelsBusy || !controller.peerLinkUp
            ? null
            : (value) => unawaited(_select(value, context)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.memory_outlined, size: 18, color: colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              l10n.agentDetail_model,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            if (controller.modelsLoading)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              )
            else
              IconButton(
                icon: const Icon(Icons.refresh, size: 18),
                tooltip: l10n.agentDetail_refreshModels,
                onPressed: () => unawaited(controller.refreshModels(force: true)),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          hint,
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        body,
        if (isShe && controller.peerLinkUp) ...[
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => unawaited(_addSheModel(context)),
              icon: const Icon(Icons.add, size: 16),
              label: Text(l10n.agentDetail_addSheModel),
            ),
          ),
        ],
      ],
    );
  }
}

/// 模式选择（编辑页）。主机把模式存在 agent 级配置里，和聊天输入框切的是同一个值。
class AgentModePicker extends StatelessWidget {
  const AgentModePicker({
    super.key,
    required this.controller,
    required this.onFailure,
  });

  final AgentRuntimeController controller;
  final void Function(AgentActionFailure failure) onFailure;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final modes = controller.modes;
    final effectiveCurrent = controller.currentMode ??
        (modes.length == 1 ? modes.first.value : null);
    final dropdownValue =
        effectiveCurrent != null && modes.any((m) => m.value == effectiveCurrent)
            ? effectiveCurrent
            : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.tune_outlined, size: 18, color: colorScheme.primary),
            const SizedBox(width: 8),
            Text(
              l10n.agentDetail_mode,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            if (controller.modesBusy)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          l10n.agentDetail_modeHint,
          style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 10),
        if (modes.isEmpty)
          Text(
            controller.peerLinkUp
                ? l10n.agentDetail_noModes
                : l10n.agentDetail_peerOffline,
            style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
          )
        else
          DropdownButtonFormField<String>(
            value: dropdownValue,
            isExpanded: true,
            decoration: InputDecoration(
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              filled: true,
              fillColor: colorScheme.surface,
            ),
            items: [
              for (final m in modes)
                DropdownMenuItem<String>(
                  value: m.value,
                  child: Text(m.displayName, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: controller.modesBusy || !controller.peerLinkUp
                ? null
                : (value) async {
                    if (value == null) return;
                    final failure = await controller.selectMode(value);
                    if (failure != null && context.mounted) onFailure(failure);
                  },
          ),
      ],
    );
  }
}

/// 详情页里「运行设置」卡的一行：只读展示，点击跳到编辑页。
class AgentRuntimeSummaryRow extends StatelessWidget {
  const AgentRuntimeSummaryRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: colorScheme.primary),
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, size: 18),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// 改名用的输入框（编辑页）。离开焦点或回车才提交，避免每敲一个字都发请求。
class AgentNameField extends StatefulWidget {
  const AgentNameField({
    super.key,
    required this.agent,
    required this.readOnly,
    required this.onSubmit,
  });

  final RemoteAgent agent;
  final bool readOnly;
  /// 返回 null 表示成功，否则返回给用户的错误原因。
  final Future<String?> Function(String name) onSubmit;

  @override
  State<AgentNameField> createState() => _AgentNameFieldState();
}

class _AgentNameFieldState extends State<AgentNameField> {
  late final TextEditingController _controller;
  final _focusNode = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.agent.name);
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) unawaited(_submit());
    });
  }

  @override
  void didUpdateWidget(AgentNameField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.agent.name != widget.agent.name &&
        _controller.text != widget.agent.name) {
      _controller.text = widget.agent.name;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    final name = _controller.text.trim();
    if (name.isEmpty || name == widget.agent.name) return;
    final error = await widget.onSubmit(name);
    if (!mounted) return;
    setState(() => _error = error == null ? null : l10n.agentDetail_saveFailed(error));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (widget.readOnly) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            readOnly: true,
            decoration: InputDecoration(
              labelText: l10n.addAgent_agentName,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.badge),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.agentDetail_nameFromHost,
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ],
      );
    }
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      decoration: InputDecoration(
        labelText: l10n.addAgent_agentName,
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.badge),
        errorText: _error,
      ),
      textInputAction: TextInputAction.done,
      onSubmitted: (_) => unawaited(_submit()),
    );
  }
}
