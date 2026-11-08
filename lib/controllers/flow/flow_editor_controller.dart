import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../peer/models/flow_models.dart';
import '../../peer/services/hub_flow.dart';
import 'flow_edit_ops.dart';
import 'flow_draft_store.dart';
import 'flow_editor_history.dart';
import 'flow_host_caps.dart';
import 'flow_editor_notice.dart';
import 'flow_names.dart';
import 'flow_rehearsal_runner.dart';

/// 挂起的一个字段改动。`nodeId` 为空表示这是定义头上的字段。
typedef FlowPendingKey = ({String nodeId, String field});

/// 流程草稿的编排器（方案 M2）。
///
/// 界面（工具条 / 大纲 / 检查器 / 诊断 / 源码）都读它，它不许碰
/// `BuildContext`，也不读 `AppLocalizations`：要告诉用户的事一律走
/// [onNotice]，由界面去配文案。
///
/// **唯一的不变量：状态只在拿到主机回包时才改，从不做乐观更新。**
class FlowEditorController extends ChangeNotifier {
  FlowEditorController({
    required this.peerId,
    required this.name,
    this.scope = '',
    HubFlow? client,
    this.draftStore,
    this.stepInterval = const Duration(milliseconds: 350),
  }) : _client = client ?? HubFlow() {
    _rehearsal = FlowRehearsalRunner(
      client: _client,
      peerId: peerId,
      stepInterval: stepInterval,
      onNotice: _emit,
    );
    _rehearsal.addListener(_onRehearsalChanged);
  }

  static const Duration _debounceDelay = Duration(milliseconds: 500);
  static const Duration _coalesceWindow = Duration(seconds: 2);

  final String peerId;
  final String name;
  final String scope;
  final Duration stepInterval;

  final HubFlow _client;
  HubFlow get client => _client;

  late final FlowRehearsalRunner _rehearsal;
  FlowRehearsalRunner get rehearsal => _rehearsal;

  final FlowEditorHistory _history = FlowEditorHistory();
  final FlowDraftStore? draftStore;

  FlowDraft? _restorableDraft;
  FlowDraft? get restorableDraft => _restorableDraft;

  /// 恢复那份草稿（界面问过用户之后）。
  Future<bool> restoreDraft() async {
    final draft = _restorableDraft;
    if (draft == null) return false;
    if (draft.yaml.isEmpty) {
      _restorableDraft = null;
      return false;
    }
    // 主机可能已经前进了好几版：先 flush 再比对版本，别把草稿盖到新版本上。
    if (!await flush()) return false;
    if (_disposed) return false;
    final checked = await _client.validate(peerId, draft.yaml);
    if (_disposed) return false;
    if (checked == null || !_adopt(checked)) {
      _emit(const FlowEditorNotice(FlowEditorNoticeKind.sourceInvalid));
      return false; // 草稿还在，界面可以再问一次
    }
    _restorableDraft = null;
    _generation++;
    _pending.clear();
    _rejected.clear();
    _rejectReason.clear();
    return true;
  }

  void discardDraft() {
    _restorableDraft = null;
    _notify();
  }

  /// 流程已经从主机删掉时调用：不让 dispose() 的 flush 或迟到的 edit 回包
  /// 再给这个已不存在的流程落一份草稿（草稿横幅会指向幽灵流程）。
  bool _abandoned = false;

  void abandon() {
    _abandoned = true;
    _restorableDraft = null;
    _pending.clear();
    _rejected.clear();
    _rejectReason.clear();
    _debounce?.cancel();
    _debounce = null;
    _notify();
  }

  final Map<FlowPendingKey, Object?> _pending = <FlowPendingKey, Object?>{};
  final Map<FlowPendingKey, Object?> _rejected = <FlowPendingKey, Object?>{};
  final Map<FlowPendingKey, String> _rejectReason = <FlowPendingKey, String>{};
  List<Map<String, dynamic>>? _queuedOps;

