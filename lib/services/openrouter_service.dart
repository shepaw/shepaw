import 'dart:convert';
import 'package:http/http.dart' as http;
import 'logger_service.dart';
import '../utils/exceptions.dart';

/// OpenRouter 模型定义
class OpenRouterModel {
  final String id;
  final String name;
  final String? description;
  final int? contextLength;
  final String? modality;   // e.g. "text->text", "text+image->text"
  final double? promptPricing;  // 每 1K tokens 的输入成本（美元）

  OpenRouterModel({
    required this.id,
    required this.name,
    this.description,
    this.contextLength,
    this.modality,
    this.promptPricing,
  });

  factory OpenRouterModel.fromJson(Map<String, dynamic> json) {
    // architecture 是对象 {"modality": "text->text", ...}，不是数组
    final arch = json['architecture'];
    final modality = arch is Map ? arch['modality'] as String? : null;

    // top_provider 是对象 {"is_moderated": true, ...}，不是 int
    // pricing 是对象 {"prompt": "0.00003", ...}
    final pricing = json['pricing'];
    final promptPricing = pricing is Map
        ? double.tryParse(pricing['prompt']?.toString() ?? '')
        : null;

    return OpenRouterModel(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? json['id'] as String? ?? '',
      description: json['description'] as String?,
      contextLength: json['context_length'] as int?,
      modality: modality,
      promptPricing: promptPricing,
    );
  }

  @override
  String toString() => '$name ($id)';
}

/// OpenRouter API 服务
class OpenRouterService {
  static const String baseUrl = 'https://openrouter.ai/api/v1';
  static const String modelsEndpoint = '/models';
  
  // 缓存模型列表，避免频繁请求
  static List<OpenRouterModel>? _cachedModels;
  static DateTime? _cacheTime;
  static const Duration cacheDuration = Duration(hours: 1);

  final http.Client _httpClient;
  final LoggerService _logger = LoggerService();

  OpenRouterService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  /// 获取可用的模型列表
  /// 
  /// 参数:
  /// - [forceRefresh]: 是否强制刷新缓存（默认为 false）
  /// - [apiKey]: OpenRouter API Key（可选，用于特定配额查询）
  /// 
  /// 返回: OpenRouter 可用模型列表，按热度排序
  /// 
  /// 异常:
  /// - [NetworkException]: 网络连接失败
  /// - [AuthException]: API Key 无效
  /// - [ApiException]: API 返回错误
  Future<List<OpenRouterModel>> getModels({
    bool forceRefresh = false,
    String? apiKey,
  }) async {
    try {
      // 检查缓存
      if (!forceRefresh &&
          _cachedModels != null &&
          _cacheTime != null &&
          DateTime.now().difference(_cacheTime!) < cacheDuration) {
        _logger.info('返回缓存的 OpenRouter 模型列表 (${_cachedModels!.length} 个)',
            tag: 'OpenRouter');
        return _cachedModels!;
      }

      _logger.info('从 OpenRouter API 获取模型列表...', tag: 'OpenRouter');

      final url = Uri.parse('$baseUrl$modelsEndpoint');

      // 清洗 API Key：去除换行、回车等非法 HTTP header 字符
      final cleanKey = apiKey?.replaceAll(RegExp(r'[\r\n\t]'), '').trim();

      // 校验 API Key 格式：只允许可打印 ASCII 字符
      if (cleanKey != null && cleanKey.isNotEmpty) {
        if (!RegExp(r'^[\x21-\x7E]+$').hasMatch(cleanKey)) {
          throw const FormatException('API Key 包含非法字符，请重新粘贴正确的 OpenRouter API Key');
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
          'OpenRouter API Key 无效或无访问权限',
          code: response.statusCode,
        );
      }

      if (response.statusCode != 200) {
        throw ApiException(
          'OpenRouter API 返回错误 (${response.statusCode})',
          code: response.statusCode,
        );
      }

      final decoded = jsonDecode(response.body);

      // OpenRouter 可能直接返回数组，也可能返回 {"data": [...]} 格式
      List<dynamic> data;
      if (decoded is List) {
        data = decoded;
      } else if (decoded is Map<String, dynamic>) {
        if (decoded['error'] != null) {
          throw ApiException('OpenRouter API 错误: ${decoded['error']}');
        }
        data = decoded['data'] as List<dynamic>? ?? [];
      } else {
        data = [];
      }
      
      // 解析模型列表并排序
      final models = data
          .whereType<Map<String, dynamic>>()
          .map((m) => OpenRouterModel.fromJson(m))
          .toList();

      // 按名称字母序排序
      models.sort((a, b) => a.name.compareTo(b.name));

      // 更新缓存
      _cachedModels = models;
      _cacheTime = DateTime.now();

      _logger.info('成功获取 ${models.length} 个 OpenRouter 模型', tag: 'OpenRouter');
      return models;
    } catch (e) {
      _logger.error('获取 OpenRouter 模型列表失败', tag: 'OpenRouter', error: e);
      rethrow;
    }
  }

  /// 验证 API Key 的有效性
  /// 
  /// 返回: true 如果 API Key 有效，false 否则
  Future<bool> validateApiKey(String apiKey) async {
    try {
      _logger.info('验证 OpenRouter API Key...', tag: 'OpenRouter');

      final cleanKey = apiKey.replaceAll(RegExp(r'[\r\n\t]'), '').trim();
      if (!RegExp(r'^[\x21-\x7E]+$').hasMatch(cleanKey)) {
        return false;
      }

      final url = Uri.parse('$baseUrl$modelsEndpoint');
      final response = await _httpClient
          .get(
            url,
            headers: {
              'Authorization': 'Bearer $cleanKey',
            },
          )
          .timeout(const Duration(seconds: 10));

      final isValid = response.statusCode == 200;
      _logger.info(
        isValid ? 'API Key 验证成功' : 'API Key 验证失败 (${response.statusCode})',
        tag: 'OpenRouter',
      );
      return isValid;
    } catch (e) {
      _logger.warning('API Key 验证异常', tag: 'OpenRouter', error: e);
      return false;
    }
  }

  /// 清空模型缓存
  static void clearCache() {
    _cachedModels = null;
    _cacheTime = null;
  }

  void close() {
    _httpClient.close();
  }
}
