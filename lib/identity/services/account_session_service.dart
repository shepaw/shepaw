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

  Future<bool> hasLocalAccount() => LocalAccountRegistry.instance.hasAnyAccount();

  Future<void> switchToAccount(String accountId) async {
    await SyncClientService.instance.awaitIdle();
    _stopSyncServices();
    AccountIdentityService.instance.resetInMemory();
    await LocalAccountRegistry.instance.setActiveAccountId(accountId);
    await LocalDatabaseService().switchAccount(accountId);
    _log.info('Switched to account $accountId', tag: _tag);
  }

  Future<void> prepareNewAccount() async {
    await SyncClientService.instance.awaitIdle();
    _stopSyncServices();
    AccountIdentityService.instance.resetInMemory();
    await LocalDatabaseService().switchAccount(null);
  }

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
    _stopSyncServices();
  }

  void _stopSyncServices() {
    if (_syncStarted) {
      SyncProtocolService.instance.stop();
      SyncClientService.instance.stop();
      _syncStarted = false;
    }
  }
}
