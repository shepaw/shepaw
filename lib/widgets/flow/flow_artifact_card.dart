import 'dart:async';

import 'package:flutter/material.dart';

import '../../peer/models/flow_models.dart';
import '../../services/store_open_service.dart';

/// 产物所属的两层 scope。老主机没有 `instance_scope` 时 UI 会隐藏切换。
enum FlowArtifactScope { run, instance }

/// 删除运行 / 实例 / 产物目录时共用的一段明确警告。这里按当前 locale 给中英
/// 文案，不为 M4 再动生成好的 l10n 目录。
String flowArtifactDeletionWarning(BuildContext context) {
  final language = Localizations.maybeLocaleOf(context)?.languageCode ?? 'zh';
  return language.toLowerCase().startsWith('en')
      ? 'Artifacts stored under this run or instance, including every version, '
          'will be deleted too. This cannot be undone.'
      : '该运行或实例下的产物（含所有版本）也会一起删除，无法恢复。';
}

/// 运行页的产物卡：按 `artifact_id` 分组，每个 `v<n>` 可展开看元数据；
/// 点版本行走既有的 [StoreOpenService.openStoreUri] 预览 / 打开路径。
///
/// 列表数据由宿主页面的 Service + setState 拉取，这里只管展开、切换这类的
/// UI 局部状态，不引入全局状态管理。
class FlowArtifactCard extends StatefulWidget {
  const FlowArtifactCard({
    super.key,
    this.artifacts = const <FlowArtifact>[],
    this.instanceArtifacts = const <FlowArtifact>[],
    this.instanceScopeAvailable = false,
    this.loading = false,
    this.onScopeChanged,
    this.onOpenUri,
  });

  /// 本次运行 scope 下的产物。
  final List<FlowArtifact> artifacts;

  /// 提升到实例 scope 的产物。
  final List<FlowArtifact> instanceArtifacts;

  /// 老主机没有实例坐标时隐藏「本实例」切换。
  final bool instanceScopeAvailable;
  final bool loading;
  final ValueChanged<FlowArtifactScope>? onScopeChanged;

  /// 测试注入；生产缺省走 [StoreOpenService.instance.openStoreUri]。
  final Future<void> Function(BuildContext context, String uri)? onOpenUri;

  @override
  State<FlowArtifactCard> createState() => _FlowArtifactCardState();
}

class _FlowArtifactCardState extends State<FlowArtifactCard> {
  FlowArtifactScope _scope = FlowArtifactScope.run;
  final Set<String> _expanded = <String>{};

  @override
  void didUpdateWidget(FlowArtifactCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.instanceScopeAvailable &&
        _scope == FlowArtifactScope.instance) {
      _scope = FlowArtifactScope.run;
    }
  }

  List<FlowArtifact> get _visible {
    final source = _scope == FlowArtifactScope.run
        ? widget.artifacts
        : widget.instanceArtifacts;
    return FlowArtifact.groupByArtifactId(source);
  }

  void _select(FlowArtifactScope scope) {
    if (_scope == scope) return;
    setState(() => _scope = scope);
    widget.onScopeChanged?.call(scope);
  }

  void _toggle(String key) {
    setState(() {
      if (!_expanded.add(key)) _expanded.remove(key);
    });
  }

  void _open(String uri) {
    if (uri.isEmpty) return;
    final opener = widget.onOpenUri ?? StoreOpenService.instance.openStoreUri;
    final context = this.context;
    unawaited(() async {
      try {
        await opener(context, uri);
      } catch (_) {
        // StoreOpenService 已负责提示；产物卡不把后台失败变成整页错误。
      }
    }());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final artifacts = _visible;
    return Card(
      key: const ValueKey('flow-artifact-card'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.folder_copy_outlined, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('工作流产物', style: theme.textTheme.titleSmall),
                ),
                if (artifacts.isNotEmpty)
                  Text('${artifacts.length}',
                      style: theme.textTheme.labelMedium),
              ],
            ),
            if (widget.instanceScopeAvailable) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    key: const ValueKey('flow-artifact-tab-run'),
                    label: const Text('本次运行'),
                    selected: _scope == FlowArtifactScope.run,
                    onSelected: (_) => _select(FlowArtifactScope.run),
                  ),
                  ChoiceChip(
                    key: const ValueKey('flow-artifact-tab-instance'),
                    label: const Text('本实例'),
                    selected: _scope == FlowArtifactScope.instance,
                    onSelected: (_) => _select(FlowArtifactScope.instance),
                  ),
                ],
              ),
            ],
            if (widget.loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: LinearProgressIndicator(minHeight: 2),
              )
            else if (artifacts.isEmpty)
              const Padding(
                key: ValueKey('flow-artifact-empty'),
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Icon(Icons.inbox_outlined, size: 16),
                    SizedBox(width: 8),
                    Expanded(child: Text('还没有产物')),
                  ],
                ),
              )
            else
              for (final artifact in artifacts) ..._artifactRows(artifact),
          ],
        ),
      ),
    );
  }

  List<Widget> _artifactRows(FlowArtifact artifact) {
    final theme = Theme.of(context);
    final title =
        artifact.title.isNotEmpty ? artifact.title : artifact.artifactId;
    final subtitle = <String>[
      if (artifact.kind.isNotEmpty) artifact.kind,
      '最新 v${artifact.latestVersion}',
      if (artifact.scope.isNotEmpty) artifact.scope,
    ].join(' · ');
    return [
      const Divider(height: 12),
      Text(title, style: theme.textTheme.bodyMedium),
      if (subtitle.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      for (final version in artifact.versions)
        ..._versionRows(artifact, version),
    ];
  }

  List<Widget> _versionRows(
    FlowArtifact artifact,
    FlowArtifactVersion version,
  ) {
    final key = '${artifact.artifactId}|${version.version}|${version.filename}';
    final expanded = _expanded.contains(key);
    final created = _createdLabel(version.createdMs);
    final subtitle = <String>[
      if (version.filename.isNotEmpty) version.filename else '未命名文件',
      StoreOpenService.formatBytes(version.size),
      created,
    ].join(' · ');
    return [
      ListTile(
        key: ValueKey('flow-artifact-version-$key'),
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text('v${version.version}'),
        subtitle: Text(subtitle),
        trailing: IconButton(
          key: ValueKey('flow-artifact-toggle-$key'),
          tooltip: expanded ? '收起' : '展开',
          icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
          onPressed: () => _toggle(key),
        ),
        onTap: version.uri.isEmpty ? null : () => _open(version.uri),
      ),
      if (expanded)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('版本：v${version.version} · 大小：'
                  '${StoreOpenService.formatBytes(version.size)} · 创建：$created'),
              if (version.filename.isNotEmpty) Text('文件名：${version.filename}'),
              if (version.hash.isNotEmpty) Text('SHA256：${version.hash}'),
              if (version.note.isNotEmpty) Text('备注：${version.note}'),
              if (version.uri.isNotEmpty)
                SelectableText('地址：${version.uri}',
                    style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
    ];
  }

  String _createdLabel(int createdMs) {
    if (createdMs <= 0) return '时间未知';
    final time = DateTime.fromMillisecondsSinceEpoch(createdMs).toLocal();
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatShortDate(time)} '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(time))}';
  }
}
