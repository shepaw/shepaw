import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

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
}
