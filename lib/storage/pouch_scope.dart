/// 储物袋 v3 的 scope 模型（对应 hub 的 `crates/pouch/src/v3/scope.rs`）。
///
/// 语法（A 1.1）：
/// - `pouch` / `system` / `public` / `files`：裸 scope，后面不能再带段；
/// - `group:<gid>`、`:shared`、`:member:<aid>`、`:session:<sid>`、
///   `:session:<sid>:task:<tid>`；
/// - `agent:<aid>`、`agent:<aid>:session:<sid>`；
/// - `skill:<name>` / `instruction:<name>` / `slip:<id>`。
///
/// id 只认 `[A-Za-z0-9_.-]`，`shared`/`session`/`task`/`member` 是关键字，
/// 不能当 id。调用方不要自己拼 scope 字符串：一律走这里的构造函数。
library;

/// id 允许的字符（hub 的 `is_id`）。袋子 id 也走这条。
bool isValidPouchScopeId(String value) =>
    value.isNotEmpty &&
    !_keywords.contains(value) &&
    RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value);

const Set<String> _keywords = {'shared', 'session', 'task', 'member'};

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
  slip('slip', '玉简');

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
  slip('玉简');

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
    }
  }

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

  // ── 解析 ─────────────────────────────────────────────────────────────────

  /// 不合语法返回 null。
  static PouchScope? tryParse(String text) {
    final value = text.trim();
    if (value.isEmpty) return null;
    final parts = value.split(':');
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
    if (head == 'skill' || head == 'instruction' || head == 'slip') {
      final name = _oneId(parts, 1);
      if (name == null || parts.length != 2) return null;
      return PouchScope._(value, _namedKind(head), name, null);
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
