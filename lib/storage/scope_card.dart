/// Agent 储物袋作用域卡片（Scope Card）— 每轮唯一说明书。
///
/// 见 `.ai_workspace/AGENT_SCOPE_CARD_DESIGN.md`。
/// - [toStableMarkdown]：进 system / 会话级（spaces、commands、rules）
/// - [toVolatileMarkdown]：随轮次任务（injected 摘要、extra_uris）
library;

import 'memory_paths.dart';
import 'runtime_paths.dart';

/// Scope Card 场景。
enum ScopeCardMode {
  dm,
  group,
  peer,
  workflow,
  acp,
}

/// 本轮注入状态（易变；默认只影响 volatile 文案）。
class ScopeCardInjected {
  const ScopeCardInjected({
    this.soul = ScopeInjectLevel.none,
    this.memoryEntries = ScopeInjectLevel.none,
    this.memoryEntryCount = 0,
    this.session = ScopeInjectLevel.none,
  });

  final ScopeInjectLevel soul;
  final ScopeInjectLevel memoryEntries;
  final int memoryEntryCount;
  final ScopeInjectLevel session;
}

enum ScopeInjectLevel { full, summary, topN, none, windowHint }

/// 读写能力开关。
class ScopeCardCapabilities {
  const ScopeCardCapabilities({
    this.readStore = true,
    this.writeArtifacts = true,
    this.writeSoul = true,
    this.writeMemory = true,
  });

  final bool readStore;
  final bool writeArtifacts;
  final bool writeSoul;
  final bool writeMemory;

  static const groupMember = ScopeCardCapabilities(
    writeSoul: false,
    writeMemory: false,
  );

  /// Peer P0：禁 memory-write（CLI 不写 peers/ 子树，避免歧义）。
  static const peerDefault = ScopeCardCapabilities(
    writeMemory: false,
  );
}

/// 结构化作用域卡片。
class ScopeCard {
  ScopeCard({
    required this.mode,
    required this.ownerId,
    required this.ownerKind,
    required this.deviceId,
    this.channelId,
    this.peerClientId,
    this.cognitionRootUri,
    this.soulUri,
    this.memoryEntriesUri,
    this.runtimeRootUri,
    this.manifestUri,
    this.workspaceUris = const [],
    this.injected = const ScopeCardInjected(),
    this.capabilities = const ScopeCardCapabilities(),
    this.extraUris = const [],
    this.schemaVersion = ScopeCard.currentSchemaVersion,
  });

  static const currentSchemaVersion = 1;

  final int schemaVersion;
  final ScopeCardMode mode;
  final String ownerId;
  final String ownerKind; // agent | group | device
  final String deviceId;
  final String? channelId;
  final String? peerClientId;

  final String? cognitionRootUri;
  final String? soulUri;
  final String? memoryEntriesUri;
  final String? runtimeRootUri;
  final String? manifestUri;
  final List<String> workspaceUris;

  final ScopeCardInjected injected;
  final ScopeCardCapabilities capabilities;
  final List<String> extraUris;

  // ── Factories ──────────────────────────────────────────────────────────

  /// 本机 / 外接 ACP 私聊（owner = agent）。
  factory ScopeCard.forAgentDm({
    required String agentId,
    required String deviceId,
    String? channelId,
    ScopeCardInjected injected = const ScopeCardInjected(
      soul: ScopeInjectLevel.full,
    ),
    bool writeMemory = true,
  }) {
    final cogRoot = MemoryPaths.uri(
      deviceId: deviceId,
      relPath: '${MemoryPaths.agentRoot(agentId)}/',
    );
    return ScopeCard(
      mode: ScopeCardMode.dm,
      ownerId: agentId,
      ownerKind: 'agent',
      deviceId: deviceId,
      channelId: channelId,
      cognitionRootUri: cogRoot,
      soulUri: MemoryPaths.uri(
        deviceId: deviceId,
        relPath: MemoryPaths.soulMd(agentId),
      ),
      memoryEntriesUri: MemoryPaths.uri(
        deviceId: deviceId,
        relPath: '${MemoryPaths.entriesDir(agentId)}/',
      ),
      runtimeRootUri: RuntimePaths.uri(
        deviceId: deviceId,
        relPath: RuntimePaths.runtimeRoot(agentId),
      ),
      manifestUri: RuntimePaths.uri(
        deviceId: deviceId,
        relPath: RuntimePaths.contextManifest(agentId),
      ),
      injected: injected,
      capabilities: ScopeCardCapabilities(writeMemory: writeMemory),
    );
  }

