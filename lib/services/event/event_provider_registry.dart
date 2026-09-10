import 'dart:convert';
import 'dart:io';

import '../logger_service.dart';

/// External event provider manifest (`~/shepaw/event-providers/<name>/manifest.json`).
class EventProviderManifest {
  final String name;
  final String namespace;
  final String version;
  final List<String> eventTypes;
  final List<String> requiredPermissions;
  final String path;

  const EventProviderManifest({
    required this.name,
    required this.namespace,
    required this.version,
    required this.eventTypes,
    required this.requiredPermissions,
    required this.path,
  });

  factory EventProviderManifest.fromJson(
    Map<String, dynamic> json, {
    required String path,
    required String name,
  }) {
    return EventProviderManifest(
      name: name,
      namespace: json['namespace'] as String? ?? name,
      version: json['version'] as String? ?? '0.0.0',
      eventTypes: (json['event_types'] as List?)?.cast<String>() ?? const [],
      requiredPermissions:
          (json['required_permissions'] as List?)?.cast<String>() ?? const [],
      path: path,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'namespace': namespace,
        'version': version,
        'event_types': eventTypes,
        'required_permissions': requiredPermissions,
        'path': path,
      };
}

/// Scans `~/shepaw/event-providers/` (P4).
class EventProviderRegistry {
  EventProviderRegistry._();
  static final EventProviderRegistry instance = EventProviderRegistry._();

  static const _tag = 'EventProviders';

  Directory get rootDir {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) {
      return Directory('/tmp/shepaw/event-providers');
    }
    return Directory('$home/shepaw/event-providers');
  }

  Future<List<EventProviderManifest>> scan() async {
    final dir = rootDir;
    if (!await dir.exists()) return [];

    final manifests = <EventProviderManifest>[];
    await for (final entity in dir.list()) {
      if (entity is! Directory) continue;
      final manifestFile = File('${entity.path}/manifest.json');
      if (!await manifestFile.exists()) continue;
      try {
        final json =
            jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
        manifests.add(EventProviderManifest.fromJson(
          json,
          path: entity.path,
          name: entity.uri.pathSegments.where((s) => s.isNotEmpty).last,
        ));
      } catch (e) {
        LoggerService().warning(
          'Invalid event provider manifest: ${entity.path}',
          tag: _tag,
          error: e,
        );
      }
    }
    manifests.sort((a, b) => a.name.compareTo(b.name));
    return manifests;
  }
}
