import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../services/app_paths.dart';

/// App 当前登录的袋子。这是选择记录，不是袋子里的身份密钥。
class PouchSession {
  const PouchSession({
    required this.hubUrl,
    required this.pouchId,
    required this.pouchName,
    required this.hostPeerId,
  });

  final String hubUrl;
  final String pouchId;
  final String pouchName;
  final String hostPeerId;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'hub_url': hubUrl,
        'pouch_id': pouchId,
        'pouch_name': pouchName,
        'host_peer_id': hostPeerId,
      };

  static PouchSession? fromJson(Map<String, dynamic> json) {
    final hubUrl = (json['hub_url'] as String?)?.trim() ?? '';
    final pouchId = (json['pouch_id'] as String?)?.trim() ?? '';
    final pouchName = (json['pouch_name'] as String?)?.trim() ?? '';
    final hostPeerId = (json['host_peer_id'] as String?)?.trim() ?? '';
    if (hubUrl.isEmpty || pouchId.isEmpty || hostPeerId.isEmpty) return null;
    return PouchSession(
      hubUrl: hubUrl,
      pouchId: pouchId,
      pouchName: pouchName.isEmpty ? pouchId : pouchName,
      hostPeerId: hostPeerId,
    );
  }
}

class PouchSessionStore {
  PouchSessionStore(this.file);

  final File file;

  /// 测试替换读取，避免碰到应用目录。
  @visibleForTesting
  static Future<PouchSession?> Function()? readOverride;

  static Future<File> appFile() async {
    final docs = await AppPaths.documents();
    return File(p.join(docs.path, 'shepaw', 'pouch_session.json'));
  }

  static Future<PouchSession?> readActive() async {
    final override = readOverride;
    if (override != null) return override();
    return PouchSessionStore(await appFile()).load();
  }

  Future<PouchSession?> load() async {
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    return PouchSession.fromJson(decoded.cast<String, dynamic>());
  }

  Future<void> save(PouchSession session) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(session.toJson()));
  }
}
