/// 储物袋 v3 的 scope 模型（对应 hub 的 `crates/pouch/src/v3/scope.rs`）。
///
/// 语法（A 1.1）：
/// - `pouch` / `system` / `public` / `files`：裸 scope，后面不能再带段；
/// - `group:<gid>`、`:shared`、`:member:<aid>`、`:session:<sid>`、
///   `:session:<sid>:task:<tid>`；
/// - `agent:<aid>`、`agent:<aid>:session:<sid>`；
/// - `skill:<name>` / `instruction:<name>` / `slip:<id>`；
/// - `flow:<fid>`、`flow:<fid>:instance:<iid>`、
///   `flow:<fid>:instance:<iid>:run:<rid>`（三层工作流）；
/// - 旧形态：`run:<rid>`（旧运行区，没有父 scope）。
///
/// id 只认 `[A-Za-z0-9_.-]`，`shared`/`session`/`task`/`member` 是关键字，
/// 不能当 id；`instance`/`run` 是 flow scope 第 3/5 段的保留关键字，三层形态
/// 的 id 位置也不能用它们（旧的两段式别名不受限）。三层形态的 id 还必须是
/// `fl_<hex>` / `in_<hex>` / `run_<hex>`（小写 16 进制，至少一位）；两段式
/// `flow:<name>` / `run:<rid>` 仍沿用宽松解析，主机过渡期还在写它们。
/// 调用方不要自己拼 scope 字符串：一律走这里的构造函数。
library;

/// id 允许的字符（hub 的 `is_id`）。袋子 id 也走这条。
bool isValidPouchScopeId(String value) =>
    value.isNotEmpty &&
    !_keywords.contains(value) &&
    RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value);

const Set<String> _keywords = {'shared', 'session', 'task', 'member'};

/// 工作流三层的层级标记。形状校验已覆盖（id 必须是 `fl_`/`in_`/`run_` + hex），
/// 这里留作和主机一致的防御：三层形态的 id 位置不能放它们。
const Set<String> _flowKeywords = {'instance', 'run'};

/// 三层工作流 id 的后缀：小写 16 进制，至少一位。
final RegExp _lowerHex = RegExp(r'^[0-9a-f]+$');

/// 三层工作流 id 的形状校验，和 hub 的 `parse_flow` 对齐：`<prefix>_<hex>`。
/// `prefix` 只取生成约定里的 `fl` / `in` / `run`；hex 只认小写 `[0-9a-f]` 且
/// 至少一位。生产的 id 是 32/16/32 位，但解析器只卡前缀 + 字符集，长度由
/// 主机的 128 字节上限兜底。两段式别名（`flow:<name>` / `run:<rid>`）不走这里。
bool _isFlowId(String value, String prefix) {
  if (!value.startsWith('${prefix}_')) return false;
  final hex = value.substring(prefix.length + 1);
  return hex.isNotEmpty && _lowerHex.hasMatch(hex);
}

/// scope 的种类。和 hub 的 `ScopeKind` 一一对应。
enum PouchScopeKind {
  pouch('pouch', '袋子'),
  system('system', '系统'),
  public('public', '公开'),
  files('files', '文件'),
  group('group', '群'),
  shared('shared', '共享'),
  session('session', '会话'),
  task('task', '任务'),
  member('member', '成员'),
  agent('agent', '助手'),
  skill('skill', '技能'),
  instruction('instruction', '指令'),
  slip('slip', '玉简'),
  flow('flow', '流程'),
  instance('instance', '实例'),
  run('run', '运行');

  const PouchScopeKind(this.id, this.label);

  /// scope 里出现的那一段（`session`、`slip` …）。
  final String id;

  /// 展示用的名字，不带具体 id。
  final String label;
}

/// 浏览器按这一层分组：固定分区 + 各自带 id 的家族。
enum PouchScopeFamily {
  fixed('分区'),
  group('群'),
  agent('助手'),
  skill('技能'),
  instruction('指令'),
  slip('玉简'),
  flow('工作流');

  const PouchScopeFamily(this.label);

  final String label;
}

/// 一个已解析的 scope。
class PouchScope {
  const PouchScope._(this.id, this.kind, this.ownerId, this.parentId);

