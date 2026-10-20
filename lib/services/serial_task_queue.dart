/// 按 key 串行执行的异步任务队列。
///
/// 同一个 key 的任务严格按入队顺序一个接一个跑，不同 key 之间互不阻塞。
/// 典型用途是「读改写」：后一个任务必须等前一个任务写完，否则两边都拿着
/// 同一份旧快照，后写的会把先写的结果冲掉。
///
/// 任务抛出的异常不会卡住后面的任务（后面的照常执行），但会从这次 [run]
/// 返回的 future 传给调用方。
class SerialTaskQueue<K> {
  final Map<K, Future<void>> _chains = {};

  /// 把 [action] 排到 [key] 的队尾，返回它自己的完成 future。
  Future<void> run(K key, Future<void> Function() action) {
    final previous = _chains[key] ?? Future<void>.value();
    final next = previous.catchError((Object _) {}).then((_) => action());
    _chains[key] = next;
    return next.whenComplete(() {
      if (identical(_chains[key], next)) _chains.remove(key);
    });
  }
}
