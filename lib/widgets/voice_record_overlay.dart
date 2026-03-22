import 'package:flutter/material.dart';

/// 录音时显示在输入区域上方的覆盖组件
class VoiceRecordOverlay extends StatelessWidget {
  final Duration elapsed;
  final double amplitude;
  final bool isCancelZone;

  const VoiceRecordOverlay({
    Key? key,
    required this.elapsed,
    required this.amplitude,
    required this.isCancelZone,
  }) : super(key: key);

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
