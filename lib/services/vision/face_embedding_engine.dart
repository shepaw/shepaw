import 'dart:typed_data';

import '../../models/vision/face_models.dart';
import 'debug_face_embedding_engine.dart';
import 'tflite_face_embedding_engine.dart';

/// 人脸特征引擎抽象：检测人脸并产出 embedding 向量。
///
/// 实现：
/// - [TfliteFaceEmbeddingEngine]（生产正路，on-device）
/// - [DebugFaceEmbeddingEngine]（确定性伪 embedding，无模型文件时降级 / 测试）
///
/// 引擎必须是无状态可重入的；`detectAndEmbed` 每次独立处理一张图。
abstract class FaceEmbeddingEngine {
  /// 统一 embedding 维度（MobileFaceNet 192-d；Debug 引擎也返回同维，
  /// 保证 veda 向量库维度在引擎切换时保持稳定）。
  static const int embeddingDim = 192;

  /// 引擎标识（'tflite-mobilefacenet' | 'debug'）。
  String get id;

  /// 人类可读标签。
  String get label;

  /// 是否为降级/非生物特征引擎。
  bool get isDebug;

  /// 引擎当前是否可用（模型文件/原生库是否就绪）。
  ///
  /// TFLite 引擎会做资产探测并吞掉原生加载异常；Debug 恒为 true。
  Future<bool> get isAvailable;

  /// 该引擎下"已识别"的余弦阈值。
  double get highThreshold;

  /// 该引擎下"未知"的余弦阈值（两者之间为存疑）。
  double get lowThreshold;

  /// 检测图片中的所有人脸并产出 embedding。
  ///
  /// 空图 / 无可解码像素 → 返回空列表；失败不得抛出（引擎内部兜底）。
  Future<List<FaceEmbedding>> detectAndEmbed(Uint8List imageBytes);
}

/// 引擎注册表：按 [tflite, debug] 顺序解析首个可用引擎。
class FaceEmbeddingEngineRegistry {
  static final FaceEmbeddingEngineRegistry instance =
      FaceEmbeddingEngineRegistry._();

  FaceEmbeddingEngineRegistry._();

  Future<FaceEmbeddingEngine>? _cached;

  /// 解析当前主引擎（带缓存；[reset] 可清除缓存）。
  Future<FaceEmbeddingEngine> resolve() => _cached ??= _resolve();

  Future<FaceEmbeddingEngine> _resolve() async {
    final tflite = TfliteFaceEmbeddingEngine();
    if (await tflite.isAvailable) return tflite;
    return const DebugFaceEmbeddingEngine();
  }

  /// 清空解析缓存（模型文件就绪后调用，可让引擎切换生效）。
  void reset() => _cached = null;
}
