import 'dart:async';

import 'device_identity.dart';
import 'store_service.dart';

/// 交接通知缓存项（来自 master `events.list` / `handoff.created`）。
class HandoffNotice {
  HandoffNotice({
    required this.seq,
    required this.uri,
    required this.device,
    required this.tsMs,
    this.context,
  });

  final int seq;
  final String uri;
  final String device;
  final int tsMs;
  final String? context;
}

/// 轮询 master 的 `handoff.created` 事件，供储物袋总览角标使用。
class HandoffNotifyService {
  HandoffNotifyService._();
  static final HandoffNotifyService instance = HandoffNotifyService._();

  final _changed = StreamController<void>.broadcast();
  Stream<void> get onChanged => _changed.stream;

  final List<HandoffNotice> _notices = [];
  List<HandoffNotice> get notices => List.unmodifiable(_notices);

  int get count => _notices.length;

  int _since = 0;
  Timer? _timer;
  bool _busy = false;

  void start({Duration interval = const Duration(seconds: 12)}) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(poll()));
    unawaited(poll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> poll() async {
    if (_busy) return;
    _busy = true;
    try {
      if (await StoreService.instance.isMaster()) return;
      final data = await StoreService.instance.eventsList(
        since: _since,
        limit: 50,
        kind: 'handoff.created',
      );
      if (data == null || data['_error'] != null) return;
      final latest = (data['latest_seq'] as num?)?.toInt() ?? _since;
      final events = (data['events'] as List?) ?? const [];
      var added = false;
      for (final raw in events) {
        if (raw is! Map) continue;
        final seq = (raw['seq'] as num?)?.toInt() ?? 0;
        final uri = '${raw['uri'] ?? raw['detail']?['handoff_uri'] ?? ''}';
        if (uri.isEmpty) continue;
        if (_notices.any((n) => n.seq == seq && n.uri == uri)) continue;
        _notices.insert(
          0,
          HandoffNotice(
            seq: seq,
            uri: uri,
            device: '${raw['device'] ?? ''}',
            tsMs: (raw['ts_ms'] as num?)?.toInt() ?? 0,
            context: raw['detail'] is Map
                ? '${(raw['detail'] as Map)['context'] ?? ''}'
                : null,
          ),
        );
        added = true;
      }
      if (_notices.length > 50) {
        _notices.removeRange(50, _notices.length);
      }
      if (latest > _since) _since = latest;
      if (added && !_changed.isClosed) _changed.add(null);
    } finally {
      _busy = false;
    }
  }

  void dismissAll() {
    _notices.clear();
    if (!_changed.isClosed) _changed.add(null);
  }

  /// 本机 device id（供 UI 展示）。
  Future<String> selfDeviceId() => DeviceIdentity.deviceId();
}
