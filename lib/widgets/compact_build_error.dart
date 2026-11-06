import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 把构建失败收成一条有限高度的提示。
///
/// 默认的 [ErrorWidget] 在列表里会按最大约束撑到约 10 万像素。release
/// 不画错误文字，叠在深色聊天底上就是整段消息区一块灰。提问卡、审核卡
/// 的 metadata 类型一对不上就会走到这里，把正在看的对话盖住。
void installCompactBuildErrorWidget() {
  ErrorWidget.builder = (FlutterErrorDetails details) {
    return _CompactBuildError(details: details);
  };
}

class _CompactBuildError extends StatelessWidget {
  final FlutterErrorDetails details;

  const _CompactBuildError({required this.details});

  @override
  Widget build(BuildContext context) {
    // 不用 Theme / DefaultTextStyle.of：这颗组件就是在那棵树坏掉时画的，
    // 再去依赖它们会第二次抛错。
    final detail = kDebugMode ? details.exceptionAsString() : '';
    final text = detail.isEmpty ? '这条内容暂时显示不了' : detail;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: DefaultTextStyle(
        style: const TextStyle(
          fontSize: 12,
          color: Color(0xFFB71C1C),
          decoration: TextDecoration.none,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: ColoredBox(
            color: const Color(0xFFFFEBEE),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                text,
                maxLines: kDebugMode ? 8 : 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
