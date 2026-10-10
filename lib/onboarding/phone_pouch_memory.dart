import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/cli_pouch.dart';
import '../storage/pouch_catalog.dart';
import '../storage/pouch_session.dart';

/// 这台手机在某台主机上见过的储物袋。
///
/// 主机暂时连不上时，登录页仍用这份名单，让人点选后再输密码。
class PhonePouchMemory {
  static String keyFor(String hostId) => 'phone_pouches_${hostId.trim()}';

  static Future<List<PouchDescriptor>> read(String hostId) async {
    if (hostId.trim().isEmpty) return const [];
    final prefs = await SharedPreferences.getInstance();
    return decode(prefs.getString(keyFor(hostId)));
  }

  static Future<void> write(
    String hostId,
    List<PouchDescriptor> pouches,
  ) async {
    final id = hostId.trim();
    if (id.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyFor(id), encode(pouches));
  }

  static List<PouchDescriptor> decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final pouches = <PouchDescriptor>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final id = (item['id'] as String?)?.trim() ?? '';
        final name = (item['name'] as String?)?.trim() ?? '';
        if (id.isEmpty || name.isEmpty) continue;
        pouches.add(PouchDescriptor(id: id, name: name, rootPath: ''));
      }
      return pouches;
    } catch (_) {
      return const [];
    }
  }

  static String encode(List<PouchDescriptor> pouches) {
    return jsonEncode([
      for (final pouch in pouches)
        if (pouch.id.trim().isNotEmpty && pouch.name.trim().isNotEmpty)
          {'id': pouch.id.trim(), 'name': pouch.name.trim()},
    ]);
  }

  /// 退出登录前把当前这只记下来。token 清掉之后，登录页还能点它。
  static Future<void> rememberSession(PouchSession? session) async {
    if (session == null) return;
    final hostId = session.hostPeerId.trim();
    final id = session.pouchId.trim();
    final name = session.pouchName.trim();
    if (hostId.isEmpty || id.isEmpty || name.isEmpty) return;
    final existing = await read(hostId);
    await write(hostId, rememberPhonePouch(existing, id: id, name: name));
    await PouchLoginMemory.write(id: id, name: name);
  }
}

/// 把上次进入的那一只补进名单。已经在里面就不重复。
List<PouchDescriptor> rememberPhonePouch(
  List<PouchDescriptor> pouches, {
  required String id,
  required String name,
}) {
  final pouchId = id.trim();
  final pouchName = name.trim();
  if (pouchId.isEmpty || pouchName.isEmpty) return pouches;
  if (pouches.any((pouch) => pouch.id == pouchId)) return pouches;
  return [
    ...pouches,
    PouchDescriptor(id: pouchId, name: pouchName, rootPath: ''),
  ];
}