  bool _disposed = false;

  /// 每次 load / 源码 / 撤销 / 恢复草稿都 +1。迟到的回包发现版本变了就丢掉，
  /// 否则旧请求的结果会把新状态覆盖回去。
  int _generation = 0;

  /// 在途的那一次 `_commit`。`flush()` 会等它，而不是看到空缓冲就报「都发出去了」。
  Completer<bool>? _inFlightDone;

  /// 上一次采纳是「同一个字段的单字段批次」，用来决定能否合并 undo。
  FlowPendingKey? _lastCoalesceKey;
  int _lastAdoptMs = 0;

  /// 界面挂上它来出提示。
  void Function(FlowEditorNotice notice)? onNotice;

  FlowSchema? _schema;
  String _baseYaml = '';
  String _yaml = '';
  int _revision = 0;
  List<FlowNode> _tree = const [];
  List<FlowDiagnostic> _diagnostics = const [];
  FlowDiff? _diff;
  bool _showDiff = false;
  bool _loading = true;
  bool _loadFailed = false;
  bool _saving = false;
  bool _busy = false;
  bool _offline = false;
  int _nextId = 1;
  Timer? _debounce;

  /// 关页面之后回包仍可能到达：那时只能改数据，不能再 notify（ChangeNotifier
  /// 已 dispose）。
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ── 读 ────────────────────────────────────────────────────────────────────

  FlowSchema? get schema => _schema;
  FlowHostCaps get caps => FlowHostCaps.of(_schema, _tree);
  String get yaml => _yaml;
  String get baseYaml => _baseYaml;
  int get revision => _revision;
  List<FlowNode> get tree => _tree;
  List<FlowDiagnostic> get diagnostics => _diagnostics;

  bool get loading => _loading;
  bool get loadFailed => _loadFailed;
  bool get saving => _saving;
  bool get offline => _offline;
  bool get busy => _busy || _saving || _rehearsal.active;
  bool get hasPending => _pending.isNotEmpty;
  bool get hasRejected => _rejected.isNotEmpty;
  bool get dirty =>
      _yaml != _baseYaml || _pending.isNotEmpty || _rejected.isNotEmpty;
  int get errorCount => _diagnostics.where((d) => d.isError).length;
  bool get canUndo => !busy && _history.canUndo;
  bool get canRedo => !busy && _history.canRedo;
  FlowDiff? get diff => _showDiff ? _diff : null;
  bool get showDiff => _showDiff;

  // ── 载入 ──────────────────────────────────────────────────────────────────

  Future<void> load() => _load();
  Future<void> reload() => _load();

  Future<void> _load() async {
    final generation = ++_generation;
    _loading = true;
    _loadFailed = false;
    _notify();
    final got = await _client.get(peerId, name, scope: scope);
    final schema = await _client.schema(peerId);
    if (_disposed || generation != _generation) return;
    if (got == null || schema == null) {
      _loading = false;
      _loadFailed = true;
      _offline = true;
      _notify();
      return;
    }
    // `flow_get_resp` 不带树，得再校验一次才有节点树和诊断。
    final checked = await _client.validate(peerId, got.yaml);
    if (_disposed || generation != _generation) return;
    if (checked == null) {
      // 拿不到树就别装作加载成功：否则后续编辑会算在一份不存在的树上。
      _loading = false;
      _loadFailed = true;
      _offline = true;
      _emit(const FlowEditorNotice(FlowEditorNoticeKind.hostNoReply));
      _notify();
      return;
    }
    _loading = false;
    _offline = false;
    _schema = schema;
    _revision = got.revision;
    _baseYaml = checked.yaml.isNotEmpty ? checked.yaml : got.yaml;
    _yaml = _baseYaml;
    _tree = checked.tree;
    _diagnostics = checked.diagnostics;
    _pending.clear();
    _rejected.clear();
    _rejectReason.clear();
    _queuedOps = null;
    _diff = null;
    _history.clear();
    _resetCoalesce();
    await _lookForDraft();
    if (_disposed || generation != _generation) return;
    _notify();
  }

