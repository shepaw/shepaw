import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../services/noise_identity.dart';
import 'pouch_identity_store.dart';

/// 设备身份（docs/storage_space_plan.md §5.4）。
///
/// `device_id` = Noise 静态公钥的哈希（fingerprintHex，16 hex）。
/// 身份随加密快照保存：重装后恢复快照即恢复原 device_id；
/// 全新安装且不恢复 = 新设备、新 device_id。
class DeviceIdentity {
  DeviceIdentity._();

  /// 本机 device_id（Noise 公钥哈希，跨重装经快照恢复保持稳定）。
  static Future<String> deviceId() async {
    final identity = await NoiseIdentity.loadOrCreate();
    return identity.fingerprintHex;
  }

  /// 导出身份记录（随快照加密保存为 identity.enc）。
  static Future<Uint8List> exportIdentity() async {
    final identity = await NoiseIdentity.loadOrCreate();
    return Uint8List.fromList(utf8.encode(identity.encodeRecord()));
  }

  /// 从快照恢复身份（覆盖当前密钥对）。
  static Future<void> importIdentity(Uint8List record) async {
    await NoiseIdentity.importRecord(utf8.decode(record));
  }

  /// 启动时把身份锚到储物袋。
  ///
  /// 袋子里已有记录则导入钥匙串（换主机后指纹不变）。袋子是空的则把
  /// 当前安装的密钥种进去，已有配对不会因此换成新指纹。
  static Future<PouchIdentitySource> ensureFromPouch(Directory storeRoot) async {
    final store = PouchIdentityStore(storeRoot);
    final pouch = await store.readRecord();
    if (pouch != null) {
      await importIdentity(Uint8List.fromList(utf8.encode(pouch)));
      return PouchIdentitySource.pouch;
    }
    final exported = utf8.decode(await exportIdentity());
    await store.writeRecord(exported);
    return PouchIdentitySource.keychain;
  }
}