  /// Peer 中继 Agent：禁 memory-write；可读 URI 指向 peers 子树（若有 peerId）。
  factory ScopeCard.forPeerAgent({
    required String agentId,
    required String deviceId,
    required String peerClientId,
    String? channelId,
    ScopeCardInjected injected = const ScopeCardInjected(
      soul: ScopeInjectLevel.full,
    ),
  }) {
    final entriesRel =
        '${MemoryPaths.entriesDir(agentId, peerClientId: peerClientId)}/';
    return ScopeCard(
      mode: ScopeCardMode.peer,
      ownerId: agentId,
      ownerKind: 'agent',
      deviceId: deviceId,
      channelId: channelId,
      peerClientId: peerClientId,
      cognitionRootUri: MemoryPaths.uri(
        deviceId: deviceId,
        relPath: '${MemoryPaths.agentRoot(agentId)}/',
      ),
      soulUri: MemoryPaths.uri(
        deviceId: deviceId,
        relPath: MemoryPaths.soulMd(agentId),
      ),
      memoryEntriesUri: MemoryPaths.uri(
        deviceId: deviceId,
        relPath: entriesRel,
      ),
      runtimeRootUri: RuntimePaths.uri(
        deviceId: deviceId,
        relPath: RuntimePaths.runtimeRoot(agentId),
      ),
      manifestUri: RuntimePaths.uri(
        deviceId: deviceId,
        relPath: RuntimePaths.contextManifest(agentId),
      ),
      injected: injected,
      capabilities: ScopeCardCapabilities.peerDefault,
    );
  }

  /// 群：无个人 cognition URI；产物落到 group owner。
  factory ScopeCard.forGroup({
    required String groupId,
    required String deviceId,
    String? channelId,
    List<String> extraUris = const [],
  }) {
    return ScopeCard(
      mode: ScopeCardMode.group,
      ownerId: groupId,
      ownerKind: 'group',
      deviceId: deviceId,
      channelId: channelId,
      runtimeRootUri: RuntimePaths.uri(
        deviceId: deviceId,
        relPath: RuntimePaths.runtimeRoot(groupId),
      ),
      manifestUri: RuntimePaths.uri(
        deviceId: deviceId,
        relPath: RuntimePaths.contextManifest(groupId),
      ),
      injected: const ScopeCardInjected(),
      capabilities: ScopeCardCapabilities.groupMember,
      extraUris: extraUris,
    );
  }

  /// ACP / bridge 设备级卡（无 agent owner；与宿主 Scope Card schema 对齐）。
  factory ScopeCard.forAcpDevice({
    required String deviceId,
    String? workspaceUri,
  }) {
    return ScopeCard(
      mode: ScopeCardMode.acp,
      ownerId: deviceId,
      ownerKind: 'device',
      deviceId: deviceId,
      workspaceUris:
          workspaceUri != null && workspaceUri.isNotEmpty ? [workspaceUri] : const [],
      capabilities: const ScopeCardCapabilities(
        writeSoul: false,
        writeMemory: false,
      ),
    );
  }

  ScopeCard copyWith({
    ScopeCardInjected? injected,
    List<String>? extraUris,
    String? channelId,
  }) =>
      ScopeCard(
        schemaVersion: schemaVersion,
        mode: mode,
        ownerId: ownerId,
        ownerKind: ownerKind,
        deviceId: deviceId,
        channelId: channelId ?? this.channelId,
        peerClientId: peerClientId,
        cognitionRootUri: cognitionRootUri,
        soulUri: soulUri,
        memoryEntriesUri: memoryEntriesUri,
        runtimeRootUri: runtimeRootUri,
        manifestUri: manifestUri,
        workspaceUris: workspaceUris,
        injected: injected ?? this.injected,
        capabilities: capabilities,
        extraUris: extraUris ?? this.extraUris,
      );

  // ── Render ─────────────────────────────────────────────────────────────

  String get _modeLabel => switch (mode) {
        ScopeCardMode.dm => 'dm',
        ScopeCardMode.group => 'group',
        ScopeCardMode.peer => 'peer',
        ScopeCardMode.workflow => 'workflow',
        ScopeCardMode.acp => 'acp',
      };

