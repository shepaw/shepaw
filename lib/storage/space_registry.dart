import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'store_protocol.dart';

/// 自定义空间注册表（`.system/spaces.json`；spec §0.5 / `space.declare`）。
class SpaceRegistry {
  SpaceRegistry(this.root)
      : _file = File(p.join(root.path, '.system', 'spaces.json'));

  final Directory root;
  final File _file;
  final Map<String, SpaceProfile> _custom = {};
  bool _loaded = false;

  static const visibilities = {'shared', 'private'};
  static const encryptions = {'client', 'none'};
  static const retentions = {'keep_last', 'gfs', 'none'};
  static const importGrants = {'allowed', 'denied'};

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (!await _file.exists()) return;
    try {
      final decoded = jsonDecode(await _file.readAsString());
      if (decoded is! Map) return;
      final raw = decoded['spaces'];
      if (raw is! List) return;
      for (final item in raw) {
        if (item is! Map) continue;
        final profile =
            SpaceProfile.fromJson(item.cast<String, dynamic>());
        if (profile.name.isEmpty || StoreSpace.isReservedDeclareName(profile.name)) {
          continue;
        }
        _custom[profile.name] = profile;
      }
    } catch (_) {
      // 损坏的注册表当作空；下一次 declare 会覆写。
    }
  }

  /// `true`=shared / `false`=private / `null`=未知（非内置且未声明）。
  bool? visibility(String space) {
    final builtin = StoreSpace.visibilityOf(space);
    if (builtin != null) return builtin;
    final custom = _custom[space];
    if (custom == null) return null;
    return custom.isShared;
  }

  bool isKnown(String space) => visibility(space) != null;

  List<SpaceProfile> listAll() {
    final out = [...StoreSpace.builtinProfiles];
    final custom = _custom.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    out.addAll(custom);
    return out;
  }

  /// 声明或更新自定义空间。非法参数抛 [StoreException]。
  Future<SpaceProfile> declare({
    required String name,
    String visibility = 'private',
    String encryption = 'none',
    String retention = 'none',
    String importGrant = 'allowed',
  }) async {
    await load();
    if (!StoreSpace.isValidSyntax(name)) {
      throw const FormatException('invalid space name');
    }
    if (StoreSpace.isReservedDeclareName(name)) {
      throw const FormatException('reserved space name');
    }
    if (!visibilities.contains(visibility)) {
      throw const FormatException('invalid visibility');
    }
    if (!encryptions.contains(encryption)) {
      throw const FormatException('invalid encryption');
    }
    if (!retentions.contains(retention)) {
      throw const FormatException('invalid retention');
    }
    if (!importGrants.contains(importGrant)) {
      throw const FormatException('invalid import_grant');
    }
    final profile = SpaceProfile(
      name: name,
      visibility: visibility,
      encryption: encryption,
      retention: retention,
      importGrant: importGrant,
    );
    _custom[name] = profile;
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(<String, dynamic>{
      'spaces': [for (final p in _custom.values) p.toJson()],
    }));
    return profile;
  }
}
