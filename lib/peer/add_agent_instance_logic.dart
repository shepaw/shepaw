/// 可用的排在前面，同一组里保持主机原来的顺序。
List<T> sortEnginesUnavailableLast<T>(
  Iterable<T> engines,
  bool Function(T engine) available,
) {
  final ready = <T>[];
  final missing = <T>[];
  for (final engine in engines) {
    if (available(engine)) {
      ready.add(engine);
    } else {
      missing.add(engine);
    }
  }
  return [...ready, ...missing];
}

bool _subsequence(String haystack, String query) {
  var index = 0;
  for (final char in query.split('')) {
    index = haystack.indexOf(char, index);
    if (index < 0) return false;
    index += 1;
  }
  return true;
}

/// 按 id 和名字做不区分大小写的子串或子序列匹配。空查询匹配全部。
bool matchEngineKeyword({
  required String id,
  required String name,
  required String query,
}) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return true;
  for (final field in [id, name]) {
    final haystack = field.toLowerCase();
    if (haystack.contains(needle) || _subsequence(haystack, needle)) {
      return true;
    }
  }
  return false;
}

/// 去掉末尾的 `/` 或 `\`，用来比较是不是同一条路径。
String normalizeCwd(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return trimmed;
  final stripped = trimmed.replaceAll(RegExp(r'[\\/]+$'), '');
  return stripped.isEmpty ? trimmed : stripped;
}

/// 最新的放前面，按归一化路径去重，最多留 [max] 条。
List<String> rememberCwd(
  List<String> history,
  String path, {
  int max = 30,
}) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return history.take(max).toList();
  final key = normalizeCwd(trimmed);
  final next = <String>[
    trimmed,
    for (final item in history)
      if (normalizeCwd(item) != key) item,
  ];
  return next.take(max).toList();
}

/// 本地历史在前，这台设备上已有实例的目录接在后面，同样去重。
List<String> mergeCwdSuggestions(
  List<String> history,
  Iterable<String> instanceCwds,
) {
  final seen = history.map(normalizeCwd).toSet();
  final extras = <String>[];
  for (final raw in instanceCwds) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    final key = normalizeCwd(trimmed);
    if (!seen.add(key)) continue;
    extras.add(trimmed);
  }
  return [...history, ...extras];
}

/// 工作目录的最后一段。用户没改过名称时用它当默认名。
String directoryBasename(String path) {
  final normalized = path.trim().replaceAll('\\', '/');
  final stripped = normalized.replaceAll(RegExp(r'/+$'), '');
  if (stripped.isEmpty) return normalized.trim();
  final slash = stripped.lastIndexOf('/');
  return slash < 0 ? stripped : stripped.substring(slash + 1);
}

/// 提交前去掉空行，以及和工作目录相同的项。
List<String> cleanAdditionalDirectories(String cwd, Iterable<String> raw) {
  final home = normalizeCwd(cwd);
  final seen = <String>{};
  final out = <String>[];
  for (final item in raw) {
    final trimmed = item.trim();
    if (trimmed.isEmpty) continue;
    final key = normalizeCwd(trimmed);
    if (key.isEmpty || key == home || !seen.add(key)) continue;
    out.add(trimmed);
  }
  return out;
}
