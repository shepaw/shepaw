/// Agent 认知（Soul + 结构化记忆）在储物袋 v3 里的路径约定。
///
/// 权威 scope：`agent:<agentId>`（见 [scopeFor]）。
///
/// 落点与 hub 的 `v3::layout` 对齐：
/// - `identity/soul.md`、`identity/profile.json`；
/// - `identity/face_vectors/<photo_id>.json`；
/// - `memory/memory.json`、`memory/long_term_memory.md`；
/// - `memory/inference/0000.jsonl`（log）；
/// - `derived/resume.md`（可重建）。
///
/// App 自己的结构化记忆与状态：
/// - `memory/entries/<id>.json`；
/// - `memory/meta.json`。
///
/// 配对设备经 peer 中继写入的子记忆按 peerId 隔离到
/// `memory/peers/<peerId>/…`。
///
/// 下方 `legacy*` 只给一次性 v2 → v3 迁移用，新代码不要读写。
library;

import 'pouch_scope.dart';
import 'runtime_paths.dart';
import 'store_protocol.dart';

class MemoryPaths {
  MemoryPaths._();

  /// 文件系统 / 显示用的 agent 目录名。
  static String agentRoot(String agentId) =>
      RuntimePaths.sanitizeSegment(agentId);

  /// v3 scope 里的 agent id。hub 只接受 `[A-Za-z0-9_.-]`。
  static String agentScopeId(String agentId) =>
      agentRoot(agentId).replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');

  static PouchScope scopeFor(String agentId) =>
      PouchScope.agent(agentScopeId(agentId));

  // ── v3 落点 ───────────────────────────────────────────────────────────

  static String soulPath() => 'identity/soul.md';

  static String profilePath() => 'identity/profile.json';

  static String faceVectorsDir() => 'identity/face_vectors';

  static String faceVectorPath(String photoId) =>
      '${faceVectorsDir()}/${RuntimePaths.sanitizeSegment(photoId)}.json';

  static String resumePath() => 'derived/resume.md';

  /// 本机：`memory`；peer 子记忆：`memory/peers/<peerId>`。
  static String memoryRoot({String? peerClientId}) {
    final peer = peerClientId?.trim();
    if (peer == null || peer.isEmpty) return 'memory';
    return 'memory/peers/${RuntimePaths.sanitizeSegment(peer)}';
  }

  /// peer 子树根（含 v2 迁移判断用）。
  static String peerRoot(String agentId, String peerId) =>
      '${agentRoot(agentId)}/peers/${RuntimePaths.sanitizeSegment(peerId)}';

  static String metaPath({String? peerClientId}) =>
      '${memoryRoot(peerClientId: peerClientId)}/meta.json';

  static String entriesDir({String? peerClientId}) =>
      '${memoryRoot(peerClientId: peerClientId)}/entries';

  static String entryPath(int memoryId, {String? peerClientId}) =>
      '${entriesDir(peerClientId: peerClientId)}/$memoryId.json';

  static String memoryJsonPath() => 'memory/memory.json';

  static String longTermMemoryPath() => 'memory/long_term_memory.md';

  static String inferencePath() => 'memory/inference/0000.jsonl';

  /// App 私有派生状态（未对齐 hub 布局的旧文件也落在这里）。
  static String appDerivedDir({String? peerClientId}) {
    final root = memoryRoot(peerClientId: peerClientId);
    return root == 'memory' ? 'derived/app-memory' : '$root/derived/app-memory';
  }

  static String appDerivedPath(String relPath, {String? peerClientId}) {
    final rel = normalizeStorePath(relPath);
    return '${appDerivedDir(peerClientId: peerClientId)}/$rel';
  }

  /// v3 地址。路径留空表示 scope 根。
  static String uriFor({
    required String pouchId,
    required String agentId,
    required String path,
  }) =>
      PouchV2Uri(
        pouchId: pouchId,
        scope: scopeFor(agentId).id,
        path: path,
      ).format();

