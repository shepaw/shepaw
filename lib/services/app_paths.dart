import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 应用数据目录的唯一入口。
///
/// macOS 版本已退出 App Sandbox，`getApplicationDocumentsDirectory()` 会指向
/// 用户的「文稿」目录，不能再往那里放数据库。macOS 统一落在
/// `~/Library/Application Support/ShePaw`，其余平台保持 path_provider 默认值。
///
/// [initialize] 必须在任何服务碰磁盘之前调用——它负责把旧沙盒容器里的数据
/// 一次性搬到新位置。
class AppPaths {
  AppPaths._();

  static const _macFolderName = 'ShePaw';
  static const _legacyBundleId = 'com.shepaw.app';
  static const _migrationMarker = '.migrated-from-sandbox';

  /// 日志量大且可再生，迁移时跳过，避免启动时多拷贝 1GB。
  static const _skipDuringMigration = {'logs'};

  static Directory? _macRoot;
  static Directory? _legacyDocs;
  static Directory? _legacySupport;
  static Directory? _testRoot;

  /// 迁移过程中的异常信息，由启动流程在 LoggerService 就绪后补记。
  static String? migrationNote;

  /// 测试专用：把数据根目录钉在临时目录上，跳过平台解析与迁移。
  /// 让测试和生产走同一套路径解析，避免 harness 直接 mock path_provider
  /// 时两边指到不同目录。
  static void setRootForTesting(Directory? dir) {
    _testRoot = dir;
    _macRoot = null;
    _legacyDocs = null;
    _legacySupport = null;
  }

  static Future<void> initialize() async {
    if (_testRoot != null) return;
    if (!Platform.isMacOS || _macRoot != null || _legacyDocs != null) return;

    final library = await getLibraryDirectory();
    final home = library.parent.path;
    final target = Directory('${library.path}/Application Support/$_macFolderName');
    final legacyDocs =
        Directory('$home/Library/Containers/$_legacyBundleId/Data/Documents');
    final legacySupport = Directory(
      '$home/Library/Containers/$_legacyBundleId/Data/Library/'
      'Application Support/$_legacyBundleId',
    );

    if (target.existsSync() ||
        (!legacyDocs.existsSync() && !legacySupport.existsSync())) {
      _macRoot = _ensured(target);
      return;
    }

    final started = DateTime.now();
    final staging = Directory('${target.path}.migrating');
    try {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
      staging.createSync(recursive: true);
      if (legacyDocs.existsSync()) _copyInto(legacyDocs, staging, top: true);
      if (legacySupport.existsSync()) {
        _copyInto(legacySupport, staging, top: true);
      }
      File('${staging.path}/$_migrationMarker').writeAsStringSync(
        '${DateTime.now().toIso8601String()}\n'
        'source: ${legacyDocs.path}\n'
        'source: ${legacySupport.path}\n',
      );
      staging.renameSync(target.path);
      _macRoot = target;
      final ms = DateTime.now().difference(started).inMilliseconds;
      migrationNote = 'Migrated sandbox container to ${target.path} in ${ms}ms';
    } catch (e) {
      // 迁移没做完就继续用旧容器：非沙盒进程照样读得到，用户不会看到
      // 「数据全没了」，下次启动还会再试一次。
      _safeDelete(staging);
      _legacyDocs = legacyDocs;
      _legacySupport = legacySupport;
      migrationNote =
          'Sandbox container migration failed, still using ${legacyDocs.path}: $e';
    }
  }

  /// 数据库、储物袋、技能包等业务数据的根目录。
  static Future<Directory> documents() async {
    final test = _testRoot;
    if (test != null) return _ensured(test);
    if (!Platform.isMacOS) return getApplicationDocumentsDirectory();
    final legacy = _legacyDocs;
    if (legacy != null) return _ensured(legacy);
    return _ensured(_macRoot ?? await _fallbackMacRoot());
  }

  /// SecureKeyManager 的 master key / secrets 落点。
  static Future<Directory> support() async {
    final test = _testRoot;
    if (test != null) return _ensured(test);
    if (!Platform.isMacOS) return getApplicationSupportDirectory();
    final legacy = _legacySupport;
    if (legacy != null) return _ensured(legacy);
    return _ensured(_macRoot ?? await _fallbackMacRoot());
  }

  /// [initialize] 没跑过时（例如子窗口引擎）按同样规则兜底解析。
  static Future<Directory> _fallbackMacRoot() async {
    final library = await getLibraryDirectory();
    final root = Directory('${library.path}/Application Support/$_macFolderName');
    _macRoot = root;
    return root;
  }

  static Directory _ensured(Directory dir) {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static void _copyInto(Directory src, Directory dst, {bool top = false}) {
    for (final entity in src.listSync(followLinks: false)) {
      final name = entity.path.split(Platform.pathSeparator).last;
      if (top && _skipDuringMigration.contains(name)) continue;
      final targetPath = '${dst.path}/$name';
      if (entity is Directory) {
        Directory(targetPath).createSync(recursive: true);
        _copyInto(entity, Directory(targetPath));
      } else if (entity is File) {
        entity.copySync(targetPath);
      }
      // 容器里的 Desktop / Downloads 等符号链接直接跳过。
    }
  }

  static void _safeDelete(Directory dir) {
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}
