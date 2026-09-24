import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/jade_slip.dart';
import '../services/jade_slip_service.dart';
import '../theme/app_theme.dart';
import '../utils/layout_utils.dart';
import 'jade_slip_editor_screen.dart';

/// 搜索词是否命中玉简标题、正文或清单。与 [JadeSlipService.list] 的过滤一致。
bool jadeSlipMatchesQuery(JadeSlip slip, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  if (slip.title.toLowerCase().contains(q)) return true;
  if (slip.body.toLowerCase().contains(q)) return true;
  return slip.items.any((item) => item.text.toLowerCase().contains(q));
}

/// 当前打开的玉简已不符合筛选时，仍插回列表原位置。
///
/// 勾选清单会推导状态（已完成 ↔ 进行中）。立刻按筛选丢掉它，桌面分栏右侧
/// 正在编辑的页面会一起消失。留到用户主动切换筛选再严格过滤。
List<JadeSlip> insertRetainedJadeSlip({
  required List<JadeSlip> items,
  required JadeSlip retained,
  required int anchorIndex,
}) {
  if (retained.status == JadeSlipStatus.archived) return items;
  if (items.any((slip) => slip.id == retained.id)) return items;
  final next = List<JadeSlip>.of(items);
  var index = anchorIndex;
  if (index < 0) index = 0;
  if (index > next.length) index = next.length;
  next.insert(index, retained);
  return next;
}

/// 储物袋「玉简」：待办笔记本。桌面嵌在右侧面板，移动端独立页。
class JadeSlipScreen extends StatefulWidget {
  final bool embedded;

  const JadeSlipScreen({super.key, this.embedded = false});

  @override
  State<JadeSlipScreen> createState() => _JadeSlipScreenState();
}

enum _JadeSlipFilter { open, doing, done, all }

class _JadeSlipScreenState extends State<JadeSlipScreen> {
  final _service = JadeSlipService.instance;
  final _search = TextEditingController();
  final _searchFocus = FocusNode();

  List<JadeSlip>? _items;
  _JadeSlipFilter _filter = _JadeSlipFilter.all;
  String? _selectedId;
  String? _focusChecklistId;
  String? _focusTitleId;
  bool _searchOpen = false;
  bool _filterOpen = true;
  bool _creating = false;
  bool _lastWide = false;
  StreamSubscription<void>? _sub;
  int _loadSerial = 0;

  /// 打开中的玉简在当前筛选列表里的位置，状态变了也留在原处。
  int _anchorIndex = 0;
  double _listPaneWidth = 280;

  static const double _minListPaneWidth = 220;
  static const double _maxListPaneWidth = 480;
  static const double _minDetailPaneWidth = 360;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _sub = _service.changes.listen((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _load({bool strict = false}) async {
    final serial = ++_loadSerial;
    final includeArchived = _filter == _JadeSlipFilter.all;
    JadeSlipStatus? status;
    switch (_filter) {
      case _JadeSlipFilter.open:
        status = JadeSlipStatus.open;
      case _JadeSlipFilter.doing:
        status = JadeSlipStatus.inProgress;
      case _JadeSlipFilter.done:
        status = JadeSlipStatus.done;
      case _JadeSlipFilter.all:
        status = null;
    }
    final selectedId = _selectedId;
    var items = await _service.list(
      status: status,
      query: _search.text,
      includeArchived: includeArchived,
    );
    if (!mounted || serial != _loadSerial) return;
    var nextSelected = selectedId;
    if (selectedId != null && items.every((s) => s.id != selectedId)) {
      JadeSlip? kept;
      if (!strict) {
        kept = await _service.getById(selectedId);
        if (!mounted || serial != _loadSerial) return;
      }
      if (kept != null &&
          kept.status != JadeSlipStatus.archived &&
          jadeSlipMatchesQuery(kept, _search.text)) {
        items = insertRetainedJadeSlip(
          items: items,
          retained: kept,
          anchorIndex: _anchorIndex,
        );
      } else {
        nextSelected = null;
      }
    }
    if (nextSelected != null) {
      final index = items.indexWhere((s) => s.id == nextSelected);
      if (index >= 0) _anchorIndex = index;
    }
    setState(() {
      _items = items;
      _selectedId = nextSelected;
    });
  }

  AppLocalizations get _l10n => AppLocalizations.of(context);

  bool _wideFor(BoxConstraints constraints) =>
      LayoutUtils.isDesktopLayout(context) && constraints.maxWidth >= 720;

  Future<void> _openEditor(JadeSlip slip) async {
    final items = _items;
    if (items != null) {
      final index = items.indexWhere((s) => s.id == slip.id);
      if (index >= 0) _anchorIndex = index;
    }
    setState(() {
      _selectedId = slip.id;
      if (_focusChecklistId != slip.id) _focusChecklistId = null;
      if (_focusTitleId != slip.id) _focusTitleId = null;
    });
    if (_lastWide) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => JadeSlipEditorScreen(
          slipId: slip.id,
          onOpenSlip: _openRelated,
        ),
      ),
    );
    if (mounted) unawaited(_load());
  }