  /// 稳定段：适合 system / 会话首包。
  String toStableMarkdown() {
    final buf = StringBuffer()
      ..writeln('## 当前储物袋作用域')
      ..writeln(
        '- schema: v$schemaVersion · mode: `$_modeLabel` · '
        'owner: `$ownerId` ($ownerKind)'
        '${channelId != null && channelId!.isNotEmpty ? ' · channel: `$channelId`' : ''}'
        '${peerClientId != null && peerClientId!.isNotEmpty ? ' · peer: `$peerClientId`' : ''}',
      )
      ..writeln('- device: `$deviceId`')
      ..writeln('- URI 形如 `store://<space>/<device_id>/<path>`');

    if (mode == ScopeCardMode.group) {
      buf.writeln(
        '- 本群**无**个人 `cognition/`（soul/记忆）；岗位与人格摘要见群身份段，'
        '禁止在本任务读写个人认知袋',
      );
    } else if (mode == ScopeCardMode.acp) {
      buf.writeln(
        '- 分区：`files` 沉淀 · `public` 公开引用 · `runtime` 会话产物 · '
        '`cognition` Soul/结构化记忆权威 · `workspaces` 工作区 · `backups` 本端灾备',
      );
      if (workspaceUris.isNotEmpty) {
        buf.writeln('- 工作区已挂载：`${workspaceUris.first}`');
      }
    } else {
      if (cognitionRootUri != null) {
        buf.writeln('- 认知权威: `$cognitionRootUri`');
      }
      if (soulUri != null) {
        final soulNote = injected.soul == ScopeInjectLevel.full
            ? '（soul 本轮已内嵌全文，勿再 store read）'
            : injected.soul == ScopeInjectLevel.summary
                ? '（soul 本轮已内嵌摘要）'
                : '（未内嵌；需要时 `shepaw store read --uri` 本 URI）';
        buf.writeln('- soul: `$soulUri`$soulNote');
      }
      if (memoryEntriesUri != null) {
        final memNote = mode == ScopeCardMode.peer
            ? '（读范围：peer 子树；禁止 memory-write）'
            : injected.memoryEntries == ScopeInjectLevel.topN
                ? '（本轮已内嵌最近条目）'
                : '（未内嵌；需要时 list/read 本 URI 或 memory-write 查询 CLI）';
        buf.writeln('- memory entries: `$memoryEntriesUri`$memNote');
      }
    }

    if (runtimeRootUri != null) {
      buf.writeln('- 产物/runtime: `$runtimeRootUri`');
    }
    if (manifestUri != null) {
      buf.writeln('- manifest: `$manifestUri`');
    }

    if (capabilities.readStore) {
      buf.writeln(
        '- 读: `shepaw store read --uri <uri-as-is>` · '
        '列: `shepaw store list --uri <uri> --depth 1`',
      );
    }
    if (capabilities.writeArtifacts) {
      buf.writeln(
        '- 写产物: `shepaw store write --filename <名> --content "..."`'
        '（可选 `--task` / `--desc` / `--space public`）；'
        '**不要**传 `agent_id` / `owner` / 个人 channel，由系统落到本作用域袋',
      );
    }
    if (capabilities.writeMemory) {
      buf.writeln(
        '- 写记忆: `shepaw context agents.memory-write --id $ownerId --content "..."`',
      );
    } else if (mode == ScopeCardMode.peer) {
      buf.writeln('- 写记忆: **禁止**（本 peer 回合不使用 memory-write）');
    }
    if (capabilities.writeSoul && mode != ScopeCardMode.group) {
      buf.writeln('- 写 Soul: 经既有 cognition/soul CLI（勿写 runtime 镜像）');
    }

    buf.writeln('- 禁止: 回写 `runtime/*/soul.md` 与 `memory.md` 镜像；编造 `store://`；'
        '用 `os.file.*` 读 store URI');
    if (mode == ScopeCardMode.group) {
      buf.writeln(
        '- 禁止: 把群产出写到 `runtime/<你的agentId>/` 或 `cognition/<你的agentId>/`',
      );
    }
    return buf.toString().trimRight();
  }

  /// 易变段：本轮 URI / 注入计数（随任务消息）。
  String toVolatileMarkdown() {
    final uris = <String>{
      if (manifestUri != null) manifestUri!,
      if (runtimeRootUri != null) runtimeRootUri!,
      ...extraUris.where((u) => u.isNotEmpty),
    };
    final lines = <String>[];
    if (mode == ScopeCardMode.group) {
      lines.add('- 本群 runtime 袋（非个人 cognition）；读写命令见 system 作用域卡');
    }
    if (injected.soul == ScopeInjectLevel.full) {
      lines.add('- soul: 已内嵌全文');
    } else if (injected.soul == ScopeInjectLevel.summary) {
      lines.add('- soul: 已内嵌摘要');
    }
    if (injected.memoryEntries == ScopeInjectLevel.topN ||
        injected.memoryEntryCount > 0) {
      lines.add('- memory: 已内嵌最近 ${injected.memoryEntryCount} 条');
    }
    if (uris.isNotEmpty) {
      lines.add('- 本轮 URI:');
      final sorted = uris.toList()..sort();
      for (final u in sorted) {
        lines.add('  - `$u`');
      }
      lines.add(
        '- 需要内容时用 `shepaw store read --uri …`；'
        '勿假设已内嵌 session/产物全文',
      );
    }
    if (lines.isEmpty) return '';
    return (StringBuffer()
          ..writeln('## 当前储物袋作用域 · 本轮')
          ..writeAll(lines.map((e) => '$e\n')))
        .toString()
        .trimRight();
  }

