import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../peer/models/flow_models.dart';
import '../../peer/services/hub_flow.dart';
import 'flow_editor_notice.dart';

/// 演练：不调任何 Agent，用回声执行器把流程走一遍（方案 C.5）。
///
/// 原来这段逻辑写在 `flow_design_screen.dart` 里，和界面状态混在一起。拆出来
/// 之后它只管「演练自身的生命周期」：开跑、按派活顺序点亮、卡在关卡时作答、
/// 结束。演练期间禁止编辑这件事由控制器读 [active] 统一拦。
class FlowRehearsalRunner extends ChangeNotifier {
  FlowRehearsalRunner({
    required this.client,
    required this.peerId,
    this.stepInterval = const Duration(milliseconds: 350),
    this.onNotice,
  });

  final HubFlow client;
  final String peerId;

  /// 每一步点亮的间隔。
  final Duration stepInterval;

  /// 出错时通知界面（主机没应答 / 演练失败）。
  final void Function(FlowEditorNotice notice)? onNotice;

  FlowRehearsal? _rehearsal;
  int _progress = 0;
  Timer? _timer;
  bool _answering = false;

  bool get active => _rehearsal != null;
  bool get answering => _answering;
  FlowRehearsal? get rehearsal => _rehearsal;
  int get progress => _progress;

  /// 卡住的问题。动画还在点亮时不急着把选项摆出来。
  FlowQuestion? get waiting {
    final rehearsal = _rehearsal;
    if (rehearsal == null) return null;
    if (_progress < rehearsal.steps.length) return null;
    return rehearsal.question;
  }

  /// 演练时画演练返回的树（循环按真实跑的轮数展开），按派活顺序点亮。
  List<FlowNode> view(List<FlowNode> draftTree) {
    final rehearsal = _rehearsal;
    if (rehearsal == null) return draftTree;
    final steps = rehearsal.steps;
    final doneCount = _progress.clamp(0, steps.length);
    final done = steps.take(doneCount > 0 ? doneCount - 1 : 0).toSet();
    final running = doneCount > 0 && doneCount <= steps.length
        ? steps[doneCount - 1]
        : null;
    // 点亮完这一段（或这一段本来没有活要派）就算走到了。
    final finished = _progress >= steps.length;
    return [
      for (final node in rehearsal.tree)
        node.withProgress(
            finished ? steps.toSet() : done, finished ? null : running),
    ];
  }

  Future<void> start(String yaml) async {
    final got = await client.rehearse(peerId, yaml);
    final rehearsal = got.rehearsal;
    if (rehearsal == null) {
      onNotice?.call(got.error == null
          ? const FlowEditorNotice(FlowEditorNoticeKind.hostNoReply)
          : FlowEditorNotice(FlowEditorNoticeKind.editRejected,
              raw: got.error));
      return;
    }
    _animate(rehearsal);
  }

  /// 演练卡在关卡 / 判断时作答，接着往下走。
  Future<void> answer(String choice) async {
    final current = _rehearsal;
    final id = current?.rehearsalId ?? '';
    if (id.isEmpty) return;
    _answering = true;
    notifyListeners();
    final got = await client.rehearseAnswer(peerId, id, choice);
    _answering = false;
    final next = got.rehearsal;
    if (next == null) {
      onNotice?.call(got.error == null
          ? const FlowEditorNotice(FlowEditorNoticeKind.hostNoReply)
          : FlowEditorNotice(FlowEditorNoticeKind.editRejected,
              raw: got.error));
      stop();
      return;
    }
    // 接着点亮新派出去的那些活。
    _animate(next);
  }

  /// 卡片依次点亮，走完（或到卡住的地方）就把问题摆出来。
  void _animate(FlowRehearsal rehearsal) {
    _timer?.cancel();
    _rehearsal = rehearsal;
    _progress = 0;
    notifyListeners();
    _timer = Timer.periodic(stepInterval, (timer) {
      _progress++;
      if (_progress >= rehearsal.steps.length) timer.cancel();
      notifyListeners();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    final id = _rehearsal?.rehearsalId ?? '';
    _rehearsal = null;
    _progress = 0;
    notifyListeners();
    if (id.isNotEmpty) unawaited(client.rehearseDrop(peerId, id));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
