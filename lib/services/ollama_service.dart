import 'dart:convert';
import 'package:http/http.dart' as http;
import 'logger_service.dart';
import '../utils/exceptions.dart';

/// Ollama 本地模型定义
class OllamaModel {
  final String name;
  final String? family;
  final String? parameterSize;
  final String? quantizationLevel;
  final int? sizeBytes;

  OllamaModel({
    required this.name,
    this.family,
    this.parameterSize,
    this.quantizationLevel,
    this.sizeBytes,
  });

  factory OllamaModel.fromJson(Map<String, dynamic> json) {
    final details = json['details'];
    return OllamaModel(
      name: json['name'] as String? ?? json['model'] as String? ?? '',
      family: details is Map ? details['family'] as String? : null,
      parameterSize:
          details is Map ? details['parameter_size'] as String? : null,
      quantizationLevel:
          details is Map ? details['quantization_level'] as String? : null,
      sizeBytes: json['size'] as int?,
    );
  }

  String? get description {
    final parts = <String>[];
    if (family != null && family!.isNotEmpty) parts.add(family!);
    if (parameterSize != null && parameterSize!.isNotEmpty) {
      parts.add(parameterSize!);
    }
    if (quantizationLevel != null && quantizationLevel!.isNotEmpty) {
      parts.add(quantizationLevel!);
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  String toString() => name;
}

/// Ollama 本地 API 服务
class OllamaService {
  static List<OllamaModel>? _cachedModels;
  static String? _cachedApiBase;
  static DateTime? _cacheTime;
  static const Duration cacheDuration = Duration(minutes: 5);

  final http.Client _httpClient;
  final LoggerService _logger = LoggerService();

  OllamaService({http.Client? httpClient})
      : _httpClient = httpClient ?? http.Client();

  /// 从 OpenAI 兼容 apiBase（如 `http://localhost:11434/v1`）解析 Ollama 根地址
  static String resolveRootUrl(String apiBase) {
    final trimmed = apiBase.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.endsWith('/v1')) {
      return trimmed.substring(0, trimmed.length - 3);
    }
    return trimmed;
  }

  /// 获取 Ollama 已安装的本地模型列表
  Future<List<OllamaModel>> getModels({
    required String apiBase,
    bool forceRefresh = false,
  }) async {
    final root = resolveRootUrl(apiBase);
    if (root.isEmpty) {
      throw const FormatException('请先填写有效的 Ollama API Base 地址');
    }

    try {
      if (!forceRefresh &&
          _cachedModels != null &&
          _cachedApiBase == root &&
          _cacheTime != null &&
          DateTime.now().difference(_cacheTime!) < cacheDuration) {
        _logger.info('返回缓存的 Ollama 模型列表 (${_cachedModels!.length} 个)',
            tag: 'Ollama');
        return _cachedModels!;
      }

      _logger.info('从 Ollama 获取本地模型列表: $root', tag: 'Ollama');

      final url = Uri.parse('$root/api/tags');
      final response = await _httpClient
          .get(url, headers: {'Content-Type': 'application/json'})
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw ApiException(
          'Ollama API 返回错误 (${response.statusCode})',
          code: response.statusCode,
        );
      }

      final decoded = jsonDecode(response.body);
      final modelsJson = decoded is Map<String, dynamic>
          ? decoded['models'] as List<dynamic>? ?? []
          : <dynamic>[];

      final models = modelsJson
          .whereType<Map<String, dynamic>>()
          .map(OllamaModel.fromJson)
          .where((m) => m.name.isNotEmpty)
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      _cachedModels = models;
      _cachedApiBase = root;
      _cacheTime = DateTime.now();

      _logger.info('成功获取 ${models.length} 个 Ollama 本地模型', tag: 'Ollama');
      return models;
    } on http.ClientException catch (e) {
      _logger.error('连接 Ollama 失败', tag: 'Ollama', error: e);
      throw NetworkException(
        '无法连接 Ollama 服务，请确认 Ollama 已启动且 API Base 地址正确',
        originalError: e,
      );
    } catch (e) {
      _logger.error('获取 Ollama 模型列表失败', tag: 'Ollama', error: e);
      rethrow;
    }
  }

  /// Verify Ollama is reachable at [apiBase]. Throws on failure.
  Future<int> testConnection({required String apiBase}) async {
    final models = await getModels(apiBase: apiBase, forceRefresh: true);
    return models.length;
  }

  static void clearCache() {
    _cachedModels = null;
    _cachedApiBase = null;
    _cacheTime = null;
  }

  void close() {
    _httpClient.close();
  }
}
