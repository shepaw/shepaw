import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../services/logger_service.dart';
import '../utils/exceptions.dart';

/// HTTP客户端包装器 - 添加重试、超时、错误处理
class HttpClientWrapper {
  final http.Client _client;
  final int maxRetries;
  final Duration timeout;
  final Duration retryDelay;

  HttpClientWrapper({
    http.Client? client,
    this.maxRetries = 3,
    this.timeout = const Duration(seconds: 30),
    this.retryDelay = const Duration(seconds: 2),
  }) : _client = client ?? http.Client();

  /// GET请求
  Future<http.Response> get(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    return _executeWithRetry(() async {
      LoggerService().debug('GET $url', tag: 'HTTP');
      final response = await _client
          .get(url, headers: headers)
          .timeout(timeout);
      _logResponse(response);
      return response;
    });
  }

  /// POST请求
  Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    return _executeWithRetry(() async {
      LoggerService().debug('POST $url', tag: 'HTTP');
      final response = await _client
          .post(url, headers: headers, body: body)
          .timeout(timeout);
      _logResponse(response);
      return response;
    });
  }

  /// PUT请求
  Future<http.Response> put(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    return _executeWithRetry(() async {
      LoggerService().debug('PUT $url', tag: 'HTTP');
      final response = await _client
          .put(url, headers: headers, body: body)
          .timeout(timeout);
      _logResponse(response);
      return response;
    });
  }

  /// DELETE请求
  Future<http.Response> delete(
    Uri url, {
    Map<String, String>? headers,
  }) async {
    return _executeWithRetry(() async {
      LoggerService().debug('DELETE $url', tag: 'HTTP');
      final response = await _client
          .delete(url, headers: headers)
          .timeout(timeout);
      _logResponse(response);
      return response;
    });
  }

  /// 执行请求并重试
  Future<http.Response> _executeWithRetry(
    Future<http.Response> Function() request,
  ) async {
    int attempts = 0;
    dynamic lastError;

    while (attempts < maxRetries) {
      try {
        final response = await request();
        
        // 检查响应状态
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response;
        } else if (response.statusCode >= 400 && response.statusCode < 500) {
          // 客户端错误不重试
          _handleHttpError(response);
        } else if (response.statusCode >= 500) {
          // 服务器错误，可重试
          throw NetworkException(
            '服务器错误 (${response.statusCode})',
            code: response.statusCode,
          );
        }
        
        return response;
      } on TimeoutException catch (e) {
        lastError = e;
        LoggerService().warning('请求超时 (尝试 ${attempts + 1}/$maxRetries)', tag: 'HTTP', error: e);
      } on SocketException catch (e) {
        lastError = e;
        LoggerService().warning('网络连接失败 (尝试 ${attempts + 1}/$maxRetries)', tag: 'HTTP', error: e);
      } on NetworkException catch (e) {
        lastError = e;
        LoggerService().warning('网络异常 (尝试 ${attempts + 1}/$maxRetries)', tag: 'HTTP', error: e);
      } catch (e) {
        lastError = e;
        LoggerService().error('请求失败', tag: 'HTTP', error: e);
        throw ExceptionHandler.handle(e);
      }

      attempts++;
      
      if (attempts < maxRetries) {
        await Future.delayed(retryDelay * attempts);
      }
    }

    // 所有重试都失败
    throw NetworkException(
      '请求失败，已重试 $maxRetries 次',
      originalError: lastError,
    );
  }

  /// 处理HTTP错误
  void _handleHttpError(http.Response response) {
    switch (response.statusCode) {
      case 400:
        throw ValidationException('请求参数错误', code: 400);
      case 401:
        throw AuthException('未授权，请重新登录', code: 401);
      case 403:
        throw AuthException('无访问权限', code: 403);
      case 404:
        throw ApiException('请求的资源不存在', code: 404);
      case 429:
        throw ApiException('请求过于频繁，请稍后再试', code: 429);
      default:
        throw ApiException(
          'HTTP ${response.statusCode}: ${response.body}',
          code: response.statusCode,
        );
    }
  }

  /// 记录响应日志
  void _logResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      LoggerService().debug('Response ${response.statusCode}', tag: 'HTTP');
    } else {
      LoggerService().warning(
        'Response ${response.statusCode}: ${response.body}',
        tag: 'HTTP',
      );
    }
  }

  void close() {
    _client.close();
  }
}
