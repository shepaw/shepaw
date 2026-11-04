import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../peer/models/flow_models.dart';
import '../../peer/services/hub_flow.dart';
import 'flow_editor_notice.dart';

/// 演练：不调任何 Agent，用回声执行器把流程走一遍（方案 C.5）。
///
/// 演练期间禁止编辑这件事由控制器读 [active] 统一拦。
class FlowRehearsalRunner extends ChangeNotifier {
  FlowRehearsalRunner({
    required this.client,
    required this.peerId,
    this.stepInterval = const Duration(milliseconds: 350),
    this.onNotice,
  });

  final HubFlow client;
  final String peerId;
  final Duration stepInterval;
  final void Function(FlowEditorNotice notice)? onNotice;

  FlowRehearsal? _rehearsal;
  int _progress = 0;
  Timer? _timer;
  bool _answering = false;
  bool _disposed = false;

  bool get active => _rehearsal != null;
  bool get answering => _answering;
  FlowRehearsal? get rehearsal => _rehearsal;
  int get progress => _progress;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  FlowQuestion? get waiting {
    final rehearsal = _rehearsal;
    if (rehearsal == null) return null;
    if (_progress < rehearsal.steps.length) return null;
    return rehearsal.question;
  }

  List<FlowNode> view(List<FlowNode> draftTree) {
    final rehearsal = _rehearsal;
    if (rehearsal == null) return draftTree;
    final steps = rehearsal.steps;
    final doneCount = _progress.clamp(0, steps.length);
    final done = steps.take(doneCount > 0 ? doneCount - 1 : 0).toSet();
    final running = doneCount > 0 && doneCount <= steps.length
        ? steps[doneCount - 1]
        : null;
    final finished = _progress >= steps.length;
    return [
      for (final node in rehearsal.tree)
        node.withProgress(
            finished ? steps.toSet() : done, finished ? null : running),
    ];
  }

  /// 返回是否真的开起来了（失败时不该让调用方以为演练已在跑）。
  Future<bool> start(String yaml) async {
    final got = await client.rehearse(peerId, yaml);
    if (_disposed) return false;
    final rehearsal = got.rehearsal;
    if (rehearsal == null) {
      onNotice?.call(got.error == null
          ? const FlowEditorNotice(FlowEditorNoticeKind.hostNoReply)
          : FlowEditorNotice(FlowEditorNoticeKind.editRejected,
              raw: got.error));
      return false;
    }
    _animate(rehearsal);
    return true;
  }

  Future<void> answer(String choice) async {
    final current = _rehearsal;
    final id = current?.rehearsalId ?? '';
    if (id.isEmpty) return;
    _answering = true;
    _notify();
    final got = await client.rehearseAnswer(peerId, id, choice);
    _answering = false;
    if (_disposed) return;
    final next = got.rehearsal;
    if (next == null) {
      onNotice?.call(got.error == null
          ? const FlowEditorNotice(FlowEditorNoticeKind.hostNoReply)
          : FlowEditorNotice(FlowEditorNoticeKind.editRejected,
              raw: got.error));
      stop();
      return;
    }
    _animate(next);
  }

  void _animate(FlowRehearsal rehearsal) {
    _timer?.cancel();
    _rehearsal = rehearsal;
    _progress = 0;
    _notify();
    _timer = Timer.periodic(stepInterval, (timer) {
      _progress++;
      if (_progress >= rehearsal.steps.length) timer.cancel();
      _notify();
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    final id = _rehearsal?.rehearsalId ?? '';
    _rehearsal = null;
    _progress = 0;
    _notify();
    if (id.isNotEmpty) unawaited(client.rehearseDrop(peerId, id));
  }

  @override
  void dispose() {
    // 主机那边的演练要显式结束，否则会一直留在内存里。
    final id = _rehearsal?.rehearsalId ?? '';
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _rehearsal = null;
    if (id.isNotEmpty) unawaited(client.rehearseDrop(peerId, id));
    super.dispose();
  }
}
