import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/noise_identity.dart';

/// 储物袋身份记录的落点。
///
/// 文件在袋根 `.system/` 下，不进 `store://`，agent 读不到私钥。
/// 换主机时整袋拷走，新机器启动时以这份记录为准。
class PouchIdentityStore {
  PouchIdentityStore(this.root);

  final Directory root;

  static const fileName = 'pouch_identity.v1';

  File get file => File(p.join(root.path, '.system', fileName));

  /// 袋子里的身份记录。没有文件时返回 null。
  /// 内容损坏时抛 [FormatException]，调用方不得改用别的密钥顶上。
  Future<String?> readRecord() async {
    if (!await file.exists()) return null;
    final raw = (await file.readAsString()).trim();
    if (raw.isEmpty) return null;
    NoiseIdentity.parseRecord(raw);
    return raw;
  }

  Future<void> writeRecord(String record) async {
    NoiseIdentity.parseRecord(record);
    await file.parent.create(recursive: true);
    await file.writeAsString(record);
  }
}

/// 启动时身份以谁为准。
enum PouchIdentitySource {
  /// 袋子里已有记录，钥匙串要改成这一份。
  pouch,

  /// 袋子还是空的，把当前安装的密钥种进袋子。
  keychain,

  /// 两边都没有，调用方再生成。
  none,
}

/// 纯判定：袋子优先于钥匙串。两边都有且不同时，仍用袋子。
class PouchIdentityAdoption {
  PouchIdentityAdoption._();

  static ({PouchIdentitySource source, String? record}) decide({
    String? pouchRecord,
    String? keychainRecord,
  }) {
    final pouch = pouchRecord?.trim();
    if (pouch != null && pouch.isNotEmpty) {
      return (source: PouchIdentitySource.pouch, record: pouch);
    }
    final keychain = keychainRecord?.trim();
    if (keychain != null && keychain.isNotEmpty) {
      return (source: PouchIdentitySource.keychain, record: keychain);
    }
    return (source: PouchIdentitySource.none, record: null);
  }
}
