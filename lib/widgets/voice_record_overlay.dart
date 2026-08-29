import 'package:flutter/material.dart';

import '../services/audio_recording_service.dart';

/// 录音时显示在输入区域上方的覆盖组件。
///
/// 振幅/计时的高频更新（~15Hz）由 [AudioRecordingService.stateNotifier]
/// 驱动，在组件内部局部订阅，避免整页 setState。只有 [isCancelZone]
/// 这类低频状态仍从外部传入。
class VoiceRecordOverlay extends StatelessWidget {
  final AudioRecordingService audioRecordingService;
  final bool isCancelZone;

  const VoiceRecordOverlay({
    Key? key,
    required this.audioRecordingService,
    required this.isCancelZone,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RecordingState>(
      valueListenable: audioRecordingService.stateNotifier,
      builder: (context, state, _) {
        return _RecordingChrome(
          elapsed: state.elapsed,
          amplitude: state.amplitude,
          isCancelZone: isCancelZone,
        );
      },
    );
  }
}

class _RecordingChrome extends StatelessWidget {
  final Duration elapsed;
  final double amplitude;
  final bool isCancelZone;

  const _RecordingChrome({
    required this.elapsed,
    required this.amplitude,
    required this.isCancelZone,
  });

  String get _timerText {
    final minutes = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = isCancelZone ? Colors.red[50] : Colors.grey[100];
    final accentColor = isCancelZone ? Colors.red : Theme.of(context).primaryColor;

    // 脉动红点大小随振幅变化
    final dotSize = 12.0 + amplitude * 8.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: bgColor,
        border: Border(
          top: BorderSide(color: Colors.grey[300]!, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // 脉动红点
          AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: dotSize,
            height: dotSize,
            decoration: BoxDecoration(
              color: accentColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),

          // 录音计时器
          Text(
            _timerText,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: accentColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),

          const Spacer(),

          // 提示文字
          Text(
            isCancelZone ? 'Release to cancel' : 'Swipe up to cancel',
            style: TextStyle(
              fontSize: 14,
              color: isCancelZone ? Colors.red : Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }
}
