import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../../models/vision/face_models.dart';
import 'face_embedding_engine.dart';
import 'nms.dart';

/// 生产正路引擎：UltraFace（检测）+ MobileFaceNet（112×112 → 192-d embedding）。
///
/// 模型文件放在 `assets/models/face/`（见 `tool/fetch_face_models.sh`）。
/// 文件缺失 / 原生库不可用 / 推理异常时 **一律降级返回空列表**，不抛出；
/// [isAvailable] 通过"两解释器均能加载"判断，供注册表在无模型时切换到 Debug 引擎。
///
/// 模型格式约定（fetch 脚本会以 sha256 锁定以下结构）：
/// - `ultraface.tflite`：输入 `[1, 240, 320, 3]` float32 [0,1]（NHWC）；
///   输出两个张量：scores `[1, N, 2]`、boxes `[1, N, 4]`（Linzaer 版 anchor 布局）。
/// - `mobilefacenet.tflite`：输入 `[1, 112, 112, 3]` float32 [-1,1]；输出 `[1, 192]`。
class TfliteFaceEmbeddingEngine implements FaceEmbeddingEngine {
  TfliteFaceEmbeddingEngine({
    this.detectorAsset = 'assets/models/face/ultraface.tflite',
    this.embedderAsset = 'assets/models/face/mobilefacenet.tflite',
    this.maxFaces = 5,
  });

  final String detectorAsset;
  final String embedderAsset;
  final int maxFaces;

  Interpreter? _detector;
  Interpreter? _embedder;
  bool _loadAttempted = false;

  @override
  String get id => 'tflite-mobilefacenet';

  @override
  String get label =>
      'TFLite UltraFace + MobileFaceNet (112×112 → 192d, on-device)';

  @override
  bool get isDebug => false;

  @override
  double get highThreshold => 0.55;

  @override
  double get lowThreshold => 0.35;

  /// 两个模型解释器都能成功加载才算可用。
  @override
  Future<bool> get isAvailable async {
    final loaded = await _ensureLoaded();
    return loaded && _detector != null && _embedder != null;
  }

  Future<bool> _ensureLoaded() async {
    if (_loadAttempted) return _detector != null && _embedder != null;
    _loadAttempted = true;
    try {
      _detector = await Interpreter.fromAsset(detectorAsset);
    } catch (_) {
      _detector = null; // 资产缺失 / 原生库不可用
    }
    try {
      _embedder = await Interpreter.fromAsset(embedderAsset);
    } catch (_) {
      _embedder = null;
    }
    return _detector != null && _embedder != null;
  }

  @override
  Future<List<FaceEmbedding>> detectAndEmbed(
      Uint8List imageBytes) async {
    if (imageBytes.isEmpty) return const [];
    final loaded = await _ensureLoaded();
    final detector = _detector;
    final embedder = _embedder;
    if (!loaded || detector == null || embedder == null) return const [];

    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) return const [];

