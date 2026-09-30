import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../services/app_lifecycle_service.dart';
import '../services/local_database_service.dart';
import '../services/logger_service.dart';
import 'device_identity.dart';
import 'local_store.dart';
import 'store_protocol.dart';
import 'store_service.dart';

/// 从文本里抽出「本机 runtime 附件」的相对路径。
///
/// 消息 metadata / 正文里的 `pouch://runtime/<device>/…/attachments/…`。
/// 其他分区、其他 device 忽略。
Set<String> referencedRuntimeAttachmentPaths(
  String deviceId,
  Iterable<String> texts,
) {
  final out = <String>{};
  final re = RegExp(
    r'''pouch://runtime/[0-9a-f]{16}/[^\s"'`<>)\]]+''',
  );
  for (final text in texts) {
    for (final match in re.allMatches(text)) {
      try {
        final parsed = parseStoreUri(match.group(0)!);
        if (parsed.device != deviceId) continue;
        if (!parsed.path.contains('/attachments/')) continue;
        out.add(normalizeStorePath(parsed.path));
      } catch (_) {}
    }
  }
  return out;
}

/// 本机 agent 分区（runtime / artifacts / attachments / cognition）已用字节。
int agentQuotaUsedBytes(Map<String, dynamic>? stats, String deviceId) {
  final devices = stats?['devices'];
  if (devices is! Map) return 0;
  final per = devices[deviceId];
  if (per is! Map) return 0;
  var used = 0;
  for (final space in StoreSpace.agentQuotaSpaces) {
    final value = per[space];
    if (value is int) {
      used += value;
    } else if (value is num) {
      used += value.toInt();
    }
  }
  return used;
}

/// 达到配额 80% 时提示。产物不因这条被删除。
bool agentQuotaNeedsAttention(
  int usedBytes, {
  int capBytes = LocalStore.defaultAgentSpaceQuotaBytes,
}) {
  if (capBytes <= 0 || usedBytes <= 0) return false;
  return usedBytes * 5 >= capBytes * 4;
}

/// 前台保留清理（`docs/runtime_lifecycle_decision.md`）。
///
/// 后台不跑。版本裁剪每台设备清自己的 `.versions`。会话归档与孤儿附件
/// 只在 master 上跑，避免多端各删一遍；附件只判断本机消息库能看见的引用。
class RuntimeRetentionService {
  RuntimeRetentionService._();
  static final RuntimeRetentionService instance = RuntimeRetentionService._();

  static const interval = Duration(hours: 1);
  static const _tag = 'RuntimeRetention';

  final _log = LoggerService();
  Timer? _timer;
  StreamSubscription<Duration>? _resumeSub;
  bool _running = false;

  void start() {
    _resumeSub ??= AppLifecycleService().onResume.listen((_) {
      unawaited(run());
    });
    _timer ??= Timer.periodic(interval, (_) {
      unawaited(run());
    });
    unawaited(run());
  }

  @visibleForTesting
  Future<void> run({bool Function()? isForeground}) async {
    final foreground = isForeground ?? () => AppLifecycleService().isInForeground;
    if (!foreground() || _running) return;
    _running = true;
    try {
      final store = await StoreService.instance.localStore();
      final staging = await store.gcStaging();
      final recycle = await store.gcRecycle();
      final self = await DeviceIdentity.deviceId();
      final versions = await store.pruneOldVersions(self);
      var archives = 0;
      var orphans = 0;
      if (await StoreService.instance.isMaster()) {
        for (final deviceId in await store.listDeviceIds()) {
          archives += await store.pruneSessionArchives(deviceId);
        }
        final refs = await _referencedAttachmentPaths(self);
        if (refs != null) {
          orphans = await store.pruneOrphanAttachments(self, refs);
        }
      }
      if (staging > 0 || recycle > 0 || versions > 0 || archives > 0 || orphans > 0) {
        _log.info(
          'retention staging=$staging recycleBytes=$recycle '
          'versions=$versions archives=$archives orphans=$orphans',
          tag: _tag,
        );
      }
    } catch (e) {
      _log.warning('retention failed: $e', tag: _tag);
    } finally {
      _running = false;
    }
  }

  /// 消息库不可用时返回 null，调用方跳过附件清理，避免把还在用的文件删掉。
  Future<Set<String>?> _referencedAttachmentPaths(String deviceId) async {
    try {
      final db = await LocalDatabaseService().database;
      final rows = await db.rawQuery(
        "SELECT metadata, content FROM messages "
        "WHERE metadata LIKE '%/attachments/%' "
        "OR content LIKE '%/attachments/%'",
      );
      final texts = <String>[];
      for (final row in rows) {
        final metadata = row['metadata'];
        final content = row['content'];
        if (metadata is String && metadata.isNotEmpty) texts.add(metadata);
        if (content is String && content.isNotEmpty) texts.add(content);
      }
      return referencedRuntimeAttachmentPaths(deviceId, texts);
    } catch (e) {
      _log.warning('attachment refs unavailable, skip orphan prune: $e', tag: _tag);
      return null;
    }
  }
}
