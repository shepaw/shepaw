import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../services/noise_identity.dart';
import 'pouch_identity_store.dart';

/// 一台机器上的一个袋子。目录名就是 id，身份只写在这个目录里。
class PouchDescriptor {
  const PouchDescriptor({
    required this.id,
    required this.name,
    required this.rootPath,
  });

  final String id;
  final String name;
  final String rootPath;
}

/// `{hubRoot}/pouches/<id>/`。App 只列举和新建，不在这里跑惜宝。
class PouchCatalog {
  PouchCatalog(this.pouchesDir);

  final Directory pouchesDir;

  static const manifestName = 'pouch.json';

  static Directory underHub(String hubRoot) =>
      Directory(p.join(hubRoot, 'pouches'));

  Future<List<PouchDescriptor>> list() async {
    if (!await pouchesDir.exists()) return const [];
    final found = <PouchDescriptor>[];
    await for (final entity in pouchesDir.list()) {
      if (entity is! Directory) continue;
      final pouch = await _read(entity);
      if (pouch != null) found.add(pouch);
    }
    found.sort((a, b) => a.name.compareTo(b.name));
    return found;
  }

  Future<PouchDescriptor> create({required String name}) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('袋子需要一个名字');
    }
    final id = const Uuid().v4();
    final root = Directory(p.join(pouchesDir.path, id));
    await root.create(recursive: true);
    final identity = await NoiseIdentity.generateDetached();
    await PouchIdentityStore(root).writeRecord(identity.encodeRecord());
    final manifest = File(p.join(root.path, '.system', manifestName));
    await manifest.writeAsString(jsonEncode(<String, dynamic>{
      'id': id,
      'name': trimmed,
    }));
    return PouchDescriptor(id: id, name: trimmed, rootPath: root.path);
  }

  Future<PouchDescriptor?> _read(Directory root) async {
    final file = File(p.join(root.path, '.system', manifestName));
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    final id = (decoded['id'] as String?)?.trim() ?? '';
    final name = (decoded['name'] as String?)?.trim() ?? '';
    if (id.isEmpty || id != p.basename(root.path) || name.isEmpty) return null;
    return PouchDescriptor(id: id, name: name, rootPath: root.path);
  }
}
