import 'dart:async';
import 'package:flutter/material.dart';
import '../models/message.dart';
import '../services/audio_playback_service.dart';
import '../services/local_file_storage_service.dart';

/// 语音消息气泡内容组件
class VoiceMessageBubble extends StatefulWidget {
  final Message message;
  final bool isMyMessage;

  const VoiceMessageBubble({
    Key? key,
    required this.message,
    required this.isMyMessage,
  }) : super(key: key);

  @override
  State<VoiceMessageBubble> createState() => _VoiceMessageBubbleState();
}

class _VoiceMessageBubbleState extends State<VoiceMessageBubble> {
  final _playbackService = AudioPlaybackService();
  StreamSubscription<AudioPlaybackState>? _subscription;
  AudioPlaybackState _playbackState = const AudioPlaybackState();

  @override
  void initState() {
    super.initState();
    _subscription = _playbackService.stateStream.listen((state) {
      if (mounted) {
        setState(() {
          _playbackState = state;
        });
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  bool get _isThisPlaying =>
      _playbackState.messageId == widget.message.id && _playbackState.isPlaying;

  double get _progress {
    if (_playbackState.messageId != widget.message.id) return 0.0;
    if (_playbackState.duration.inMilliseconds == 0) return 0.0;
    return (_playbackState.position.inMilliseconds /
            _playbackState.duration.inMilliseconds)
        .clamp(0.0, 1.0);
  }

  List<double> get _waveform {
    final raw = widget.message.metadata?['waveform'];
    if (raw is List) {
      return raw.map((e) => (e as num).toDouble()).toList();
    }
    return List.filled(20, 0.3);
  }

  /// 降采样为固定柱条数
  List<double> _downsample(List<double> data, int targetCount) {
    if (data.isEmpty) return List.filled(targetCount, 0.3);
    if (data.length <= targetCount) {
      return List.generate(targetCount, (i) {
        return i < data.length ? data[i] : 0.3;
      });
    }
    final step = data.length / targetCount;
    return List.generate(targetCount, (i) {
      final start = (i * step).floor();
      final end = ((i + 1) * step).floor().clamp(start + 1, data.length);
      double sum = 0;
      for (var j = start; j < end; j++) {
        sum += data[j];
      }
      return sum / (end - start);
    });
  }

  String get _durationText {
    final ms = widget.message.metadata?['duration_ms'] as int? ?? 0;
    final seconds = (ms / 1000).round();
    return '${seconds}s';
  }

  Future<void> _onTap() async {
    final relativePath = widget.message.metadata?['path'] as String?;
    if (relativePath == null) return;

    final fullPath = await LocalFileStorageService().getFullPath(relativePath);
    await _playbackService.playOrToggle(widget.message.id, fullPath);
  }

  @override
  Widget build(BuildContext context) {
    const barCount = 20;
    final bars = _downsample(_waveform, barCount);
    final highlightedBars = (_progress * barCount).floor();

    final primaryColor =
        widget.isMyMessage ? Colors.white : Theme.of(context).primaryColor;
    final inactiveColor =
        widget.isMyMessage ? Colors.white54 : Colors.grey[400]!;

    return GestureDetector(
      onTap: _onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 播放/暂停图标
          Icon(
            _isThisPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
            color: primaryColor,
            size: 28,
          ),
          const SizedBox(width: 8),

          // 波形条
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(barCount, (i) {
              final height = (bars[i] * 20).clamp(3.0, 20.0);
              final isHighlighted = i < highlightedBars;
              return Container(
                width: 2.5,
                height: height,
                margin: const EdgeInsets.symmetric(horizontal: 0.5),
                decoration: BoxDecoration(
                  color: isHighlighted ? primaryColor : inactiveColor,
                  borderRadius: BorderRadius.circular(1.5),
                ),
              );
            }),
          ),
          const SizedBox(width: 8),

          // 时长
          Text(
            _durationText,
            style: TextStyle(
              fontSize: 12,
              color: primaryColor,
            ),
          ),
        ],
      ),
    );
  }
}
