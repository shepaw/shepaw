import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../peer/models/flow_models.dart';
import '../../peer/services/hub_flow.dart';
import 'flow_edit_ops.dart';
import 'flow_editor_history.dart';
import 'flow_host_caps.dart';
import 'flow_editor_notice.dart';
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
///
/// 由此省掉了回滚代码：主机的 `flow_edit_req` 是整批原子的，整批被拒时定义没
/// 动过，我们这边也就什么都不用撤 —— 只要把挂起的字段改动留着，下次再发。
class FlowEditorController extends ChangeNotifier {
  FlowEditorController({
    required this.peerId,
    required this.name,
    this.scope = '',
    HubFlow? client,
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

  final String peerId;
  final String name;
  final String scope;

  /// 演练每一步的间隔。
  final Duration stepInterval;

  final HubFlow _client;
  HubFlow get client => _client;

  late final FlowRehearsalRunner _rehearsal;
  FlowRehearsalRunner get rehearsal => _rehearsal;

  final FlowEditorHistory _history = FlowEditorHistory();
  final Map<FlowPendingKey, Object?> _pending = <FlowPendingKey, Object?>{};

  /// 被主机拒过、用户还没改的那批值。
  ///
  /// 值还留在界面上（界面拿它标红），但不再自动拼进后续批次 —— 否则一个坏
  /// 字段会让之后所有编辑都被拒。用户改了值（[setField]）或撤销后才重发。
  final Map<FlowPendingKey, Object?> _rejected = <FlowPendingKey, Object?>{};

  /// 在途期间来的结构操作。只留最后一批：连点三下「加一步」没必要发三次。
  List<Map<String, dynamic>>? _queuedOps;

  /// 页面已经销毁。所有 `await` 之后都要看它，否则会碰已 dispose 的
  /// `ChangeNotifier`。
  bool _disposed = false;

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
  int _stateRev = 0;
  int _nextId = 1;
  Timer? _debounce;

  // ── 读 ────────────────────────────────────────────────────────────────────

  FlowSchema? get schema => _schema;

  /// 这台主机能干什么。新 App 连到旧主机时用它降级，别假设操作一定支持。
  FlowHostCaps get caps => FlowHostCaps.of(_schema, _tree);

  String get yaml => _yaml;
  String get baseYaml => _baseYaml;
  int get revision => _revision;
  List<FlowNode> get tree => _tree;
  List<FlowDiagnostic> get diagnostics => _diagnostics;

  /// 检查器靠它判断要不要重播种：主机回了新状态才 +1，打字不动它。
  int get stateRev => _stateRev;

  bool get loading => _loading;
  bool get loadFailed => _loadFailed;
  bool get saving => _saving;
  bool get offline => _offline;

  /// 有在途的事：编辑、保存、演练。界面上的手势在这个期间置灰。
  bool get busy => _busy || _saving || _rehearsal.active;

  bool get hasPending => _pending.isNotEmpty;

  /// 有改了但被主机拒着、还没发出去的字段。
  bool get hasRejected => _rejected.isNotEmpty;

  /// 有没保存的东西：草稿和库里的不一致，或者有改了还没发出去的字段。
  bool get dirty =>
      _yaml != _baseYaml || _pending.isNotEmpty || _rejected.isNotEmpty;

  int get errorCount => _diagnostics.where((d) => d.isError).length;

  /// 在途请求期间不给撤销：会和回包交错。
  bool get canUndo => !busy && _history.canUndo;
  bool get canRedo => !busy && _history.canRedo;

  FlowDiff? get diff => _showDiff ? _diff : null;
  bool get showDiff => _showDiff;

  // ── 载入 ──────────────────────────────────────────────────────────────────

  Future<void> load() => _load();

  /// 重新拉一份（群主改完之后）。撤销栈也一起重置：本地草稿被覆盖了。
  Future<void> reload() => _load();

  Future<void> _load() async {
    _loading = true;
    _loadFailed = false;
    notifyListeners();
    final got = await _client.get(peerId, name, scope: scope);
    final schema = await _client.schema(peerId);
    if (_disposed) return;
    if (got == null || schema == null) {
      _loading = false;
      _loadFailed = true;
      _offline = true;
      notifyListeners();
      return;
    }
    // `flow_get_resp` 不带树，得再校验一次才有节点树和诊断。
    final checked = await _client.validate(peerId, got.yaml);
    if (_disposed) return;
    _loading = false;
    _offline = false;
    _schema = schema;
    _revision = got.revision;
    _baseYaml = checked?.yaml.isNotEmpty == true ? checked!.yaml : got.yaml;
    _yaml = _baseYaml;
    _tree = checked?.tree ?? const [];
    _diagnostics = checked?.diagnostics ?? const [];
    _pending.clear();
    _diff = null;
    _history.clear();
    _stateRev++;
    notifyListeners();
  }

  // ── 改 ────────────────────────────────────────────────────────────────────

  /// 改节点上的一个字段。
  ///
  /// [immediate] 为 false（默认）时先落在本地缓冲里，500ms 后再发 —— 提示词
  /// 这种字段一个字一个往返会把人卡住。非标量（列表、映射）和结构操作走
  /// [applyOps]，本身是离散手势，不用防抖。
  void setField(
    String nodeId,
    String field,
    Object? value, {
    bool immediate = false,
  }) {
    final key = (nodeId: nodeId, field: field);
    _pending[key] = value;
    // 用户又动了这个字段，之前被拒的那次就作废，重新参与发送。
    _rejected.remove(key);
    notifyListeners();
    if (immediate) {
      unawaited(flush());
      return;
    }
    _rearmDebounce();
  }

  /// 改定义头里的字段（`inputs` / `limits` / `description`…）。
  void setHeader(String field, Object? value) =>
      setField('', field, value, immediate: true);

  void _rearmDebounce() {
    _debounce?.cancel();
    _debounce = Timer(_debounceDelay, () => unawaited(flush()));
  }

  /// 把挂起的字段改动发出去。切选中、保存、演练、撤销、关页面前都要调一次。
  ///
  /// 返回这次调用有没有把改动都发出去：返回 false 时 [save] / [rehearse] /
  /// [undo] 应当中止，否则会拿旧内容去保存还提示「已保存」。
  Future<bool> flush() => _commit(const []);

  /// 结构操作（增 / 删 / 挪 / 包 / 拆 / 改类型）。挂起的字段改动先发。
  Future<bool> applyOps(List<Map<String, dynamic>> ops) => _commit(ops);

  Future<bool> _commit(List<Map<String, dynamic>> extra) async {
    final ops = <Map<String, dynamic>>[
      ..._pendingOps(),
      ...extra,
    ];
    if (ops.isEmpty) return !hasRejected;
    if (_busy) {
      // 在途期间不丢东西：结构操作进单槽队列（只留最后一个），挂起的字段会
      // 自然合并进下一次；防抖定时器重新排一次，别让它刚好落在在途窗口里。
      if (extra.isNotEmpty) _queuedOps = extra;
      _rearmDebounce();
      return false;
    }
    _busy = true;
    notifyListeners();
    // 快照这批值：回包后只清掉「值没再变过」的 key。在途期间用户打的字不能
    // 被清掉 —— 以前是 await 之后整表 clear，会把那几下敲掉。
    final sent = Map<FlowPendingKey, Object?>.from(_pending);
    final result = await _client.edit(peerId, _yaml, ops);
    _busy = false;
    if (_disposed) return false;
    if (!result.reachable) {
      // 定义没变，挂起的改动留着，等下次再发。
      _offline = true;
      _emit(const FlowEditorNotice(FlowEditorNoticeKind.hostNoReply));
      notifyListeners();
      return false;
    }
    final checked = result.result;
    if (checked == null) {
      // 整批被拒：主机没动定义，我们也不动。这一批标为 rejected —— 值还留在
      // 输入框里，但不再自动拼进后续批次，否则一个坏字段会让之后所有结构
      // 操作都被拒。用户改值或撤销后才重发。
      _rejected.addEntries(sent.entries);
      _emit(FlowEditorNotice(FlowEditorNoticeKind.editRejected,
          raw: result.error));
      notifyListeners();
      return false;
    }
    _offline = false;
    _adopt(checked);
    for (final entry in sent.entries) {
      if (_pending[entry.key] == entry.value) _pending.remove(entry.key);
    }
    _rejected.removeWhere((key, _) => !_pending.containsKey(key));
    if (_showDiff) unawaited(_refreshDiff());
    // 续发排队的那批结构操作。
    final queued = _queuedOps;
    _queuedOps = null;
    if (queued != null) return _commit(queued);
    return true;
  }

  List<Map<String, dynamic>> _pendingOps() {
    final ops = <Map<String, dynamic>>[];
    for (final entry in _pending.entries) {
      final key = entry.key;
      // 被主机拒过、用户还没改的字段不再自动重发。
      if (_rejected.containsKey(key)) continue;
      if (key.nodeId.isEmpty) {
        ops.add(FlowEditOps.header(key.field, entry.value));
      } else {
        ops.add(FlowEditOps.set(key.nodeId, key.field, entry.value));
      }
    }
    return ops;
  }

  /// 采纳主机回来的三元组。这是唯一改状态的地方。
  ///
  /// 空 YAML 一律拒收：主机在 YAML 语法错时会回 `yaml:''` 加空诊断，照单采纳
  /// 会把草稿换成空串。
  bool _adopt(FlowValidation checked) {
    if (checked.yaml.trim().isEmpty) return false;
    if (!checked.ok && checked.tree.isEmpty && checked.diagnostics.isEmpty) {
      return false;
    }
    _history.record(FlowEditorSnapshot(
      yaml: _yaml,
      tree: _tree,
      diagnostics: _diagnostics,
    ));
    _yaml = checked.yaml;
    _tree = checked.tree;
    _diagnostics = checked.diagnostics;
    _stateRev++;
    notifyListeners();
    return true;
  }

  /// 用户在源码面板里改完，点「用这份」。
  ///
  /// 走同一条 [_adopt]，所以树和诊断一定一起刷新 —— 以前这里只换 YAML，界面
  /// 上的树和诊断还是改之前的，是个真 bug。
  Future<bool> applySource(String text, FlowValidation? prechecked) async {
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
    _pending.clear();
    _rejected.clear();
    if (_showDiff) unawaited(_refreshDiff());
    return true;
  }

  /// 开一次演练。挂起的改动先落定，否则演练跑的是旧内容。
  Future<bool> startRehearsal() async {
    if (!await flush()) return false;
    if (_disposed) return false;
    await _rehearsal.start(_yaml);
    return true;
  }

  Future<void> save() async {
    if (errorCount > 0) {
      _emit(FlowEditorNotice(FlowEditorNoticeKind.hasProblems,
          count: errorCount));
      return;
    }
    // 没发出去的改动不能算数：否则存的是旧内容，还提示「已保存」。
    if (!await flush()) return;
    if (_disposed) return;
    _saving = true;
    notifyListeners();
    final result = await _client.save(peerId, name, _yaml, scope: scope);
    _saving = false;
    if (_disposed) return;
    if (!result.ok) {
      _emit(result.reachable
          ? FlowEditorNotice(FlowEditorNoticeKind.saveRejected,
              raw: result.error)
          : const FlowEditorNotice(FlowEditorNoticeKind.hostNoReply));
      notifyListeners();
      return;
    }
    final flow = result.data['flow'];
    final latest = flow is Map ? (flow['latest'] as num?)?.toInt() : null;
    _baseYaml = _yaml;
    _revision = latest ?? _revision + 1;
    _diff = null;
    _showDiff = false;
    _emit(FlowEditorNotice(FlowEditorNoticeKind.saved, count: _revision));
    notifyListeners();
  }

  Future<void> toggleDiff() async {
    _showDiff = !_showDiff;
    notifyListeners();
    if (_showDiff) await _refreshDiff();
  }

  Future<void> _refreshDiff() async {
    final got = await _client.diff(peerId, fromYaml: _baseYaml, toYaml: _yaml);
    if (_disposed) return;
    _diff = got.diff;
    notifyListeners();
  }

  Future<void> undo() async {
    if (_busy) return;
    // 先把挂起的改动落定，否则撤销会和回包交错。
    if (!await flush()) return;
    final previous = _history.undo(_snapshot());
    if (previous == null) return;
    await _restore(previous);
  }

  Future<void> redo() async {
    if (_busy) return;
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
    // 撤销回到之前的状态：之前被拒的字段已经不在草稿里了，约束也跟着解除。
    _rejected.clear();
    _stateRev++;
    notifyListeners();
    // 快照里没有树（不该发生）：补一次校验，别让界面停在空树上。
    if (_tree.isEmpty && _yaml.isNotEmpty) {
      final checked = await _client.validate(peerId, _yaml);
      if (_disposed || checked == null) return;
      _tree = checked.tree;
      _diagnostics = checked.diagnostics;
      notifyListeners();
    }
  }

  /// 生成一个新的、树里没有的节点 id。
  String freshId(String prefix) {
    String id;
    do {
      id = '$prefix-${_nextId++}';
    } while (_tree.any((n) => n.find((x) => x.id == id) != null));
    return id;
  }

  void _emit(FlowEditorNotice notice) => onNotice?.call(notice);

  void _onRehearsalChanged() => notifyListeners();

  @override
  void dispose() {
    _disposed = true;
    _debounce?.cancel();
    _debounce = null;
    _rehearsal.removeListener(_onRehearsalChanged);
    _rehearsal.dispose();
    super.dispose();
  }
}
