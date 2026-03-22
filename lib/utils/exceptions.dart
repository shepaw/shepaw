/// 应用异常基类
abstract class AppException implements Exception {
  final String message;
  final int? code;
  final dynamic originalError;

  AppException(this.message, {this.code, this.originalError});

  @override
  String toString() => message;
}

/// 网络异常
class NetworkException extends AppException {
  final bool isTimeout;

  NetworkException(
    String message, {
    int? code,
    dynamic originalError,
    this.isTimeout = false,
  }) : super(message, code: code, originalError: originalError);

  String getUserMessage() {
    if (isTimeout) {
      return '网络请求超时,请检查网络连接后重试';
    }

    if (code != null) {
      switch (code) {
        case 401:
          return '认证失败,请重新登录';
        case 403:
          return '无权访问此资源';
        case 404:
          return '请求的资源不存在';
        case 429:
          return '请求过于频繁,请稍后再试';
        case 500:
        case 502:
        case 503:
          return '服务器错误,请稍后再试';
        case 504:
          return '服务器响应超时,请稍后再试';
        default:
          return '网络请求失败 (错误码: $code)';
      }
    }

    return message;
  }
}

/// API异常
class ApiException extends AppException {
  ApiException(String message, {int? code, dynamic originalError})
      : super(message, code: code, originalError: originalError);
}

/// 认证异常
class AuthException extends AppException {
  AuthException(String message, {int? code, dynamic originalError})
      : super(message, code: code, originalError: originalError);
}

/// 验证异常
class ValidationException extends AppException {
  ValidationException(String message, {int? code, dynamic originalError})
      : super(message, code: code, originalError: originalError);
}

/// 存储异常
class StorageException extends AppException {
  StorageException(String message, {int? code, dynamic originalError})
      : super(message, code: code, originalError: originalError);
}

/// WebSocket异常
class WebSocketException extends AppException {
  WebSocketException(String message, {int? code, dynamic originalError})
      : super(message, code: code, originalError: originalError);
}

/// Agent 相关异常
class AgentException extends AppException {
  final String? agentId;
  final AgentErrorType type;

  AgentException(
    String message, {
    int? code,
    dynamic originalError,
    this.agentId,
    this.type = AgentErrorType.unknown,
  }) : super(message, code: code, originalError: originalError);

  String getUserMessage() {
    switch (type) {
      case AgentErrorType.notFound:
        return 'Agent 不存在或已被删除';
      case AgentErrorType.offline:
        return 'Agent 当前离线,无法响应请求';
      case AgentErrorType.timeout:
        return 'Agent 响应超时,请稍后重试';
      case AgentErrorType.rateLimited:
        return 'Agent 请求频率过高,请稍后再试';
      case AgentErrorType.unauthorized:
        return '无权访问此 Agent';
      case AgentErrorType.configError:
        return 'Agent 配置错误';
      case AgentErrorType.executionError:
        return 'Agent 执行任务失败: $message';
      case AgentErrorType.unknown:
      default:
        return 'Agent 错误: $message';
    }
  }
}

/// Agent 错误类型枚举
enum AgentErrorType {
  notFound,
  offline,
  timeout,
  rateLimited,
  unauthorized,
  configError,
  executionError,
  unknown,
}

/// 数据解析异常
class DataParseException extends AppException {
  final String? field;

  DataParseException(
    String message, {
    int? code,
    dynamic originalError,
    this.field,
  }) : super(message, code: code, originalError: originalError);

  String getUserMessage() {
    if (field != null) {
      return '数据格式错误: "$field" 字段解析失败';
    }
    return '数据格式错误,请联系技术支持';
  }
}

/// 数据库异常
class DatabaseException extends AppException {
  final DatabaseErrorType type;

  DatabaseException(
    String message, {
    int? code,
    dynamic originalError,
    this.type = DatabaseErrorType.unknown,
  }) : super(message, code: code, originalError: originalError);

  String getUserMessage() {
    switch (type) {
      case DatabaseErrorType.notFound:
        return '数据不存在';
      case DatabaseErrorType.duplicateKey:
        return '数据已存在,无法重复创建';
      case DatabaseErrorType.constraintViolation:
        return '数据约束冲突';
      case DatabaseErrorType.connectionError:
        return '数据库连接失败';
      case DatabaseErrorType.unknown:
      default:
        return '数据库错误: $message';
    }
  }
}

/// 数据库错误类型枚举
enum DatabaseErrorType {
  notFound,
  duplicateKey,
  constraintViolation,
  connectionError,
  unknown,
}

/// 权限异常
class PermissionException extends AppException {
  final String? permission;

  PermissionException(
    String message, {
    int? code,
    dynamic originalError,
    this.permission,
  }) : super(message, code: code, originalError: originalError);

  String getUserMessage() {
    if (permission != null) {
      return '缺少 $permission 权限,请在设置中授予权限';
    }
    return '权限不足: $message';
  }
}

/// 异常工具类
class ExceptionHandler {
  /// 将通用异常转换为应用异常
  static AppException handle(dynamic error) {
    if (error is AppException) {
      return error;
    }

    if (error is FormatException) {
      return ApiException('数据格式错误', originalError: error);
    }

    if (error.toString().contains('SocketException')) {
      return NetworkException('网络连接失败，请检查网络设置', originalError: error);
    }

    if (error.toString().contains('TimeoutException')) {
      return NetworkException('网络请求超时，请稍后重试', originalError: error);
    }

    return ApiException('发生未知错误: ${error.toString()}', originalError: error);
  }

  /// 获取用户友好的错误信息
  static String getUserMessage(dynamic error) {
    if (error is NetworkException) {
      return error.getUserMessage();
    } else if (error is AgentException) {
      return error.getUserMessage();
    } else if (error is DataParseException) {
      return error.getUserMessage();
    } else if (error is DatabaseException) {
      return error.getUserMessage();
    } else if (error is PermissionException) {
      return error.getUserMessage();
    } else if (error is AppException) {
      return error.message;
    }
    return '操作失败，请稍后重试';
  }
}