  /// 规范形式，就是 hub 侧 `scopes.id`；也是 URI 里的那一段。
  final String id;

  final PouchScopeKind kind;

  /// scope 归属的那个 id（群 id、会话 id、agent id …）；裸 scope 为空串。
  final String ownerId;

  /// 父 scope 的规范 id；裸 scope 为 null。
  final String? parentId;

  /// 浏览时用的一级路径段：`session:s1`、`task:t1` 这种（父 scope 下）。
  String get segment => switch (kind) {
        PouchScopeKind.task => 'task:$ownerId',
        PouchScopeKind.session => 'session:$ownerId',
        _ => ownerId,
      };

  PouchScopeFamily get family {
    switch (kind) {
      case PouchScopeKind.pouch:
      case PouchScopeKind.system:
      case PouchScopeKind.public:
      case PouchScopeKind.files:
        return PouchScopeFamily.fixed;
      case PouchScopeKind.group:
      case PouchScopeKind.shared:
      case PouchScopeKind.member:
        return PouchScopeFamily.group;
      case PouchScopeKind.agent:
        return PouchScopeFamily.agent;
      case PouchScopeKind.skill:
        return PouchScopeFamily.skill;
      case PouchScopeKind.instruction:
        return PouchScopeFamily.instruction;
      case PouchScopeKind.slip:
        return PouchScopeFamily.slip;
      case PouchScopeKind.session:
      case PouchScopeKind.task:
        // 会话/任务跟着父 scope 走：agent:<aid>:session:* 仍属于助手。
        final parent = parentId ?? '';
        return parent.startsWith('agent:')
            ? PouchScopeFamily.agent
            : PouchScopeFamily.group;
      case PouchScopeKind.flow:
      case PouchScopeKind.instance:
      case PouchScopeKind.run:
        // 整个 flow: 家族（含旧 run:<rid>）单独一组，浏览器按
        // 模板 → 实例 → 运行 缩进展开。
        return PouchScopeFamily.flow;
    }
  }

  /// 工作流树里的层级：0 = 模板 / 旧 run，1 = 实例，2 = 运行。
  int get flowDepth => switch (kind) {
        PouchScopeKind.instance => 1,
        PouchScopeKind.run when parentId != null => 2,
        _ => 0,
      };

  /// 展示名：`文件`、`群 g1 · 共享`、`会话 s1`…（不含路径）。
  String get displayName => switch (kind) {
        PouchScopeKind.pouch ||
        PouchScopeKind.system ||
        PouchScopeKind.public ||
        PouchScopeKind.files =>
          kind.label,
        PouchScopeKind.shared =>
          '${PouchScopeKind.group.label} $ownerId · ${kind.label}',
        PouchScopeKind.session => '${kind.label} $ownerId',
        _ => '${kind.label} $ownerId',
      };

  /// 父 scope；父 id 非法（不该发生）时为 null。
  PouchScope? get parent {
    final id = parentId;
    return id == null ? null : tryParse(id);
  }

  String format() => id;

  @override
  String toString() => id;

  @override
  bool operator ==(Object other) => other is PouchScope && other.id == id;

  @override
  int get hashCode => id.hashCode;

  // ── 固定 scope ────────────────────────────────────────────────────────────
  static const pouch = PouchScope._('pouch', PouchScopeKind.pouch, '', null);
  static const system = PouchScope._('system', PouchScopeKind.system, '', null);
  static const public = PouchScope._('public', PouchScopeKind.public, '', null);
  static const files = PouchScope._('files', PouchScopeKind.files, '', null);

  /// 顶层永远可用的四个 scope（其余家族要先知道 id）。
  static const List<PouchScope> fixed = [pouch, system, public, files];

  // ── 构造：参数不合法时抛 [FormatException]（bad_scope）───────────────────
  static PouchScope group(String groupId) {
    _requireId(groupId);
    return _checked('group:$groupId', PouchScopeKind.group, groupId, null);
  }

  static PouchScope groupShared(String groupId) {
    _requireId(groupId);
    return _checked(
      'group:$groupId:shared',
      PouchScopeKind.shared,
      groupId,
      'group:$groupId',
    );
  }

