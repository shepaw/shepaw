/// Shared classification for a group-agent execution-path failure.
///
/// Local LLM, peer, and ACP catches used to copy-paste the same branch:
/// no visible output → persist "调用失败" and rethrow; bytes already
/// streamed → remember the error and persist "输出被中断" after the path.
enum GroupTurnFailurePhase {
  /// Stream never produced a user-visible buffer.
  beforeStream,

  /// Stream already started; do not persist a truncated reply as success.
  midStream,
}

class GroupTurnOutcome {
  GroupTurnOutcome._();

  /// [responseBuffer] is the live turn buffer (same object the three paths
  /// write into). Empty buffer counts as pre-stream even if a chunk callback
  /// already flipped [streamingStarted].
  static GroupTurnFailurePhase classifyFailure({
    required bool streamingStarted,
    required StringBuffer responseBuffer,
  }) {
    if (!streamingStarted || responseBuffer.isEmpty) {
      return GroupTurnFailurePhase.beforeStream;
    }
    return GroupTurnFailurePhase.midStream;
  }

  static String failureNotice({
    required String agentName,
    required Object error,
    required GroupTurnFailurePhase phase,
  }) {
    final verb =
        phase == GroupTurnFailurePhase.midStream ? '输出被中断' : '调用失败';
    return '⚠️ Agent「$agentName」$verb：$error';
  }
}
