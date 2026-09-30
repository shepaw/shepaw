/// Resolve chat markdown hrefs against mapped store workspaces.
///
/// Agents often emit `[docs/good.md](docs/good.md)` relative to cwd. The cwd
/// is mounted at `pouch://workspaces/<device>/<encoded-cwd>/`, so the default
/// open target is that store file — locally or on a paired app.
library;

import 'store_protocol.dart';

final _absoluteHref = RegExp(r'^(?:[a-z][a-z0-9+.-]*:|//|#)', caseSensitive: false);

bool isRelativeWorkspaceHref(String href) {
  final trimmed = href.trim();
  if (trimmed.isEmpty || isPouchUri(trimmed)) return false;
  return !_absoluteHref.hasMatch(trimmed);
}

/// Join [rootUri] with a relative path. Returns null on `..` traversal.
String? joinStoreUri(String rootUri, String relPath) {
  final root = rootUri.trim().replaceAll(RegExp(r'/+$'), '');
  if (!isPouchUri(root)) return null;
  var rel = relPath.trim().replaceAll('\\', '/');
  if (rel.startsWith('./')) rel = rel.substring(2);
  rel = rel.replaceFirst(RegExp(r'^/+'), '');
  if (rel.isEmpty) return root;
  final parts = <String>[];
  for (final seg in rel.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') return null;
    parts.add(seg);
  }
  if (parts.isEmpty) return root;
  return '$root/${parts.join('/')}';
}

/// Map a markdown href onto the first usable workspace root.
///
/// - `pouch://…` is returned as-is
/// - http(s)/mailto/anchors are skipped (caller uses url_launcher)
/// - relative paths join [workspaceRoots]
String? resolveWorkspaceHref(String href, Iterable<String> workspaceRoots) {
  final trimmed = href.trim();
  if (trimmed.isEmpty) return null;
  if (isPouchUri(trimmed)) return trimmed;
  if (!isRelativeWorkspaceHref(trimmed)) return null;
  for (final root in workspaceRoots) {
    final joined = joinStoreUri(root, trimmed);
    if (joined != null) return joined;
  }
  return null;
}
