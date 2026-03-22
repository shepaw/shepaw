/// 环境配置
class EnvConfig {
  /// 当前环境
  static const String environment = String.fromEnvironment(
    'ENVIRONMENT',
    defaultValue: 'development',
  );

  /// 是否为开发环境
  static bool get isDevelopment => environment == 'development';

  /// 是否为预发布环境
  static bool get isStaging => environment == 'staging';

  /// 是否为生产环境
  static bool get isProduction => environment == 'production';

  /// API Base URL
  static String get apiUrl {
    switch (environment) {
      case 'production':
        return const String.fromEnvironment(
          'API_URL',
          defaultValue: 'https://api.shepaw.com',
        );
      case 'staging':
        return const String.fromEnvironment(
          'API_URL',
          defaultValue: 'https://staging-api.shepaw.com',
        );
      default:
        return const String.fromEnvironment(
          'API_URL',
          defaultValue: 'http://localhost:8080',
        );
    }
  }

  /// Knot API URL
  static String get knotApiUrl {
    return const String.fromEnvironment(
      'KNOT_API_URL',
      defaultValue: 'https://knot.woa.com',
    );
  }

  /// WebSocket URL
  static String get wsUrl {
    switch (environment) {
      case 'production':
        return const String.fromEnvironment(
          'WS_URL',
          defaultValue: 'wss://api.shepaw.com/ws',
        );
      case 'staging':
        return const String.fromEnvironment(
          'WS_URL',
          defaultValue: 'wss://staging-api.shepaw.com/ws',
        );
      default:
        return const String.fromEnvironment(
          'WS_URL',
          defaultValue: 'ws://localhost:8080/ws',
        );
    }
  }

  /// 加密密钥（从环境变量或 Secure Storage 读取）
  static String get encryptionKey {
    return const String.fromEnvironment(
      'ENCRYPTION_KEY',
      defaultValue: '', // 实际应从 Secure Storage 读取
    );
  }

  /// 日志级别
  static String get logLevel {
    const level = String.fromEnvironment('LOG_LEVEL', defaultValue: '');
    if (level.isNotEmpty) return level;
    return isDevelopment ? 'debug' : 'info';
  }

  /// 是否启用日志
  static bool get enableLogging {
    return const bool.fromEnvironment(
      'ENABLE_LOGGING',
      defaultValue: true,
    );
  }

  /// 网络超时时间（秒）
  static int get networkTimeout {
    return const int.fromEnvironment(
      'NETWORK_TIMEOUT',
      defaultValue: 30,
    );
  }

  /// WebSocket 重连间隔（秒）
  static int get wsReconnectInterval {
    return const int.fromEnvironment(
      'WS_RECONNECT_INTERVAL',
      defaultValue: 5,
    );
  }

  /// WebSocket 最大重连次数
  static int get wsMaxReconnectAttempts {
    return const int.fromEnvironment(
      'WS_MAX_RECONNECT_ATTEMPTS',
      defaultValue: 5,
    );
  }
}
