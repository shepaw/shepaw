import 'package:uuid/uuid.dart';
import '../models/remote_agent.dart';
import 'local_database_service.dart';

/// Token 服务
/// 负责生成、验证和管理 Agent 的认证 Token
class TokenService {
  final LocalDatabaseService _databaseService;
  final Uuid _uuid = const Uuid();

  TokenService(this._databaseService);

  /// 生成新的 UUID Token
  /// 返回格式: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
  String generateToken() {
    return _uuid.v4();
  }

  /// 验证 Token 格式是否有效
  /// Token 必须是标准的 UUID v4 格式
  bool validateToken(String token) {
    if (token.isEmpty) return false;

    // UUID v4 正则表达式
    final uuidRegex = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      caseSensitive: false,
    );

    return uuidRegex.hasMatch(token);
  }

  /// 验证 Token 并从数据库查询对应的 Agent
  ///
  /// 返回:
  /// - 找到对应的 Agent: 返回 RemoteAgent 对象
  /// - Token 无效或不存在: 返回 null
  Future<RemoteAgent?> verifyToken(String token) async {
    // 首先验证格式
    if (!validateToken(token)) {
      return null;
    }

    try {
      // 从数据库查询
      final db = await _databaseService.database;
      final result = await db.query(
        'agents',
        where: 'token = ?',
        whereArgs: [token],
        limit: 1,
      );

      if (result.isEmpty) {
        return null;
      }

      return RemoteAgent.fromMap(result.first);
    } catch (e) {
      // 验证失败，返回 null
      return null;
    }
  }

  /// 检查 Token 是否已存在
  /// 用于避免重复生成相同的 Token
  Future<bool> tokenExists(String token) async {
    try {
      final db = await _databaseService.database;
      final result = await db.query(
        'agents',
        columns: ['id'],
        where: 'token = ?',
        whereArgs: [token],
        limit: 1,
      );

      return result.isNotEmpty;
    } catch (e) {
      // 检查失败，默认认为不存在
      return false;
    }
  }

  /// 为指定 Agent 重新生成 Token
  ///
  /// 注意: 这会使旧的 Token 失效，远端助手需要使用新 Token 重新连接
  Future<String> regenerateToken(String agentId) async {
    String newToken;

    // 确保生成的 Token 是唯一的（理论上 UUID 冲突概率极低）
    do {
      newToken = generateToken();
    } while (await tokenExists(newToken));

    try {
      final db = await _databaseService.database;
      await db.update(
        'agents',
        {
          'token': newToken,
          'updated_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: [agentId],
      );

      return newToken;
    } catch (e) {
      throw Exception('重新生成 Token 失败: $e');
    }
  }

  /// 批量验证多个 Token
  /// 返回 Token 到 Agent 的映射
  Future<Map<String, RemoteAgent>> verifyTokens(List<String> tokens) async {
    final result = <String, RemoteAgent>{};

    for (final token in tokens) {
      final agent = await verifyToken(token);
      if (agent != null) {
        result[token] = agent;
      }
    }

    return result;
  }

  /// 生成唯一的 Token
  /// 确保生成的 Token 在数据库中不存在
  Future<String> generateUniqueToken() async {
    String token;

    // 虽然 UUID 冲突概率极低，但还是检查一下确保唯一性
    do {
      token = generateToken();
    } while (await tokenExists(token));

    return token;
  }
}