  /// 完整卡（stable + volatile）；测试或单段注入用。
  String toMarkdown() {
    final vol = toVolatileMarkdown();
    if (vol.isEmpty) return toStableMarkdown();
    return '${toStableMarkdown()}\n\n$vol';
  }

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'mode': _modeLabel,
        'owner_id': ownerId,
        'owner_kind': ownerKind,
        'device_id': deviceId,
        if (channelId != null) 'channel_id': channelId,
        if (peerClientId != null) 'peer_client_id': peerClientId,
        'spaces': {
          if (cognitionRootUri != null) 'cognition_root': cognitionRootUri,
          if (soulUri != null) 'soul_uri': soulUri,
          if (memoryEntriesUri != null)
            'memory_entries_uri': memoryEntriesUri,
          if (runtimeRootUri != null) 'runtime_root': runtimeRootUri,
          if (manifestUri != null) 'manifest_uri': manifestUri,
          if (workspaceUris.isNotEmpty) 'workspace_uris': workspaceUris,
        },
        'injected': {
          'soul': injected.soul.name,
          'memory_entries': injected.memoryEntries.name,
          'memory_entry_count': injected.memoryEntryCount,
          'session': injected.session.name,
        },
        'capabilities': {
          'read_store': capabilities.readStore,
          'write_artifacts': capabilities.writeArtifacts,
          'write_soul': capabilities.writeSoul,
          'write_memory': capabilities.writeMemory,
        },
        'extra_uris': extraUris,
      };

  /// URI 归一化键：去掉 `@ref` / query。
  static String normalizeUriKey(String uri) {
    var u = uri.trim();
    final q = u.indexOf('?');
    if (q >= 0) u = u.substring(0, q);
    final at = u.indexOf('@');
    if (at >= 0) u = u.substring(0, at);
    return u;
  }

  /// [ancestor] 是否为 [descendant] 的目录前缀（同 space/device 路径树）。
  static bool isAncestorStoreUri(String ancestor, String descendant) {
    final a = normalizeUriKey(ancestor);
    final d = normalizeUriKey(descendant);
    if (a.isEmpty || d.isEmpty || a == d) return false;
    final prefix = a.endsWith('/') ? a : '$a/';
    return d.startsWith(prefix);
  }

  /// 去重 + 前缀折叠：有文件级 URI 时去掉其祖先根 URI。
  ///
  /// 保留原始字符串（优先较短展示形式的第一次出现）。
  static List<String> dedupeUris(
    Iterable<String> uris, {
    int maxCount = 40,
  }) {
    final byKey = <String, String>{};
    for (final raw in uris) {
      final t = raw.trim();
      if (t.isEmpty || !t.startsWith('store://')) continue;
      final key = normalizeUriKey(t);
      byKey.putIfAbsent(key, () => t);
    }
    final keys = byKey.keys.toList()..sort();
    final drop = <String>{};
    for (final a in keys) {
      for (final b in keys) {
        if (a == b) continue;
        if (isAncestorStoreUri(a, b)) drop.add(a);
      }
    }
    final kept = keys.where((k) => !drop.contains(k)).toList()..sort();
    final out = [for (final k in kept) byKey[k]!];
    if (out.length > maxCount) return out.sublist(out.length - maxCount);
    return out;
  }

  /// 仅本轮 URI 列表的 volatile 段（不依赖完整 ScopeCard 实例）。
  static String volatileUrisMarkdown(Iterable<String> uris) {
    final list = dedupeUris(uris);
    if (list.isEmpty) return '';
    final buf = StringBuffer()
      ..writeln('## 当前储物袋作用域 · 本轮')
      ..writeln('- 本轮/近期 store URI（已归一化；需要内容时 `shepaw store read --uri …`）:')
      ..writeln('- 勿用 os.file 读 store://；历史消息不再重复长读法教程');
    for (final u in list) {
      buf.writeln('  - `$u`');
    }
    return buf.toString().trimRight();
  }
}
