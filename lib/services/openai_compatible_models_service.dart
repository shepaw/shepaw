import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'logger_service.dart';
import '../utils/exceptions.dart';

/// OpenAI 兼容 `/models` 返回的单个模型条目。
///
/// 不同厂商字段丰俭不一：`id` 之外全部可缺省（TokenHub 会带
/// `name` / `created` / `status`，部分厂商只给 `id`）。
class OpenAiCompatibleModel {
  final String id;
  final String? name;
  final int? created;
  final String? status;

  const OpenAiCompatibleModel({
    required this.id,
    this.name,
    this.created,
    this.status,
  });

  factory OpenAiCompatibleModel.fromJson(Map<String, dynamic> json) {
    final rawCreated = json['created'];
    return OpenAiCompatibleModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String?,
      created: rawCreated is int ? rawCreated : int.tryParse('$rawCreated'),
      status: json['status'] as String?,
    );
  }

  @override
  String toString() => id;
}

/// 通用 OpenAI 兼容模型列表服务：`GET {apiBase}{modelsPath}`。
///
/// 与 OpenRouterService / OllamaService 的专用分支并存——那两个预设的
/// 响应带各自的富元数据（modality/pricing、family/parameter_size），迁到
/// 通用分支会让选择器退化，因此保留专用实现。本服务只服务
/// `LLMProviderConfig.modelsPath` 非空的预设（如 TokenHub）。
class OpenAiCompatibleModelsService {
  /// 缓存按 `(apiBase, modelsPath)` 分键——通用分支的 base 是运行期变量，
  /// 不同地域/厂商不能共用一份目录。
  static final Map<String, List<OpenAiCompatibleModel>> _cache = {};
  static final Map<String, DateTime> _cacheTime = {};
  static const Duration cacheDuration = Duration(hours: 1);

  final http.Client _httpClient;
  final LoggerService _logger = LoggerService();

  OpenAiCompatibleModelsService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  /// 获取可用模型列表。
  ///
  /// 参数:
  /// - [apiBase]: 服务商 API Base（如 `https://tokenhub.tencentmaas.com/v1`）
  /// - [modelsPath]: 模型列表路径（如 `/models`），来自预设的
  ///   [LLMProviderConfig.modelsPath]
  /// - [apiKey]: API Key（可选，多数厂商要求）
  /// - [providerLabel]: 出现在错误文案里的服务商名（如 `TokenHub`）
  /// - [forceRefresh]: 是否强制刷新缓存（默认为 false）
  ///
  /// 异常:
  /// - [NetworkException]: 网络连接失败 / 超时
  /// - [AuthException]: API Key 无效或无访问权限
  /// - [ApiException]: 接口未实现（404）、其它非 200、响应体错误或格式非法
  /// - [FormatException]: API Key 含非法 HTTP header 字符
  Future<List<OpenAiCompatibleModel>> getModels({
    required String apiBase,
    required String modelsPath,
    String? apiKey,
    String providerLabel = '',
    bool forceRefresh = false,
  }) async {
    final label = providerLabel.isEmpty ? 'Provider' : providerLabel;
    final base = apiBase.endsWith('/')
        ? apiBase.substring(0, apiBase.length - 1)
        : apiBase;
    final cacheKey = '$base$modelsPath';

    try {
      // 检查缓存
      final cachedTime = _cacheTime[cacheKey];
      if (!forceRefresh &&
          _cache.containsKey(cacheKey) &&
          cachedTime != null &&
          DateTime.now().difference(cachedTime) < cacheDuration) {
        final cached = _cache[cacheKey]!;
        _logger.info('返回缓存的 $label 模型列表 (${cached.length} 个)',
            tag: 'OpenAiCompatible');
        return cached;
      }

      _logger.info('从 $label API 获取模型列表...', tag: 'OpenAiCompatible');

      final url = Uri.parse('$base$modelsPath');

      // 清洗 API Key：去除换行、回车等非法 HTTP header 字符
      final cleanKey = apiKey?.replaceAll(RegExp(r'[\r\n\t]'), '').trim();

      // 校验 API Key 格式：只允许可打印 ASCII 字符
      if (cleanKey != null && cleanKey.isNotEmpty) {
        if (!RegExp(r'^[\x21-\x7E]+$').hasMatch(cleanKey)) {
          throw FormatException('API Key 包含非法字符，请重新粘贴正确的 $label API Key');
        }
      }

      final headers = {
        'Content-Type': 'application/json',
        if (cleanKey != null && cleanKey.isNotEmpty)
          'Authorization': 'Bearer $cleanKey',
      };

      final response = await _httpClient
          .get(url, headers: headers)
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw AuthException(
          '$label API Key 无效或无访问权限',
          code: response.statusCode,
        );
      }

      if (response.statusCode == 404) {
        // 部分 OpenAI 兼容厂商根本不实现 GET /models —— 明确告知用户改手输 ID，
        // 而不是让他去排查网络。
        throw ApiException(
          '$label 未提供模型列表接口 (404)',
          code: response.statusCode,
        );
      }

      if (response.statusCode != 200) {
        throw ApiException(
          '$label API 返回错误 (${response.statusCode})',
          code: response.statusCode,
        );
      }

      final List<dynamic> data;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is List) {
          // 少数厂商（如 OpenRouter）直接返回顶层数组
          data = decoded;
        } else if (decoded is Map<String, dynamic>) {
          if (decoded['error'] != null) {
            throw ApiException('$label API 错误: ${decoded['error']}');
          }
          data = decoded['data'] as List<dynamic>? ?? [];
        } else {
          throw ApiException('$label 模型列表响应格式错误');
        }
      } on ApiException {
        rethrow;
      } catch (e) {
        // jsonDecode 失败 / data 不是数组 —— 统一成 ApiException（而非裸
        // FormatException），以便界面按服务商错误展示。
        throw ApiException('$label 模型列表响应格式错误', originalError: e);
      }

      // 解析模型列表：跳过非 map 元素与 id 为空的条目
      final models = data
          .whereType<Map<String, dynamic>>()
          .map((m) => OpenAiCompatibleModel.fromJson(m))
          .where((m) => m.id.isNotEmpty)
          .toList();

      // 按 id 排序
      models.sort((a, b) => a.id.compareTo(b.id));

      _cache[cacheKey] = models;
      _cacheTime[cacheKey] = DateTime.now();

      _logger.info('成功获取 ${models.length} 个 $label 模型', tag: 'OpenAiCompatible');
      return models;
    } on http.ClientException catch (e) {
      _logger.error('获取 $label 模型列表失败', tag: 'OpenAiCompatible', error: e);
      throw NetworkException('无法连接 $label API，请检查网络或 API Base 地址',
          originalError: e);
    } on SocketException catch (e) {
      _logger.error('获取 $label 模型列表失败', tag: 'OpenAiCompatible', error: e);
      throw NetworkException('无法连接 $label API，请检查网络或 API Base 地址',
          originalError: e);
    } on TimeoutException catch (e) {
      _logger.error('获取 $label 模型列表超时', tag: 'OpenAiCompatible', error: e);
      throw NetworkException('请求 $label API 超时，请稍后重试',
          isTimeout: true, originalError: e);
    }
  }

  /// 清空模型缓存
  static void clearCache() {
    _cache.clear();
    _cacheTime.clear();
  }

  void close() {
    _httpClient.close();
  }
}
