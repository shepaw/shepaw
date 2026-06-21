import '../../services/local_database_service.dart';
import '../../services/logger_service.dart';
import 'account_identity_service.dart';
import 'local_account_registry.dart';
import 'sync_client_service.dart';
import 'sync_protocol_service.dart';

/// 账号会话：设备登录账号后激活身份与同步服务。
class AccountSessionService {
  AccountSessionService._();
  static final AccountSessionService instance = AccountSessionService._();

  static const _tag = 'AccountSession';
  final _log = LoggerService();

  bool _syncStarted = false;

  /// 本机是否已有账号密钥。
  Future<bool> hasLocalAccount() => LocalAccountRegistry.instance.hasAnyAccount();

  /// 切换到指定账号（重置内存状态 + 切换数据库）。
  Future<void> switchToAccount(String accountId) async {
    AccountIdentityService.instance.resetInMemory();
    resetSyncState();
    await LocalAccountRegistry.instance.setActiveAccountId(accountId);
    await LocalDatabaseService().switchAccount(accountId);
    _log.info('Switched to account $accountId', tag: _tag);
  }

  /// 准备创建新账号：清除当前会话状态，不删除已保存账号。
  Future<void> prepareNewAccount() async {
    AccountIdentityService.instance.resetInMemory();
    resetSyncState();
    await LocalDatabaseService().switchAccount(null);
  }

  /// 激活当前账号（加载身份 + 启动 P2P 同步协议）。
  Future<void> activate() async {
    final accountId = await LocalAccountRegistry.instance.getActiveAccountId();
    if (accountId != null) {
      await LocalDatabaseService().switchAccount(accountId);
    }
    await AccountIdentityService.instance.ensureInitialized();
    if (!_syncStarted) {
      SyncProtocolService.instance.start();
      SyncClientService.instance.start();
      _syncStarted = true;
      _log.info('Account session activated', tag: _tag);
    }
  }

  void resetSyncState() {
    _syncStarted = false;
  }
}