  Future<void> _lookForDraft() async {
    final store = draftStore;
    if (store == null) return;
    final draft = await store.load(
      peerId: peerId,
      scope: scope,
      name: name,
    );
    if (_disposed) return;
    if (draft == null) return;
    if (draft.yaml.isEmpty || draft.yaml == _baseYaml) {
      await _clearDraft();
      return;
    }
    _restorableDraft = draft;
  }

  // ── 改 ────────────────────────────────────────────────────────────────────

  void setField(
    String nodeId,
    String field,
    Object? value, {
    bool immediate = false,
  }) {
    final key = (nodeId: nodeId, field: field);
    _pending[key] = value;
    _rejected.remove(key);
    _rejectReason.remove(key);
    _notify();
    if (immediate) {
      unawaited(flush());
      return;
    }
    _rearmDebounce();
  }

  void setHeader(String field, Object? value) =>
      setField('', field, value, immediate: true);

  /// 一次改同一个节点上的多个字段，合成一批发出去。
  ///
  /// 换执行者会同时动 `role` / `agent` / `uses`，还可能清掉 model / mode。
  /// 拆成多次 `setField(immediate: true)` 会变成多次往返，撤销也碎成几条。
  Future<bool> setFields(String nodeId, Map<String, Object?> fields) {
    for (final entry in fields.entries) {
      final key = (nodeId: nodeId, field: entry.key);
      _pending[key] = entry.value;
      _rejected.remove(key);
      _rejectReason.remove(key);
    }
    _notify();
    _debounce?.cancel();
    _debounce = null;
    return flush();
  }

  /// 主机拒绝这个字段时的原因。没有被拒就返回 null。
  String? rejection(String nodeId, String field) =>
      _rejectReason[(nodeId: nodeId, field: field)];

  /// 一次改多个头部字段。头部表单用：五个字段要在一个原子批次里发，不能拆成
  /// 五次 `setHeader` 各自 `flush()`（会变成两个往返，切页面还会丢后四个）。
  Future<bool> setHeaders(Map<String, Object?> fields) {
    for (final entry in fields.entries) {
      final key = (nodeId: '', field: entry.key);
      _pending[key] = entry.value;
      _rejected.remove(key);
      _rejectReason.remove(key);
    }
    _notify();
    _debounce?.cancel();
    _debounce = null;
    return flush();
  }

