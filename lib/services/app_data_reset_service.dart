import '../storage/store_wipe_service.dart';
import 'agent_memory_store_service.dart';
import 'chat_service.dart';
import 'event/event_bus.dart';
import 'event/peer_event_provider.dart';
import 'cognition_service.dart';
import 'inference_log_service.dart';
import 'local_database_service.dart';
import 'local_file_storage_service.dart';
import 'logger_service.dart';
import 'she_memory_db_service.dart';

/// 清空本机应用数据（聊天 / Agent / 记忆 / 储物袋文件）。
///
/// 保留应用锁密码与设备身份。快照在储物袋 `backups/` 内，会随 store 一并清除。
class AppDataResetService {
  AppDataResetService({
    LocalDatabaseService? db,
    LocalFileStorageService? files,
    LoggerService? logger,
    StoreWipeService? storeWipe,
  })  : _db = db ?? LocalDatabaseService(),
        _files = files ?? LocalFileStorageService(),
        _log = logger ?? LoggerService(),
        _storeWipe = storeWipe ?? StoreWipeService.instance;

  static const _tag = 'AppDataReset';

  final LocalDatabaseService _db;
  final LocalFileStorageService _files;
  final LoggerService _log;
  final StoreWipeService _storeWipe;

  Future<void> clearAllAppData() async {
    _log.info('Clearing all app data', tag: _tag);
    final errors = <String>[];

    Future<void> step(String name, Future<void> Function() fn) async {
      try {
        await fn();
      } catch (e, st) {
        _log.error('$name failed', tag: _tag, error: e, stackTrace: st);
        errors.add('$name: $e');
      }
    }

    await step('database', () => _db.clearAllData());
    await step('cognition', () => CognitionService.instance.clearAll());
    await step('she_memory', () => SheMemoryDbService().clearSheMemory());
    await step('inference_log', () async {
      InferenceLogService.instance.clearAll();
    });
    await step('legacy_files', () => _files.clearAllResources());
    await step('agent_memory', AgentMemoryStoreService.deleteAllAgentMemories);
    // 事件系统：DB 行在 database 步骤已删，这里清内存态并恢复 She 的默认订阅，
    // 否则重置后到下次启动前事件系统处于「零订阅」。
    // ChatService 侧还有一份排队中的延迟感知回合（持有事件 payload），
    // 同样属于事件系统内存态，必须一并清掉。
    await step('event_bus', () async {
      EventBus.instance.resetRuntimeState();
      ChatService().clearDeferredEventPerception();
      PeerEventProvider.seedSheInboundSubscription(EventBus.instance);
    });
    await step('store', () async {
      await _storeWipe.wipeSelfTree();
    });

    if (errors.isNotEmpty) {
      throw StateError(errors.join('; '));
    }
    _log.info('All app data cleared', tag: _tag);
  }
}
