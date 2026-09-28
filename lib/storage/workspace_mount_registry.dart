import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'store_protocol.dart';

/// 工作区挂载（`docs/workspace_mount_decision.md` A 档）。
///
/// 袋树里不放 symlink（`LocalStore` 明确禁止，防逃逸），挂载关系记在
/// `.system/mounts.json`，读路径在解析时穿透到外部真实目录：
/// - 挂载视图**没有副本**：外部目录就是本体，改磁盘即改袋；
/// - 不进版本 / 不进 journal / 不镜像 / 不参与去重与配额；
/// - 写与删一律拒绝（删除会动用户磁盘）。
class WorkspaceMount {
  WorkspaceMount({
    required this.id,
    required this.space,
    required this.path,
    required this.external,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String space;

  /// 袋内挂载点（space 下的相对路径），如 `Users/me/proj`。
  final String path;

  /// 外部真实目录绝对路径。
  final String external;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'space': space,
        'path': path,
        'external': external,
        'created_at': createdAt.toIso8601String(),
      };

  static WorkspaceMount? fromJson(Map<String, dynamic> json) {
    final space = json['space'] as String? ?? '';
    final path = json['path'] as String? ?? '';
    final external = json['external'] as String? ?? '';
    if (space.isEmpty || path.isEmpty || external.isEmpty) return null;
    return WorkspaceMount(
      id: json['id'] as String? ?? path,
      space: space,
      path: path,
      external: external,
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '') ??
              DateTime.now(),
    );
  }
}

/// `.system/mounts.json` 的读写与解析。
class WorkspaceMountRegistry {
  WorkspaceMountRegistry(this.root);

  final Directory root;

  List<WorkspaceMount>? _cache;

  Future<File> get _file async {
    final dir = Directory(p.join(root.path, '.system'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, 'mounts.json'));
  }

  /// 挂载清单（进程内缓存；[add] / [remove] 后失效）。
  Future<List<WorkspaceMount>> list() async {
    final cached = _cache;
    if (cached != null) return cached;
    final file = await _file;
    if (!await file.exists()) return _cache = const [];
    try {
      final obj = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final mounts = <WorkspaceMount>[
        for (final raw in ((obj['mounts'] as List?) ?? const []))
          if (raw is Map)
            if (WorkspaceMount.fromJson(raw.cast<String, dynamic>()) case
                final m?)
              m,
      ];
      return _cache = mounts;
    } catch (_) {
      return _cache = const [];
    }
  }

  Future<void> _save(List<WorkspaceMount> mounts) async {
    _cache = mounts;
    await (await _file).writeAsString(jsonEncode(<String, dynamic>{
      'mounts': [for (final m in mounts) m.toJson()],
    }));
  }

  /// 注册（或覆盖同名挂载点）。[path] 走 [normalizeStorePath] 校验。
  Future<WorkspaceMount> add({
    required String space,
    required String path,
    required String external,
  }) async {
    final normPath = normalizeStorePath(path);
    final mount = WorkspaceMount(
      id: 'm-${normPath.hashCode.toRadixString(36)}',
      space: space,
      path: normPath,
      external: p.normalize(external),
    );
    final mounts = List<WorkspaceMount>.of(await list());
    mounts.removeWhere((m) => m.space == space && m.path == normPath);
    mounts.add(mount);
    await _save(mounts);
    return mount;
  }

  Future<void> remove(String id) async {
    final mounts = List<WorkspaceMount>.of(await list());
    mounts.removeWhere((m) => m.id == id);
    await _save(mounts);
  }

  /// 覆盖 [relPath] 的挂载点（relPath 等于挂载点或在其下）。
  Future<WorkspaceMount?> covering(String space, String relPath) async {
    final norm = relPath.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (norm.isEmpty) return null;
    for (final m in await list()) {
      if (m.space != space) continue;
      if (norm == m.path || norm.startsWith('${m.path}/')) return m;
    }
    return null;
  }

  /// [relPath] 在挂载点内的剩余相对路径（等于挂载点时为空）。
  String restOf(WorkspaceMount mount, String relPath) {
    final norm = relPath.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    if (norm == mount.path) return '';
    return norm.substring(mount.path.length).replaceAll(RegExp(r'^/+'), '');
  }

  /// 挂载点内的相对路径 → 外部绝对路径；越界返回 null。
  String? externalPath(WorkspaceMount mount, String relPath) {
    final base = p.normalize(mount.external);
    final rest = restOf(mount, relPath);
    final abs = p.normalize(p.join(base, rest));
    if (!p.isWithin(base, abs)) return null;
    return abs;
  }
}
