/// Generation guard for group orchestration turns.
///
/// `ChatController.processGroupMessage` runs a full orchestration that can
/// outlive a user stop: the abort-summarize deliberately runs without the
/// cancellation token, so the old turn keeps going while the next queued
/// message starts a new turn. Without a generation check, the old turn's
/// `finally` would clear the *new* turn's cancellation token, reset
/// `isProcessing`, and drain the queue a second time — and its streaming
/// callbacks would interleave with the new turn's bubbles.
///
/// Each turn captures `final epoch = gate.beginTurn()`; stop methods call
/// [invalidate] so the superseded turn's callbacks and cleanup become no-ops.
/// Dart's single-threaded event loop guarantees a synchronous stop body runs
/// before the orchestration's next continuation, so there is no gap between
/// [invalidate] and the next `beginTurn`.
class GroupTurnGate {
  int _epoch = 0;

  /// Start a new turn, superseding any previous one. Returns the new epoch.
  int beginTurn() => ++_epoch;

  /// Invalidate the current epoch without starting a new turn (user stop).
  void invalidate() {
    _epoch++;
  }

  /// Whether [epoch] still belongs to the latest turn.
  bool isCurrent(int epoch) => epoch == _epoch;
}