  void _openRelated(String slipId) {
    final items = _items;
    JadeSlip? slip;
    if (items != null) {
      for (final item in items) {
        if (item.id == slipId) slip = item;
      }
    }
    if (slip != null) {
      unawaited(_openEditor(slip));
      return;
    }
    unawaited(() async {
      final loaded = await _service.getById(slipId);
      if (!mounted || loaded == null) return;
      await _openEditor(loaded);
    }());
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) _search.clear();
    });
    if (_searchOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _searchOpen) _searchFocus.requestFocus();
      });
    } else {
      unawaited(_load());
    }
  }

  /// 新建：桌面在右侧打开并改标题，手机直接进入编辑页。
  Future<void> _onCreatePressed() async {
    if (_creating) return;
    _creating = true;
    try {
      final slip = await _service.create(title: _l10n.jadeSlip_untitled);
      if (!mounted) return;
      final query = _search.text.trim();
      final wide = _lastWide;
      setState(() {
        _selectedId = slip.id;
        _focusTitleId = slip.id;
        _focusChecklistId = null;
        if (query.isNotEmpty && !jadeSlipMatchesQuery(slip, query)) {
          _search.clear();
          _searchOpen = false;
        }
      });
      await _load();
      if (!mounted || wide) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => JadeSlipEditorScreen(
            slipId: slip.id,
            focusTitle: true,
          ),
        ),
      );
      if (!mounted) return;
      setState(() {
        if (_focusTitleId == slip.id) _focusTitleId = null;
      });
      unawaited(_load());
    } finally {
      _creating = false;
    }
  }

  List<Widget> _titleActions(AppLocalizations l10n) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    Color tint(bool on) => on ? AppColors.primary : muted;
    final filterOn = _filterOpen || _filter != _JadeSlipFilter.all;
    return [
      IconButton(
        tooltip: l10n.common_search,
        visualDensity: VisualDensity.compact,
        icon: Icon(
          Icons.search,
          color: tint(_searchOpen || _search.text.isNotEmpty),
        ),
        onPressed: _toggleSearch,
      ),
      IconButton(
        tooltip: l10n.jadeSlip_filter,
        visualDensity: VisualDensity.compact,
        icon: Icon(Icons.filter_list, color: tint(filterOn)),
        onPressed: () => setState(() => _filterOpen = !_filterOpen),
      ),
      IconButton(
        tooltip: l10n.jadeSlip_create,
        visualDensity: VisualDensity.compact,
        icon: Icon(
          Icons.add,
          color: tint(_focusTitleId != null),
        ),
        onPressed: () => unawaited(_onCreatePressed()),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = _l10n;
    final items = _items;
    JadeSlip? selected;
    if (items != null) {
      for (final s in items) {
        if (s.id == _selectedId) {
          selected = s;
          break;
        }
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = _wideFor(constraints);
        _lastWide = wide;
        final hideOuterAppBar = widget.embedded && wide;
        return Scaffold(
          appBar: hideOuterAppBar
              ? null
              : AppBar(
                  title: Text(l10n.jadeSlip_title),
                  elevation: widget.embedded ? 0 : null,
                  automaticallyImplyLeading: !widget.embedded,
                  actions: _titleActions(l10n),
                ),
          body: items == null
              ? const Center(child: CircularProgressIndicator())
              : wide
                  ? Row(
                      children: [
                        SizedBox(
                          width: _listPaneWidth,
                          child: _buildListPane(
                            l10n,
                            items,
                            showHeader: hideOuterAppBar,
                          ),
                        ),
                        _buildPaneSplitter(constraints.maxWidth),
                        Expanded(
                          child: selected == null
                              ? _buildEmptyEditorHint(l10n)
                              : JadeSlipEditorScreen(
                                  key: ValueKey(selected.id),
                                  slipId: selected.id,
                                  embedded: true,
                                  focusChecklist:
                                      selected.id == _focusChecklistId,
                                  focusTitle: selected.id == _focusTitleId,
                                  onChanged: () => unawaited(_load()),
                                  onOpenSlip: _openRelated,
                                ),
                        ),
                      ],
                    )
                  : _buildListPane(l10n, items, showHeader: false),
        );
      },
    );
  }

  void _resizeListPane(double delta, double maxWidth) {
    final room = maxWidth - _minDetailPaneWidth;
    final maxList = room < _minListPaneWidth
        ? _minListPaneWidth
        : (room > _maxListPaneWidth ? _maxListPaneWidth : room);
    final next = _listPaneWidth + delta;
    setState(() {
      _listPaneWidth = next < _minListPaneWidth
          ? _minListPaneWidth
          : (next > maxList ? maxList : next);
    });
  }

  Widget _buildPaneSplitter(double maxWidth) {
    final line = Theme.of(context).colorScheme.outline;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragUpdate: (details) =>
          _resizeListPane(details.delta.dx, maxWidth),
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeColumn,
        child: SizedBox(
          width: 12,
          child: Center(
            child: Container(width: 1, color: line),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyEditorHint(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_stories_outlined, size: 40, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            l10n.jadeSlip_pickHint,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildListPane(
    AppLocalizations l10n,
    List<JadeSlip> items, {
    required bool showHeader,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader)
          SizedBox(
            height: kToolbarHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.jadeSlip_title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  ..._titleActions(l10n),
                ],
              ),
            ),
          ),
        if (_searchOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              decoration: _quietField(
                context,
                hint: l10n.common_search,
                prefix: Icon(
                  Icons.search,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              onChanged: (_) => unawaited(_load()),
            ),
          ),
        if (_filterOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final f in _JadeSlipFilter.values)
                  _FilterTag(
                    label: _filterLabel(l10n, f),
                    selected: _filter == f,
                    onTap: () {
                      setState(() => _filter = f);
                      unawaited(_load(strict: true));
                    },
                  ),
              ],
            ),
          ),
        Expanded(
          child: items.isEmpty
              ? _buildEmpty(l10n)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
                  itemCount: items.length,
                  itemBuilder: (context, i) => _SlipRow(
                    slip: items[i],
                    selected: items[i].id == _selectedId,
                    onTap: () => unawaited(_openEditor(items[i])),
                  ),
                ),
        ),
      ],
    );
  }

  String _filterLabel(AppLocalizations l10n, _JadeSlipFilter f) => switch (f) {
        _JadeSlipFilter.open => l10n.jadeSlip_filterOpen,
        _JadeSlipFilter.doing => l10n.jadeSlip_filterDoing,
        _JadeSlipFilter.done => l10n.jadeSlip_filterDone,
        _JadeSlipFilter.all => l10n.jadeSlip_filterAll,
      };

  Widget _buildEmpty(AppLocalizations l10n) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_stories_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              l10n.jadeSlip_empty,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

