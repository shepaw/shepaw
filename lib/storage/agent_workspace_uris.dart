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
