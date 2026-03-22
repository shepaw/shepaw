import 'package:sqflite/sqflite.dart';
import 'local_database_service.dart';

/// 本地存储服务
/// 提供数据库访问接口
class LocalStorageService {
  static final LocalStorageService _instance = LocalStorageService._internal();
  factory LocalStorageService() => _instance;
  LocalStorageService._internal();

  final LocalDatabaseService _databaseService = LocalDatabaseService();

  /// 获取数据库实例
  Future<Database> get database => _databaseService.database;
}