InputDecoration _quietField(
  BuildContext context, {
  required String hint,
  Widget? prefix,
  Widget? suffix,
}) {
  final scheme = Theme.of(context).colorScheme;
  final radius = BorderRadius.circular(10);
  return InputDecoration(
    hintText: hint,
    prefixIcon: prefix,
    suffixIcon: suffix,
    isDense: true,
    filled: true,
    fillColor: scheme.surfaceContainerHighest,
    hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border:
        OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
    enabledBorder:
        OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
    focusedBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: scheme.primary.withValues(alpha: 0.45)),
    ),
  );
}

class _FilterTag extends StatelessWidget {
  const _FilterTag({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: selected
          ? AppColors.primary.withValues(alpha: 0.14)
          : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? AppColors.primary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _SlipRow extends StatelessWidget {
  const _SlipRow({
    required this.slip,
    required this.selected,
    required this.onTap,
  });

  final JadeSlip slip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final done = slip.status == JadeSlipStatus.done;
    final untitled = slip.title == l10n.jadeSlip_untitled;
    final meta = <String>[];
    if (slip.assigneeAgentName.isNotEmpty) meta.add(slip.assigneeAgentName);
    if (slip.dueAtMs != null) meta.add(_fmtDay(slip.dueAtMs!));
    if (slip.itemCount > 0) {
      meta.add(l10n.jadeSlip_progress(slip.doneCount, slip.itemCount));
    }
    if (slip.attachments.isNotEmpty) {
      meta.add(l10n.jadeSlip_attachmentCount(slip.attachments.length));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: selected
            ? AppColors.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 44,
                margin: const EdgeInsets.only(left: 4),
                decoration: BoxDecoration(
                  color: selected ? AppColors.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 4, 10),
                child: Icon(
                  done ? Icons.check_circle : Icons.auto_stories_outlined,
                  size: 20,
                  color: done ? AppColors.primary : scheme.onSurfaceVariant,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        slip.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: untitled
                              ? scheme.onSurfaceVariant
                              : scheme.onSurface,
                          decoration: done ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          meta.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ] else if (slip.goal.trim().isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          slip.goal.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ] else if (slip.body.trim().isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          slip.body.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _fmtDay(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