  static PouchScope groupMember(String groupId, String agentId) {
    _requireId(groupId);
    _requireId(agentId);
    return _checked(
      'group:$groupId:member:$agentId',
      PouchScopeKind.member,
      agentId,
      'group:$groupId',
    );
  }

  static PouchScope groupSession(String groupId, String sessionId) {
    _requireId(groupId);
    return _checked(
      'group:$groupId:session:$sessionId',
      PouchScopeKind.session,
      sessionId,
      'group:$groupId',
    );
  }

  static PouchScope groupTask(
    String groupId,
    String sessionId,
    String taskId,
  ) {
    _requireId(groupId);
    _requireId(sessionId);
    return _checked(
      'group:$groupId:session:$sessionId:task:$taskId',
      PouchScopeKind.task,
      taskId,
      'group:$groupId:session:$sessionId',
    );
  }

  static PouchScope agent(String agentId) =>
      _checked('agent:$agentId', PouchScopeKind.agent, agentId, null);

  static PouchScope agentSession(String agentId, String sessionId) {
    _requireId(agentId);
    return _checked(
      'agent:$agentId:session:$sessionId',
      PouchScopeKind.session,
      sessionId,
      'agent:$agentId',
    );
  }

  static PouchScope skill(String name) =>
      _checked('skill:$name', PouchScopeKind.skill, name, null);

  static PouchScope instruction(String name) =>
      _checked('instruction:$name', PouchScopeKind.instruction, name, null);

  static PouchScope slip(String id) =>
      _checked('slip:$id', PouchScopeKind.slip, id, null);

  /// 三层工作流：`flow:<fid>` → `flow:<fid>:instance:<iid>` →
  /// `flow:<fid>:instance:<iid>:run:<rid>`，后两层的父 scope 分别是上一层。
  static PouchScope flow(String flowId) =>
      _checked('flow:$flowId', PouchScopeKind.flow, flowId, null);

  static PouchScope flowInstance(String flowId, String instanceId) {
    _requireFlowId(flowId, 'fl');
    _requireFlowId(instanceId, 'in');
    return _checked(
      'flow:$flowId:instance:$instanceId',
      PouchScopeKind.instance,
      instanceId,
      'flow:$flowId',
    );
  }

  static PouchScope flowRun(
    String flowId,
    String instanceId,
    String runId,
  ) {
    _requireFlowId(flowId, 'fl');
    _requireFlowId(instanceId, 'in');
    _requireFlowId(runId, 'run');
    return _checked(
      'flow:$flowId:instance:$instanceId:run:$runId',
      PouchScopeKind.run,
      runId,
      'flow:$flowId:instance:$instanceId',
    );
  }

  /// 旧的两段式运行 scope。主机切到三层树之前仍在写它，所以解析层继续认；
  /// 新代码构造运行地址一律走 [flowRun]。
  static PouchScope legacyRun(String runId) =>
      _checked('run:$runId', PouchScopeKind.run, runId, null);

  static PouchScope _checked(
    String id,
    PouchScopeKind kind,
    String ownerId,
    String? parentId,
  ) {
    if (!isValidPouchScopeId(ownerId)) {
      throw FormatException('bad_scope: invalid id $ownerId');
    }
    return PouchScope._(id, kind, ownerId, parentId);
  }

  /// 父 scope 里的 id 也要校验：`group:<gid>:session:<sid>` 两段都得合法。
  static void _requireId(String value) {
    if (!isValidPouchScopeId(value)) {
      throw FormatException('bad_scope: invalid id $value');
    }
  }

  /// 三层工作流构造函数的 id：形状必须是 `<prefix>_<hex>`（见 [_isFlowId]），
  /// 并额外挡掉 `instance` / `run` 两个层级标记（形状校验已覆盖，留作防御）。
  /// 两段式 `flow` / `legacyRun` 不走这里，仍保持宽松。
  static void _requireFlowId(String value, String prefix) {
    if (!isValidPouchScopeId(value) ||
        !_isFlowId(value, prefix) ||
        _flowKeywords.contains(value)) {
      throw FormatException('bad_scope: invalid id $value');
    }
  }

