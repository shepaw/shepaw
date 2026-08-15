import '../models/remote_agent.dart';
import 'device_identity.dart';
import 'store_protocol.dart';
import 'workspace_binding_service.dart';

/// Collect unique `store://workspaces/…` roots advertised on [metadata].
List<String> workspaceUrisFromMetadata(Map<String, dynamic> metadata) {
  final out = <String>[];
  final seen = <String>{};

  void add(Object? value) {
    if (value is! String) return;
    final uri = value.trim();
    if (!uri.startsWith('store://')) return;
    final key = uri.replaceAll(RegExp(r'/+$'), '');
    if (key.isEmpty || !seen.add(key)) return;
    out.add(uri.endsWith('/') ? uri : '$uri/');
  }

  add(metadata['workspace_uri']);
  final list = metadata['workspace_uris'];
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
