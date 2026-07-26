import 'dart:convert';
import 'dart:typed_data';

import '../services/noise_identity.dart';

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
}