  static String soulUri(String pouchId, String agentId) =>
      uriFor(pouchId: pouchId, agentId: agentId, path: soulPath());

  static String resumeUri(String pouchId, String agentId) =>
      uriFor(pouchId: pouchId, agentId: agentId, path: resumePath());

  /// 把 v2 `cognition/<aid>/…`（或 legacy `memory/<aid>/…`）相对路径映射到
  /// v3 agent scope 内的路径。
  ///
  /// - 非 peer 实例跳过 `peers/` 子树（由对应的 peer 实例自己懒迁移）；
  /// - peer 实例只看自己的 `peers/<peerId>/` 子树；
  /// - 认不出的旧文件落到 App 派生目录，避免覆盖 hub 的约定文件。
  static String? v3PathForLegacy(
    String agentId,
    String relPath, {
    String? peerClientId,
  }) {
    final rel = normalizeStorePath(relPath);
    final root = agentRoot(agentId);
    final peer = peerClientId?.trim();

    if (peer != null && peer.isNotEmpty) {
      final prefix = '$root/peers/${RuntimePaths.sanitizeSegment(peer)}';
      if (rel == prefix) return null;
      if (!rel.startsWith('$prefix/')) return null;
      final tail = rel.substring(prefix.length + 1);
      if (tail.isEmpty) return null;
      return _mapPeerTail(peer, tail);
    }

    if (rel == root) return null;
    if (!rel.startsWith('$root/')) return null;
    final rest = rel.substring(root.length + 1);
    if (rest.isEmpty || rest.startsWith('peers/')) return null;
    return _mapAgentTail(rest);
  }

  static String _mapAgentTail(String rest) {
    if (rest == 'soul.md') return soulPath();
    if (rest == 'profile.json') return profilePath();
    if (rest.startsWith('face_vectors/')) {
      final tail = rest.substring('face_vectors/'.length);
      return tail.isEmpty ? faceVectorsDir() : '${faceVectorsDir()}/$tail';
    }
    if (rest == 'resume.md') return resumePath();
    if (rest == 'memory.json') return memoryJsonPath();
    if (rest == 'long_term_memory.md') return longTermMemoryPath();
    if (rest == 'inference.jsonl') return inferencePath();
    if (rest == 'meta.json') return metaPath();
    if (rest.startsWith('entries/')) {
      final tail = rest.substring('entries/'.length);
      return tail.isEmpty ? entriesDir() : '${entriesDir()}/$tail';
    }
    return appDerivedPath(rest);
  }

  static String _mapPeerTail(String peerId, String tail) {
    if (tail == 'meta.json') return metaPath(peerClientId: peerId);
    if (tail.startsWith('entries/')) {
      final file = tail.substring('entries/'.length);
      final dir = entriesDir(peerClientId: peerId);
      return file.isEmpty ? dir : '$dir/$file';
    }
    return appDerivedPath(tail, peerClientId: peerId);
  }

  // ── v2（只给迁移） ────────────────────────────────────────────────────

  static String legacyScopedRoot(String agentId, {String? peerClientId}) {
    final peer = peerClientId?.trim();
    if (peer == null || peer.isEmpty) return agentRoot(agentId);
    return peerRoot(agentId, peer);
  }

  static String legacyMetaJson(String agentId, {String? peerClientId}) =>
      '${legacyScopedRoot(agentId, peerClientId: peerClientId)}/meta.json';

  static String legacyEntriesDir(String agentId, {String? peerClientId}) =>
      '${legacyScopedRoot(agentId, peerClientId: peerClientId)}/entries';

  static String legacyEntryJson(
    String agentId,
    int memoryId, {
    String? peerClientId,
  }) =>
      '${legacyEntriesDir(agentId, peerClientId: peerClientId)}/$memoryId.json';

  static String legacySoulMd(String agentId) =>
      '${agentRoot(agentId)}/soul.md';

  static String legacyResumeMd(String agentId) =>
      '${agentRoot(agentId)}/resume.md';
}
