import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/catalog_model.dart';
import '../utils/exceptions.dart';
import 'logger_service.dart';
import 'update_service.dart';

/// 官方模型目录服务
///
/// 从 channel 服务 `GET /api/v1/models` 拉取管理员维护的模型目录。
/// 基址与 check-update 同源（复用 [UpdateService.getCheckUpdateBaseUrl]），
/// 用户在设置中配置了自定义更新域名时也自动跟随。
///
/// 结果带 1 小时内存缓存，避免频繁请求。
class ModelCatalogService {
  ModelCatalogService({
    http.Client? httpClient,
    Future<String> Function()? baseUrlProvider,
  })  : _httpClient = httpClient ?? http.Client(),
        _baseUrlProvider = baseUrlProvider ?? _defaultBaseUrlProvider;

  final http.Client _httpClient;
  final Future<String> Function() _baseUrlProvider;
  final LoggerService _logger = LoggerService();

  /// 共享实例：进入模型配置页自动拉取时复用，使 1 小时缓存跨页面生效。
  static final ModelCatalogService shared = ModelCatalogService();

  static const Duration _cacheDuration = Duration(hours: 1);
  static const Duration _requestTimeout = Duration(seconds: 10);

  List<CatalogModel>? _cachedModels;
  DateTime? _cacheTime;
  Future<List<CatalogModel>>? _inFlight;

  static Future<String> _defaultBaseUrlProvider() =>
      UpdateService().getCheckUpdateBaseUrl();

  /// 拉取模型目录（带 1 小时缓存；[forceRefresh] 跳过缓存）。
  ///
  /// 异常：
  /// - [NetworkException]：网络不可达/超时
  /// - [ApiException]：服务端返回非 200 或响应格式错误
  Future<List<CatalogModel>> fetchModels({bool forceRefresh = false}) async {
    if (!forceRefresh && _cachedModels != null && _cacheTime != null) {
      if (DateTime.now().difference(_cacheTime!) < _cacheDuration) {
        return _cachedModels!;
      }
    }

    // 并发去重：页面进入自动预取与用户点击导入同时发生时，只发一次请求
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final future = _doFetch();
    _inFlight = future;
    try {
      return await future;
    } finally {
      _inFlight = null;
    }
  }

  Future<List<CatalogModel>> _doFetch() async {
    final base = await _baseUrlProvider();
    final uri = Uri.parse('$base/api/v1/models');
    _logger.debug('Fetching model catalog: $uri', tag: 'ModelCatalog');

    try {
      final response = await _httpClient.get(uri).timeout(_requestTimeout);
      if (response.statusCode != 200) {
        throw ApiException(
          '模型目录请求失败 (HTTP ${response.statusCode})',
          code: response.statusCode,
        );
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final list = json['models'] as List<dynamic>? ?? const [];
      final models = list
          .map((e) => CatalogModel.fromJson(e as Map<String, dynamic>))
          .toList();

      _cachedModels = models;
      _cacheTime = DateTime.now();
      return models;
    } on TimeoutException {
      throw NetworkException('模型目录请求超时，请稍后重试', isTimeout: true);
    } on SocketException catch (e) {
      throw NetworkException('网络连接失败，请检查网络设置', originalError: e);
    } on http.ClientException catch (e) {
      throw NetworkException('网络请求失败，请检查网络设置', originalError: e);
    } on FormatException catch (e) {
      throw ApiException('模型目录数据格式错误', originalError: e);
    }
  }

  void close() => _httpClient.close();
}
