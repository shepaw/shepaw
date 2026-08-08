/// 本机储物袋分享给某配对设备的一条允许项。
///
/// [path] 为空字符串表示整区；非空为相对 path 前缀（含子路径）。
class PeerStoreShareEntry {
  final String space;
  final String path;
  final bool shared;

  const PeerStoreShareEntry({
    required this.space,
    this.path = '',
    this.shared = true,
  });

  bool get isWholeSpace => path.isEmpty;

  Map<String, dynamic> toAnnounceJson() => <String, dynamic>{
        'space': space,
        if (path.isNotEmpty) 'path': path,
      };

  factory PeerStoreShareEntry.fromAnnounceJson(Map<String, dynamic> json) {
    return PeerStoreShareEntry(
      space: json['space'] as String? ?? '',
      path: (json['path'] as String?) ?? '',
      shared: true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PeerStoreShareEntry &&
      other.space == space &&
      other.path == path &&
      other.shared == shared;

  @override
  int get hashCode => Object.hash(space, path, shared);
}

/// 分享白名单：按 space → 整区或 path 前缀集合。
class PeerStoreShareAllowlist {
  /// space → null 表示整区；非 null 为允许的 path 前缀集合（空集合 = 该 space 未分享）。
  final Map<String, Set<String>?> _bySpace;

  const PeerStoreShareAllowlist(this._bySpace);

  factory PeerStoreShareAllowlist.empty() =>
      const PeerStoreShareAllowlist(<String, Set<String>?>{});

  factory PeerStoreShareAllowlist.fromEntries(
      Iterable<PeerStoreShareEntry> entries) {
    final map = <String, Set<String>?>{};
    for (final e in entries) {
      if (!e.shared || e.space.isEmpty) continue;
      if (e.isWholeSpace) {
        map[e.space] = null;
        continue;
      }
      if (map[e.space] == null && map.containsKey(e.space)) {
        // already whole-space
        continue;
      }
      final set = map.putIfAbsent(e.space, () => <String>{}) ?? <String>{};
      if (map[e.space] == null) continue; // whole
      set.add(_normalizePrefix(e.path));
      map[e.space] = set;
    }
    return PeerStoreShareAllowlist(map);
  }

  /// owner 默认：files + artifacts 整区。
  factory PeerStoreShareAllowlist.ownerDefaults() =>
      PeerStoreShareAllowlist.fromEntries(const [
        PeerStoreShareEntry(space: 'files'),
        PeerStoreShareEntry(space: 'artifacts'),
      ]);

  bool get isEmpty => _bySpace.isEmpty;

  Iterable<String> get spaces => _bySpace.keys;

  bool isWholeSpace(String space) =>
      _bySpace.containsKey(space) && _bySpace[space] == null;

  Set<String> pathPrefixes(String space) =>
      _bySpace[space] ?? const <String>{};

  List<PeerStoreShareEntry> toEntries() {
    final out = <PeerStoreShareEntry>[];
    for (final e in _bySpace.entries) {
      if (e.value == null) {
        out.add(PeerStoreShareEntry(space: e.key));
      } else {
        for (final p in e.value!) {
          out.add(PeerStoreShareEntry(space: e.key, path: p));
        }
      }
    }
    out.sort((a, b) {
      final c = a.space.compareTo(b.space);
      if (c != 0) return c;
      return a.path.compareTo(b.path);
    });
    return out;
  }

  /// 跨端读请求是否命中白名单。
  ///
  /// [path] 为相对路径（无首尾 `/`）；空串表示分区根 list。
  bool allows(String space, String? path) {
    if (!_bySpace.containsKey(space)) return false;
    final prefixes = _bySpace[space];
    if (prefixes == null) return true; // whole space
    if (prefixes.isEmpty) return false;
    final p = _normalizePrefix(path ?? '');
    // 分区根 list：允许（结果由服务侧按前缀过滤）
    if (p.isEmpty) return true;
    for (final prefix in prefixes) {
      if (p == prefix || p.startsWith('$prefix/')) return true;
      // 允许查询前缀本身的父路径？仅精确/子路径；顶层名等于某前缀首段时由 list 过滤
      if (prefix.startsWith('$p/')) return true;
    }
    return false;
  }

  /// list 分区根时，过滤条目 path（相对分区）。
  bool allowsListedPath(String space, String entryPath) {
    if (!_bySpace.containsKey(space)) return false;
    final prefixes = _bySpace[space];
    if (prefixes == null) return true;
    final p = _normalizePrefix(entryPath);
    if (p.isEmpty) return false;
    final top = p.split('/').first;
    for (final prefix in prefixes) {
      if (prefix == top ||
          prefix.startsWith('$top/') ||
          p == prefix ||
          p.startsWith('$prefix/')) {
        return true;
      }
    }
    return false;
  }

  static String _normalizePrefix(String path) {
    var p = path.trim();
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
}