      final boxes = _detectFaces(detector, image);
      final results = <FaceEmbedding>[];
      for (final face in boxes) {
        final embedding = await _embedFace(embedder, image, face.box);
        if (embedding == null) continue;
        results.add(FaceEmbedding(
          box: face.box,
          confidence: face.confidence,
          embedding: embedding,
        ));
        if (results.length >= maxFaces) break;
      }
      return results;
    } catch (_) {
      // 推理链路任何异常都静默降级为空结果
      return const [];
    }
  }

  // ---- 检测 ----

  List<_DetectedBox> _detectFaces(
      Interpreter detector, img.Image image) {
    final inputTensor = detector.getInputTensor(0);
    final shape = inputTensor.shape; // [1, h, w, 3]
    if (shape.length != 4 || shape[3] != 3) return const [];
    final h = shape[1];
    final w = shape[2];

    final resized = img.copyResize(image, width: w, height: h);
    final inputBytes =
        _rgbToFloat32Bytes(resized, scale: 1 / 255.0, bias: 0);

    final outputs = detector.getOutputTensors();
    final containers = <int, Object>{};
    final buffers = <int, ByteData>{};
    for (var i = 0; i < outputs.length; i++) {
      final bd = ByteData(outputs[i].numBytes());
      buffers[i] = bd;
      containers[i] = bd.buffer;
    }
    detector.runForMultipleInputs([inputBytes], containers);

    return _parseDetectorOutput(detector, buffers, outputs);
  }

  List<_DetectedBox> _parseDetectorOutput(
      Interpreter detector,
      Map<int, ByteData> buffers,
      List<Tensor> outputs) {
    List<double>? scores;
    List<double>? boxes;
    int n = 0;
    for (var i = 0; i < outputs.length; i++) {
      final outShape = outputs[i].shape;
      if (outShape.length != 3) continue;
      final channels = outShape[2];
      final count = outShape[1];
      final floats = buffers[i]!.buffer.asFloat32List();
      if (channels == 2) {
        scores = floats;
        n = count;
      } else if (channels == 4) {
        boxes = floats;
      }
    }
    if (scores == null || boxes == null || n == 0) return const [];

    final anchors = _generateAnchors(
        detector.getInputTensor(0).shape[2], // w
        detector.getInputTensor(0).shape[1]); // h
    if (anchors.length != n) {
      // anchor 布局与模型不匹配 → 放弃检测（模型变体未知）
      return const [];
    }

    // 收集高分候选（限 top 750 加速 NMS）
    final candidates = <_DetectedBox>[];
    for (var k = 0; k < n; k++) {
      final s = scores[k * 2 + 1];
      if (s < 0.5) continue;
      final ax = anchors[k * 4];
      final ay = anchors[k * 4 + 1];
      final aw = anchors[k * 4 + 2];
      final ah = anchors[k * 4 + 3];
      final bx = boxes[k * 4];
      final by = boxes[k * 4 + 1];
      final bwb = boxes[k * 4 + 2];
      final bhb = boxes[k * 4 + 3];
      final cx = ax + bx * 0.1 * aw;
      final cy = ay + by * 0.1 * ah;
      final fw = aw * math.exp(bwb * 0.2);
      final fh = ah * math.exp(bhb * 0.2);
      candidates.add(_DetectedBox(
        box: FaceBox(
          x: (cx - fw / 2) / detector.inputWidth,
          y: (cy - fh / 2) / detector.inputHeight,
          width: fw / detector.inputWidth,
          height: fh / detector.inputHeight,
        ),
        confidence: s,
      ));
    }
    if (candidates.isEmpty) return const [];

    candidates.sort((a, b) => b.confidence.compareTo(a.confidence));
    final kept = candidates.length <= 750 ? candidates : candidates.sublist(0, 750);

    // NMS
    final keep = nonMaxSuppression(
        [for (final c in kept) c.box], [for (final c in kept) c.confidence]);
    return [for (final i in keep) kept[i]];
  }

  /// Linzaer/Ultra-Light-Fast-Generic-Face-Detector-1MB 版 anchor 布局：
  /// 每层 stride 对应一张 feature map，单元中心 * stride = 像素中心，尺寸恒为 minSize。
  /// 返回像素坐标 [cx, cy, w, h] 平铺。
  List<double> _generateAnchors(int w, int h) {
    const strides = [8, 16, 32, 64];
    const minSize = 16.0;
    final anchors = <double>[];
    for (final stride in strides) {
      final fw = (w / stride).ceil();
      final fh = (h / stride).ceil();
      for (var i = 0; i < fh; i++) {
        for (var j = 0; j < fw; j++) {
          anchors
            ..add((j + 0.5) * stride)
            ..add((i + 0.5) * stride)
            ..add(minSize)
            ..add(minSize);
        }
      }
    }
    return anchors;
  }

  // ---- Embedding ----

  Future<List<double>?> _embedFace(
      Interpreter embedder, img.Image image, FaceBox normalized) async {
    final inputTensor = embedder.getInputTensor(0);
    final shape = inputTensor.shape; // [1, 112, 112, 3]
    if (shape.length != 4 || shape[3] != 3) return null;
    final size = shape[1];
    if (shape[2] != size) return null;

    final crop = _squareCrop(image, normalized);
    final resized = img.copyResize(crop, width: size, height: size);
    final inputBytes = _rgbToFloat32Bytes(resized, scale: 2 / 255.0, bias: -1);

    final outTensor = embedder.getOutputTensors().first;
    final out = ByteData(outTensor.numBytes());
    embedder.runForMultipleInputs([inputBytes], {0: out.buffer});
    final floats = out.buffer.asFloat32List();
    if (floats.isEmpty) return null;
    return floats.toList();
  }

  /// 以人脸框中心做正方形裁剪（MobileFaceNet 期望对齐后的 112×112 输入）。
  img.Image _squareCrop(img.Image image, FaceBox normalized) {
    final w = image.width;
    final h = image.height;
    var x = normalized.x * w;
    var y = normalized.y * h;
    var bw = normalized.width * w;
    var bh = normalized.height * h;
    final cx = x + bw / 2;
    final cy = y + bh / 2;
    final side = math.max(bw, bh) * 1.3; // 留边
    x = cx - side / 2;
    y = cy - side / 2;
    // 钳制到图像边界
    final left = x.clamp(0, w - 1).toDouble();
    final top = y.clamp(0, h - 1).toDouble();
    final right = (x + side).clamp(left + 1, w).toDouble();
    final bottom = (y + side).clamp(top + 1, h).toDouble();
    return img.copyCrop(
      image,
      x: left.round(),
      y: top.round(),
      width: (right - left).round(),
      height: (bottom - top).round(),
    );
  }

  /// 把图像转成 float32 输入字节（NHWC，RGB 顺序）。
  /// [scale] 与 [bias] 控制归一化：检测 [0,1] = scale 1/255、bias 0；
  /// embedding [-1,1] = scale 2/255、bias -1。
  Uint8List _rgbToFloat32Bytes(img.Image image,
      {required double scale, required double bias}) {
    final rgb = image.getBytes(order: img.ChannelOrder.rgb);
    final out = ByteData(rgb.length * 4);
    for (var i = 0; i < rgb.length; i++) {
      out.setFloat32(i * 4, rgb[i] * scale + bias, Endian.little);
    }
    return out.buffer.asUint8List();
  }
}

class _DetectedBox {
  final FaceBox box;
  final double confidence;
  const _DetectedBox({required this.box, required this.confidence});
}

extension on Interpreter {
  double get inputWidth => getInputTensor(0).shape[2].toDouble();
  double get inputHeight => getInputTensor(0).shape[1].toDouble();
}
