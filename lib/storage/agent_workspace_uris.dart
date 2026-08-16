import '../models/remote_agent.dart';
import 'device_identity.dart';
import 'store_protocol.dart';
import 'workspace_binding_service.dart';

final _deviceFirstWorkspace = RegExp(
  r'^store://([a-f0-9]{16})/workspaces(?:/(.*))?$',
  caseSensitive: false,
);

/// Normalize a Hub/App workspace URI to space-first `store://workspaces/<device>/…`.
///
/// Also accepts the on-disk device-first form `store://<device>/workspaces/…`
/// that some UIs copy from the store tree.
String? canonicalizeStoreWorkspaceUri(String raw) {
  final uri = raw.trim();
  if (!uri.startsWith('store://')) return null;
  final deviceFirst = _deviceFirstWorkspace.firstMatch(uri);
  if (deviceFirst != null) {
    final device = deviceFirst.group(1)!.toLowerCase();
    final rest = (deviceFirst.group(2) ?? '').replaceAll(RegExp(r'/+$'), '');
    return rest.isEmpty
        ? 'store://workspaces/$device/'
        : 'store://workspaces/$device/$rest/';
  }
  return uri.endsWith('/') ? uri : '$uri/';
}

String? _workspaceUriFromValue(Object? value) {
  if (value is! String) return null;
  return canonicalizeStoreWorkspaceUri(value);
}

/// Collect unique `store://workspaces/…` roots advertised on [metadata].
List<String> workspaceUrisFromMetadata(Map<String, dynamic> metadata) {
  final out = <String>[];
  final seen = <String>{};

  void add(Object? value) {
    final uri = _workspaceUriFromValue(value);
    if (uri == null) return;
    final key = uri.replaceAll(RegExp(r'/+$'), '');
    if (key.isEmpty || !seen.add(key)) return;
    out.add(uri);
  }

  add(metadata['workspace_uri']);
  add(metadata['workspaceUri']);
  final list = metadata['workspace_uris'] ?? metadata['workspaceUris'];
  if (list is List) {
    for (final item in list) {
      add(item);
    }
  }
  return out;
}

/// Metadata advertised URIs plus locally bound `workspaces/<id>` roots.
Future<List<String>> collectAgentWorkspaceUris(RemoteAgent agent) async {
  final out = workspaceUrisFromMetadata(agent.metadata);
  final seen = out.map((u) => u.replaceAll(RegExp(r'/+$'), '')).toSet();
  try {
    final ids = await WorkspaceBindingService.instance.loadBoundIds(agent.id);
    if (ids.isEmpty) return out;
    final deviceId = await DeviceIdentity.deviceId();
    for (final id in ids) {
      final uri = storeUriWithRef(StoreSpace.workspaces, deviceId, id);
      final key = uri.replaceAll(RegExp(r'/+$'), '');
      if (seen.add(key)) out.add('$uri/');
    }
  } catch (_) {
    /* store may be unavailable in tests / early boot */
  }
  return out;
}

/// Pick the URI to open from an agent-detail "view workspace" tap.
String? primaryWorkspaceUri(Iterable<String> uris) {
  for (final uri in uris) {
    final trimmed = uri.trim();
    if (trimmed.startsWith('store://')) return trimmed;
  }
  return null;
}

/// Decode a `store://workspaces/<device>/…` URI back to a host absolute path.
///
/// Hub encodes `/Users/foo` → `Users/foo` and `C:/Users/foo` → `C/Users/foo`.
String? absolutePathFromWorkspaceUri(String rawUri) {
  final uri = canonicalizeStoreWorkspaceUri(rawUri);
  if (uri == null) return null;
  try {
    final parsed = parseStoreUri(uri, allowEmptyPath: true);
    if (parsed.space != StoreSpace.workspaces) return null;
    var path = parsed.path.replaceAll(RegExp(r'/+$'), '');
    if (path.isEmpty) return null;
    if (RegExp(r'^[A-Za-z]/').hasMatch(path)) {
      return '${path[0]}:${path.substring(1)}';
    }
    return '/$path';
  } catch (_) {
    return null;
  }
}

/// Absolute additional roots from agent metadata (hub-advertised).
List<String> additionalDirectoriesFromMetadata(Map<String, dynamic> metadata) {
  final raw =
      metadata['additional_directories'] ?? metadata['additionalDirectories'];
  if (raw is! List) return const [];
  final out = <String>[];
  final seen = <String>{};
  for (final item in raw) {
    if (item is! String) continue;
    final path = item.trim();
    if (path.isEmpty || !seen.add(path)) continue;
    out.add(path);
  }
  return out;
}