  void _rearmDebounce() {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () => unawaited(flush()));
  }

  Future<bool> flush() => _commit(const []);
  Future<bool> applyOps(List<Map<String, dynamic>> ops) => _commit(ops);

  /// 把挂起的字段改动 + 结构操作合成一批发出去。
  Future<bool> _commit(List<Map<String, dynamic>> extra) async {
    // 有在途请求时不能因为「缓冲空」就报成功 —— save / rehearse / undo 等着这个
    // 结果决定要不要继续。等它结束再重新评估。
    final inFlight = _inFlightDone;
    if (inFlight != null) {
      // 在途时又来的结构操作要接在后面，不能让后一次把前一次盖掉。
      if (extra.isNotEmpty) {
        final queued = _queuedOps ?? <Map<String, dynamic>>[];
        queued.addAll(extra);
        _queuedOps = queued;
      }
      _rearmDebounce();
      final ok = await inFlight.future;
      if (!ok) return false;
      return _commit(const []);
    }

    final sent = <FlowPendingKey, Object?>{};
    final ops = <Map<String, dynamic>>[];
    for (final entry in _pending.entries) {
      if (_rejected.containsKey(entry.key)) continue;
      if (_isRequired(entry.key) && entry.value == null) continue;
      sent[entry.key] = entry.value;
      ops.add(entry.key.nodeId.isEmpty
          ? FlowEditOps.header(entry.key.field, entry.value)
          : FlowEditOps.set(entry.key.nodeId, entry.key.field, entry.value));
    }
    final queued = _queuedOps;
    _queuedOps = null;
    if (queued != null) ops.addAll(queued);
    ops.addAll(extra);

    // 被拒的字段是故意不发的；没有别的东西要发时就该成功返回，否则
    // save / undo / rehearsal 会被永久卡死。
    if (ops.isEmpty) return true;

    final done = Completer<bool>();
    _inFlightDone = done;
    _busy = true;
    _notify();
    bool result = false;
    try {
      result = await _doCommit(ops, sent, extra.isEmpty && queued == null);
    } catch (_) {
      result = false;
    } finally {
      _busy = false;
      _inFlightDone = null;
      _notify();
    }
    done.complete(result);
    return result;
  }

  Future<bool> _doCommit(
    List<Map<String, dynamic>> ops,
    Map<FlowPendingKey, Object?> sent,
    bool singleFieldBatch,
  ) async {
    final generation = _generation;
    final result = await _client.edit(peerId, _yaml, ops);
    // 迟到回包：load / 源码 / 撤销已经换了状态，丢掉它，别把旧结果盖回去。
    if (generation != _generation) return false;

    if (!result.reachable) {
      _offline = true;
      _emit(const FlowEditorNotice(FlowEditorNoticeKind.hostNoReply));
      return false;
    }
    final checked = result.result;
    if (checked == null) {
      // 整批被拒：状态没动。只把**本批实际发出去的**字段标成 rejected；之前被拒、
      // 这次没发的字段要留着，否则一次无关的成功提交会把它们清掉。
      _rejected.addEntries(sent.entries);
      final reason = result.error ?? '';
      for (final key in sent.keys) {
        if (reason.isNotEmpty) _rejectReason[key] = reason;
      }
      _emit(FlowEditorNotice(FlowEditorNoticeKind.editRejected,
          raw: result.error));
      return false;
    }
    _offline = false;
    final coalesceKey =
        singleFieldBatch && sent.length == 1 ? sent.keys.single : null;
    // `_adopt` 拒收（空 yaml 等）时不改状态，也不能清挂起缓冲。
    if (!_adopt(checked, coalesceKey: coalesceKey)) {
      _emit(const FlowEditorNotice(FlowEditorNoticeKind.sourceInvalid));
      return false;
    }
    for (final entry in sent.entries) {
      if (_pending[entry.key] == entry.value) _pending.remove(entry.key);
    }
    _rejected.removeWhere((key, _) => !_pending.containsKey(key));
    _rejectReason.removeWhere((key, _) => !_pending.containsKey(key));
    if (_showDiff) unawaited(_refreshDiff());
    // 关页面之后才到的回包也要落草稿，否则最后敲的字会丢。
    await _persistDraft();
    return true;
  }

  /// 主机解析会直接失败的三个必填路径（`loop.max` / `if.cond` / `map.over`），
  /// 再加 `task.prompt`：清空时绝不发 null。
  bool _isRequired(FlowPendingKey key) {
    if (key.nodeId.isEmpty) return false;
    return const {
      'loop.max',
      'if.cond',
      'map.over',
      'task.prompt',
    }.contains(key.field);
  }

  /// 采纳主机回来的三元组。这是唯一改状态的地方。
  bool _adopt(FlowValidation checked, {FlowPendingKey? coalesceKey}) {
    if (checked.yaml.trim().isEmpty) return false;
    if (!checked.ok && checked.tree.isEmpty && checked.diagnostics.isEmpty) {
      return false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final merge = coalesceKey != null &&
        _lastCoalesceKey == coalesceKey &&
        _lastAdoptMs > 0 &&
        now - _lastAdoptMs < _coalesceWindow.inMilliseconds;
    _lastAdoptMs = now;
    _lastCoalesceKey = coalesceKey;
    _history.record(
      FlowEditorSnapshot(
        yaml: _yaml,
        tree: _tree,
        diagnostics: _diagnostics,
      ),
      coalesce: merge,
    );
    _yaml = checked.yaml;
    _tree = checked.tree;
    _diagnostics = checked.diagnostics;
    _notify();
    return true;
  }

  void _resetCoalesce() {
    _lastCoalesceKey = null;
    _lastAdoptMs = 0;
  }

  Future<void> _persistDraft() async {
    if (_abandoned) return;
    final store = draftStore;
    if (store == null || !dirty) return;
    await store.save(
      peerId: peerId,
      scope: scope,
      name: name,
      yaml: _yaml,
      baseRevision: _revision,
    );
  }

  Future<void> _clearDraft() async {
    final store = draftStore;
    if (store == null) return;
    await store.clear(peerId: peerId, scope: scope, name: name);
  }

  Future<bool> applySource(String text, FlowValidation? prechecked) async {
    if (!await flush()) return false;
    if (_disposed) return false;
    final checked = prechecked ?? await _client.validate(peerId, text);
    if (_disposed) return false;
    if (checked == null) {
      _emit(const FlowEditorNotice(FlowEditorNoticeKind.hostNoReply));
      return false;
    }
    if (!_adopt(checked)) {
      _emit(const FlowEditorNotice(FlowEditorNoticeKind.sourceInvalid));
      return false;
    }
    _generation++;
    _restorableDraft = null;
    _resetCoalesce();
    _pending.clear();
    _rejected.clear();
    _rejectReason.clear();
    _queuedOps = null;
    if (_showDiff) unawaited(_refreshDiff());
    await _persistDraft();
    return true;
  }

  Future<bool> startRehearsal() async {
    if (!await flush()) return false;
    if (_disposed) return false;
    return _rehearsal.start(_yaml);
  }

  Future<bool> save({bool force = false}) async {
    if (errorCount > 0) {
      _emit(FlowEditorNotice(FlowEditorNoticeKind.hasProblems,
          count: errorCount));
      return false;
    }
    if (!await flush()) return false;
    if (_disposed) return false;
    // 还有被主机拒着的字段：存当前 yaml 会把用户在表单里看到的值丢掉。
    if (hasRejected) {
      _emit(const FlowEditorNotice(FlowEditorNoticeKind.editRejected,
          raw: '有字段被主机拒绝，改好再保存'));
      return false;
    }
    _saving = true;
    _notify();
    final savedYaml = _yaml;
    final result = await _client.save(
      peerId,
      name,
      savedYaml,
      scope: scope,
      baseRevision: force ? null : _revision,
    );
    _saving = false;
    if (_disposed) return false;
    if (!result.ok) {
      if (result.reachable) {
        final latest = result.data['latest'] is num
            ? (result.data['latest'] as num).toInt()
            : 0;
        // `latest` 只是「库里现在第几版」，主机给所有失败都带它，不能单独当
        // 冲突标志。只有我们确实报了 base_revision、且主机报的版本和手上的
        // 不一样，才算冲突（`>` 不够：别人删了重建会让 latest 反而变小）。
        // force 保存没报 base_revision，不可能冲突；否则「覆盖为新一版」会
        // 再弹一次同样的对话框，成死循环。旧主机不带这个字段，也不会误判。
        final conflict = !force && latest > 0 && latest != _revision;
        if (conflict) {
          _emit(FlowEditorNotice(FlowEditorNoticeKind.saveConflict,
              raw: result.error, count: latest));
        } else {
          _emit(FlowEditorNotice(FlowEditorNoticeKind.saveRejected,
              raw: result.error));
        }
      } else {
        _emit(const FlowEditorNotice(FlowEditorNoticeKind.hostNoReply));
      }
      _notify();
      return false;
    }
    final flow = result.data['flow'];
    final latest = flow is Map ? (flow['latest'] as num?)?.toInt() : null;
    _baseYaml = savedYaml;
    _revision = latest ?? _revision + 1;
    _diff = null;
    _showDiff = false;
    _resetCoalesce();
    _emit(FlowEditorNotice(FlowEditorNoticeKind.saved, count: _revision));
    _notify();
    await _clearDraft();
    return true;
  }

  /// 另存为：把当前草稿存成一个新名字（带 create_only），本编辑器仍留在原流程上。
  Future<bool> saveAs(String newName) async {
    if (!await flush()) return false;
    if (_disposed) return false;
    // 老主机不认 create_only，同名会静默覆盖已有的那份流程。先查一次库；
    // 只有「主机压根没应答」才不写，主机回了但名单不可用时照常交给主机裁决。
    final availability =
        await FlowNameGuard.check(_client, peerId, newName, scope: scope);
    if (_disposed) return false;
    if (availability == FlowNameAvailability.taken) {
      _emit(const FlowEditorNotice(FlowEditorNoticeKind.nameTaken));
      return false;
    }
    if (availability == FlowNameAvailability.unavailable) {
      _emit(const FlowEditorNotice(FlowEditorNoticeKind.hostNoReply));
      return false;
    }
    final result = await _client.save(
      peerId,
      newName,
      _yaml,
      scope: scope,
      createOnly: true,
    );
    if (_disposed) return false;
    if (!result.ok) {
      // 所有失败都由控制器发通知，界面别再叠一条通用「保存失败」把它盖掉。
      _emit(result.reachable
          ? FlowEditorNotice(FlowEditorNoticeKind.saveRejected,
              raw: result.error)
          : const FlowEditorNotice(FlowEditorNoticeKind.hostNoReply));
    }
    return result.ok;
  }

  Future<void> toggleDiff() async {
    _showDiff = !_showDiff;
    _notify();
    if (_showDiff) await _refreshDiff();
  }

  Future<void> _refreshDiff() async {
    final got = await _client.diff(peerId, fromYaml: _baseYaml, toYaml: _yaml);
    if (_disposed) return;
    _diff = got.diff;
    _notify();
  }

  Future<void> undo() async {
    if (busy) return;
    if (!await flush()) return;
    final previous = _history.undo(_snapshot());
    if (previous == null) return;
    await _restore(previous);
  }

  Future<void> redo() async {
    if (busy) return;
    if (!await flush()) return;
    final next = _history.redo(_snapshot());
    if (next == null) return;
    await _restore(next);
  }

  FlowEditorSnapshot _snapshot() => FlowEditorSnapshot(
        yaml: _yaml,
        tree: _tree,
        diagnostics: _diagnostics,
      );

  Future<void> _restore(FlowEditorSnapshot snapshot) async {
    _yaml = snapshot.yaml;
    _tree = snapshot.tree;
    _diagnostics = snapshot.diagnostics;
    _pending.clear();
    _rejected.clear();
    _rejectReason.clear();
    _queuedOps = null;
    _generation++;
    _resetCoalesce();
    _notify();
    if (_tree.isEmpty && _yaml.isNotEmpty) {
      final checked = await _client.validate(peerId, _yaml);
      if (_disposed || checked == null) return;
      _tree = checked.tree;
      _diagnostics = checked.diagnostics;
      _notify();
    }
    await _persistDraft();
  }

  String freshId(String prefix) {
    String id;
    do {
      id = '$prefix-${_nextId++}';
    } while (_tree.any((n) => n.find((x) => x.id == id) != null));
    return id;
  }

  void _emit(FlowEditorNotice notice) => onNotice?.call(notice);

  void _onRehearsalChanged() => _notify();

  @override
  void dispose() {
    // 关页面前把挂起的改动发一次。回包即使晚到也会走 `_doCommit` 落草稿（见
    // 那里对 `_disposed` 的处理），所以这里不再并发写一份旧 YAML 的草稿。
    unawaited(flush());
    _disposed = true;
    _debounce?.cancel();
    _debounce = null;
    _rehearsal.removeListener(_onRehearsalChanged);
    _rehearsal.dispose();
    super.dispose();
  }
}
