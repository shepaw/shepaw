import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/app_paths.dart';
import 'package:shepaw/storage/pouch_scope_store.dart';
import 'package:shepaw/storage/store_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'memory_scope_transport.dart';

/// 存储层测试 harness：method channel 全 mock（path_provider → 临时目录、
/// flutter_secure_storage → 内存 Map），因此真实服务链（SecureKeyManager、
/// LocalDatabaseService ffi、PasswordService）可跑在默认 CI（无需真机插件）。
class StorageTestHarness {
  static final Map<String, String?> _secureStore = <String, String?>{};
  static Directory? _tmp;

  static Future<Directory> init() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    _tmp ??= await Directory.systemTemp.createTemp('storage_test');
    final tmp = _tmp!;

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async {
        final dir = Directory('${tmp.path}/${call.method}');
        if (!dir.existsSync()) dir.createSync(recursive: true);
        return dir.path;
      },
    );

    // 生产代码一律走 AppPaths；钉到 mock 的文档目录，测试里直接
    // getApplicationDocumentsDirectory() 取到的仍是同一个位置。
    AppPaths.setRootForTesting(
      Directory('${tmp.path}/getApplicationDocumentsDirectory'),
    );

    // 测试不碰本机真实 hub（`~/.config/shepaw-hub/pouch.sock`）：否则附件
    // 双写会直接写进开发者的袋子。
    StoreService.instance.localHubRootOverride = '${tmp.path}/no-hub';

    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        final key = call.arguments['key'] as String;
        switch (call.method) {
          case 'read':
            return _secureStore[key];
          case 'write':
            _secureStore[key] = call.arguments['value'] as String?;
            return null;
          case 'delete':
            _secureStore.remove(key);
            return null;
          case 'readAll':
            return _secureStore;
          case 'deleteAll':
            _secureStore.clear();
            return null;
          default:
            return null;
        }
      },
    );
    return tmp;
  }

  /// 让当前测试进程「已配对袋子」：v3 scope 读写落到内存传输。
  ///
  /// 群工作区 / 玉简内容现在只走 `pouch://<id>/<scope>/…`，未配对的
  /// [StoreService.scopeStore] 会抛 `not_paired`。只给需要 v3 内容面的测试
  /// 装，不要放进 [init]，否则「未配对」分支就测不到了。
  static MemoryScopeTransport installMemoryPouchScope({
    String pouchId = 'test-pouch',
  }) {
    final transport = MemoryScopeTransport();
    StoreService.instance.scopeStoreOverride = PouchScopeStore(
      transport: transport,
      pouchId: pouchId,
    );
    StoreService.instance.currentPouchIdOverride = pouchId;
    return transport;
  }
}
