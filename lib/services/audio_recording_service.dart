import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'logger_service.dart';

/// 录音状态
class RecordingState {
  final bool isRecording;
  final Duration elapsed;
  final double amplitude;
  final List<double> waveform;

  const RecordingState({
    this.isRecording = false,
    this.elapsed = Duration.zero,
    this.amplitude = 0.0,
    this.waveform = const [],
  });

  RecordingState copyWith({
    bool? isRecording,
    Duration? elapsed,
    double? amplitude,
    List<double>? waveform,
  }) {
    return RecordingState(
      isRecording: isRecording ?? this.isRecording,
      elapsed: elapsed ?? this.elapsed,
      amplitude: amplitude ?? this.amplitude,
      waveform: waveform ?? this.waveform,
    );
  }
}

/// 录音结果
class RecordingResult {
  final String filePath;
  final int durationMs;
  final List<double> waveform;
  final int fileSize;

  const RecordingResult({
    required this.filePath,
    required this.durationMs,
    required this.waveform,
    required this.fileSize,
  });
}

/// 录音服务 - 封装 record 包
class AudioRecordingService {
  final AudioRecorder _recorder = AudioRecorder();
  final _uuid = const Uuid();

  final _stateController = StreamController<RecordingState>.broadcast();
  Stream<RecordingState> get stateStream => _stateController.stream;

  RecordingState _state = const RecordingState();
  RecordingState get currentState => _state;

  Timer? _amplitudeTimer;
  Timer? _elapsedTimer;
  DateTime? _startTime;
  String? _currentPath;
  final List<double> _amplitudes = [];

  static const _maxDuration = Duration(seconds: 60);

  /// 请求麦克风权限
  Future<bool> requestPermission() async {
    // permission_handler 在 macOS/Linux 桌面端没有实现，跳过权限检查
    if (!kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows)) {
      return true;
    }
    try {
      final status = await Permission.microphone.status;
      if (status.isGranted) return true;
      final result = await Permission.microphone.request();
      return result.isGranted;
    } catch (e) {
      LoggerService().error('Permission check failed', tag: 'AudioRecording', error: e);
      return true;
    }
  }

  /// 开始录音
  Future<bool> startRecording() async {
    try {
      final hasPermission = await requestPermission();
      if (!hasPermission) {
        LoggerService().warning('Microphone permission denied', tag: 'AudioRecording');
        return false;
      }

      final dir = await getTemporaryDirectory();
      _currentPath = '${dir.path}/${_uuid.v4()}.m4a';
      _amplitudes.clear();

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: _currentPath!,
      );

      _startTime = DateTime.now();

      _state = const RecordingState(isRecording: true);
      _stateController.add(_state);

      // 采样振幅 ~15Hz
      _amplitudeTimer = Timer.periodic(
        const Duration(milliseconds: 67),
        (_) => _sampleAmplitude(),
      );

      // 更新已录时长
      _elapsedTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => _updateElapsed(),
      );

      return true;
    } catch (e) {
      LoggerService().error('Failed to start recording', tag: 'AudioRecording', error: e);
      return false;
    }
  }

  /// 停止录音并返回结果
  Future<RecordingResult?> stopRecording() async {
    if (!_state.isRecording) return null;

    try {
      _amplitudeTimer?.cancel();
      _elapsedTimer?.cancel();

      final path = await _recorder.stop();
      final durationMs = _startTime != null
          ? DateTime.now().difference(_startTime!).inMilliseconds
          : 0;

      _state = const RecordingState();
      _stateController.add(_state);

      if (path == null || path.isEmpty) return null;

      final file = File(path);
      if (!await file.exists()) return null;

      final fileSize = await file.length();

      return RecordingResult(
        filePath: path,
        durationMs: durationMs,
        waveform: List<double>.from(_amplitudes),
        fileSize: fileSize,
      );
    } catch (e) {
      LoggerService().error('Failed to stop recording', tag: 'AudioRecording', error: e);
      _state = const RecordingState();
      _stateController.add(_state);
      return null;
    }
  }

  /// 取消录音
  Future<void> cancelRecording() async {
    if (!_state.isRecording) return;

    try {
      _amplitudeTimer?.cancel();
      _elapsedTimer?.cancel();

      final path = await _recorder.stop();

      _state = const RecordingState();
      _stateController.add(_state);

      // 删除临时文件
      if (path != null && path.isNotEmpty) {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      }
    } catch (e) {
      LoggerService().error('Failed to cancel recording', tag: 'AudioRecording', error: e);
      _state = const RecordingState();
      _stateController.add(_state);
    }
  }

  void _sampleAmplitude() async {
    try {
      final amp = await _recorder.getAmplitude();
      // amp.current 范围通常是 -160 到 0 dBFS，归一化到 0.0-1.0
      final normalized = ((amp.current + 60) / 60).clamp(0.0, 1.0);
      _amplitudes.add(normalized);

      _state = _state.copyWith(
        amplitude: normalized,
        waveform: List<double>.from(_amplitudes),
      );
      _stateController.add(_state);
    } catch (_) {}
  }

  void _updateElapsed() {
    if (_startTime == null) return;

    final elapsed = DateTime.now().difference(_startTime!);
    _state = _state.copyWith(elapsed: elapsed);
    _stateController.add(_state);

    // 最长录音限制
    if (elapsed >= _maxDuration) {
      stopRecording();
    }
  }

  void dispose() {
    _amplitudeTimer?.cancel();
    _elapsedTimer?.cancel();
    _stateController.close();
    _recorder.dispose();
  }
}