  // ── 解析 ─────────────────────────────────────────────────────────────────

  /// 不合语法返回 null。和 hub 的 `parse_scope` 对齐：不 trim（主机不认带空格的
  /// scope）；三层 flow 树超过 `protocol.rs` 128 字节前缀上限时拒绝。老群任务
  /// scope 本来就可能超过 128 字节，它们靠短前缀列举，不在这里卡。
  static PouchScope? tryParse(String text) {
    const maxFlowScopeIdBytes = 128;
    if (text.isEmpty) return null;
    if (text.length > maxFlowScopeIdBytes &&
        text.startsWith('flow:') &&
        text.contains(':instance:')) {
      return null;
    }
    final parts = text.split(':');
    final head = parts.first;
    if (head == 'pouch' ||
        head == 'system' ||
        head == 'public' ||
        head == 'files') {
      if (parts.length != 1) return null;
      return switch (head) {
        'pouch' => pouch,
        'system' => system,
        'public' => public,
        _ => files,
      };
    }
    if (head == 'group') return _parseGroup(parts);
    if (head == 'agent') return _parseAgent(parts);
    if (head == 'flow') return _parseFlow(parts);
    if (head == 'skill' ||
        head == 'instruction' ||
        head == 'slip' ||
        head == 'run') {
      final name = _oneId(parts, 1);
      if (name == null || parts.length != 2) return null;
      return PouchScope._(text, _namedKind(head), name, null);
    }
    return null;
  }

  /// 不合语法抛 `FormatException('bad_scope: ...')`。
  static PouchScope parse(String text) {
    final parsed = tryParse(text);
    if (parsed == null) {
      throw FormatException('bad_scope: $text');
    }
    return parsed;
  }

  static PouchScopeKind _namedKind(String head) => switch (head) {
        'skill' => PouchScopeKind.skill,
        'instruction' => PouchScopeKind.instruction,
        'run' => PouchScopeKind.run,
        _ => PouchScopeKind.slip,
      };

  static String? _oneId(List<String> parts, int index) {
    if (index >= parts.length) return null;
    final value = parts[index];
    return isValidPouchScopeId(value) ? value : null;
  }

  static PouchScope? _parseGroup(List<String> parts) {
    final gid = _oneId(parts, 1);
    if (gid == null) return null;
    final groupId = 'group:$gid';
    if (parts.length == 2) {
      return PouchScope._(groupId, PouchScopeKind.group, gid, null);
    }
    switch (parts[2]) {
      case 'shared':
        if (parts.length != 3) return null;
        return PouchScope._(
          '$groupId:shared',
          PouchScopeKind.shared,
          gid,
          groupId,
        );
      case 'member':
        final aid = _oneId(parts, 3);
        if (aid == null || parts.length != 4) return null;
        return PouchScope._(
          '$groupId:member:$aid',
          PouchScopeKind.member,
          aid,
          groupId,
        );
      case 'session':
        final sid = _oneId(parts, 3);
        if (sid == null) return null;
        final sessionId = '$groupId:session:$sid';
        if (parts.length == 4) {
          return PouchScope._(
            sessionId,
            PouchScopeKind.session,
            sid,
            groupId,
          );
        }
        if (parts[4] != 'task') return null;
        final tid = _oneId(parts, 5);
        if (tid == null || parts.length != 6) return null;
        return PouchScope._(
          '$sessionId:task:$tid',
          PouchScopeKind.task,
          tid,
          sessionId,
        );
      default:
        return null;
    }
  }

  /// `flow:<fid>` / `flow:<fid>:instance:<iid>` /
  /// `flow:<fid>:instance:<iid>:run:<rid>`。`instance`、`run` 分别是第 3、5
  /// 段的保留关键字（不是 id），也不能占三层形态的 id 位置；其余形状一律不认。
  /// 三段以上（含 `:instance:` / `:run:` 尾）时三个 id 必须按 [_isFlowId]
  /// 走 `<prefix>_<hex>` 的形状；两段式 `flow:<name>` 是旧别名，形状不限。
  /// 写法照 `_parseGroup`，并与 hub 的 `parse_flow` 对齐。
  static PouchScope? _parseFlow(List<String> parts) {
    final fid = _oneId(parts, 1);
    if (fid == null) return null;
    final flowId = 'flow:$fid';
    // 旧公共流程库也是两段式 flow:<name>，id 形状不限，这里一并兼容。
    if (parts.length == 2) {
      return PouchScope._(flowId, PouchScopeKind.flow, fid, null);
    }
    // 三层形态的 id 位置只认生成约定：fl_/in_/run_ + 小写 hex。
    if (!_isFlowId(fid, 'fl')) return null;
    // 层级标记不能落到 id 位置：flow:run:instance:in_1 之类（形状校验已覆盖，
    // 这里保留和 hub 一致的防御）。
    if (_flowKeywords.contains(fid)) return null;
    switch (parts[2]) {
      case 'instance':
        final iid = _oneId(parts, 3);
        if (iid == null || !_isFlowId(iid, 'in')) return null;
        if (_flowKeywords.contains(iid)) return null;
        final instanceId = '$flowId:instance:$iid';
        if (parts.length == 4) {
          return PouchScope._(
            instanceId,
            PouchScopeKind.instance,
            iid,
            flowId,
          );
        }
        if (parts[4] != 'run') return null;
        final rid = _oneId(parts, 5);
        if (rid == null ||
            !_isFlowId(rid, 'run') ||
            _flowKeywords.contains(rid) ||
            parts.length != 6) {
          return null;
        }
        return PouchScope._(
          '$instanceId:run:$rid',
          PouchScopeKind.run,
          rid,
          instanceId,
        );
      default:
        return null;
    }
  }

  static PouchScope? _parseAgent(List<String> parts) {
    final aid = _oneId(parts, 1);
    if (aid == null) return null;
    final agentId = 'agent:$aid';
    if (parts.length == 2) {
      return PouchScope._(agentId, PouchScopeKind.agent, aid, null);
    }
    if (parts[2] != 'session' || parts.length != 4) return null;
    final sid = _oneId(parts, 3);
    if (sid == null) return null;
    return PouchScope._(
      '$agentId:session:$sid',
      PouchScopeKind.session,
      sid,
      agentId,
    );
  }
}

/// 一组同家族的 scope（浏览器的一行）。固定分区排最前。
class PouchScopeGroup {
  const PouchScopeGroup({required this.family, required this.scopes});

  final PouchScopeFamily family;
  final List<PouchScope> scopes;

  String get label => family.label;

  /// 家族里只有这个 kind 时的标题（`群` / `助手会话` …）。
  String get subtitle => switch (family) {
        PouchScopeFamily.fixed => '袋子固定分区',
        PouchScopeFamily.group => '群与它们的会话、任务',
        PouchScopeFamily.agent => '每个助手的私有区',
        PouchScopeFamily.skill => '技能包',
        PouchScopeFamily.instruction => '指令集',
        PouchScopeFamily.slip => '玉简',
        PouchScopeFamily.flow => '模板 → 实例 → 运行',
      };
}

/// 把一批 scope 归到家族里；固定分区永远在最前，其余按 label 排。
List<PouchScopeGroup> groupPouchScopes(Iterable<PouchScope> scopes) {
  final buckets = <PouchScopeFamily, List<PouchScope>>{};
  for (final scope in scopes) {
    buckets.putIfAbsent(scope.family, () => <PouchScope>[]).add(scope);
  }
  final out = <PouchScopeGroup>[];
  for (final family in PouchScopeFamily.values) {
    final items = buckets[family];
    if (items == null || items.isEmpty) continue;
    if (family == PouchScopeFamily.fixed) {
      // 固定分区按 pouch/system/public/files 的固定顺序，不按字母排。
      const order = {
        'pouch': 0,
        'system': 1,
        'public': 2,
        'files': 3,
      };
      items.sort((a, b) => (order[a.id] ?? 9).compareTo(order[b.id] ?? 9));
    } else {
      items.sort((a, b) => a.id.compareTo(b.id));
    }
    out.add(PouchScopeGroup(family: family, scopes: items));
  }
  return out;
}
