import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../peer/services/peer_agent_client_service.dart';

/// 菜单行顺序，和 Cursor 客户端一致：Fast、Context、Effort，最后是模型。
const cursorModelOptionOrder = ['fast', 'context', 'reasoning_effort'];

const _modelMenuId = '__model__';
const _menuGap = 4.0;

/// 锚定在模型 chip 上的 Cursor 风格参数面板。点外面关闭。
class CursorModelPanelHandle {
  OverlayEntry? _entry;

  void refresh() => _entry?.markNeedsBuild();

  void close() {
    _entry?.remove();
    _entry = null;
  }
}

CursorModelPanelHandle showCursorModelPanel({
  required BuildContext context,
  required GlobalKey anchorKey,
  required WidgetBuilder panel,
}) {
  final overlay = Overlay.of(context);
  final handle = CursorModelPanelHandle();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) {
      final box = anchorKey.currentContext?.findRenderObject() as RenderBox?;
      final overlayBox = overlay.context.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize || overlayBox == null) {
        return const SizedBox.shrink();
      }
      final origin = box.localToGlobal(Offset.zero, ancestor: overlayBox);
      final anchor = box.size;
      final screen = overlayBox.size;
      const width = 248.0;
      var left = origin.dx + anchor.width - width;
      if (left < 8) left = 8;
      if (left + width > screen.width - 8) left = screen.width - 8 - width;
      final placeAbove = origin.dy > 220;
      return Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: handle.close,
            ),
          ),
          Positioned(
            left: left,
            width: width,
            top: placeAbove ? null : origin.dy + anchor.height + 6,
            bottom: placeAbove ? screen.height - origin.dy + 6 : null,
            child: Material(
              elevation: 8,
              shadowColor: Colors.black26,
              color: Theme.of(overlayContext).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              child: panel(overlayContext),
            ),
          ),
        ],
      );
    },
  );
  handle._entry = entry;
  overlay.insert(entry);
  return handle;
}

/// Fast 用胶囊开关；Context、Effort、模型各自再展开一层。
///
/// 二级菜单跟一级菜单贴在一起，同一时间只开一个：再点另一行会换掉上一个。
class CursorModelSettings extends StatefulWidget {
  final List<PeerAgentModel> models;
  final String? currentModel;
  final Map<String, String> optionValues;
  final bool enabled;
  final String modelLabel;
  final ValueChanged<bool>? onFastChanged;
  final void Function(String optionId, String value)? onOptionChanged;
  final ValueChanged<String>? onModelChanged;

  const CursorModelSettings({
    super.key,
    required this.models,
    required this.currentModel,
    required this.optionValues,
    required this.modelLabel,
    this.enabled = true,
    this.onFastChanged,
    this.onOptionChanged,
    this.onModelChanged,
  });

  @override
  State<CursorModelSettings> createState() => _CursorModelSettingsState();
}

class _CursorModelSettingsState extends State<CursorModelSettings> {
  final _portal = OverlayPortalController();
  final _links = <String, LayerLink>{};
  String? _openId;
  bool _openToRight = true;
  double _dy = 0;
  double _menuWidth = 220;

  PeerModelsList get _list => PeerModelsList(
        models: widget.models,
        current: widget.currentModel,
        optionValues: widget.optionValues,
      );

  PeerAgentModel? get _model {
    for (final model in widget.models) {
      if (model.value == widget.currentModel) return model;
    }
    return null;
  }

  LayerLink _link(String id) => _links.putIfAbsent(id, LayerLink.new);

  void _closeMenu() {
    if (_openId == null) return;
    setState(() => _openId = null);
    _portal.hide();
  }

  void _toggle(String id, BuildContext rowContext) {
    if (!widget.enabled) return;
    if (_openId == id) {
      _closeMenu();
      return;
    }
    final box = rowContext.findRenderObject() as RenderBox?;
    final screen = MediaQuery.sizeOf(rowContext);
    final padding = MediaQuery.paddingOf(rowContext);
    var toRight = true;
    var dy = 0.0;
    if (box != null && box.hasSize && box.attached) {
      final origin = box.localToGlobal(Offset.zero);
      final choices = _choicesFor(id).length;
      final menuHeight = math.min(choices * 44.0 + 8, math.min(360.0, screen.height - 16));
      final spaceRight = screen.width - (origin.dx + box.size.width) - 8;
      final spaceLeft = origin.dx - 8;
      toRight = spaceRight >= spaceLeft;
      final space = math.max(0.0, toRight ? spaceRight : spaceLeft);
      _menuWidth = space.clamp(120.0, 240.0);
      final minTop = padding.top + 8;
      final maxBottom = screen.height - padding.bottom - 8;
      final spaceBelow = maxBottom - origin.dy;
      if (menuHeight > spaceBelow) {
        dy = spaceBelow - menuHeight;
        if (origin.dy + dy < minTop) dy = minTop - origin.dy;
      }
    }
    setState(() {
      _openId = id;
      _openToRight = toRight;
      _dy = dy;
    });
    _portal.show();
  }

  List<(String, String)> _choicesFor(String id) {
    if (id == _modelMenuId) {
      return [for (final item in widget.models) (item.value, item.displayName)];
    }
    final option = _model?.optionById(id);
    if (option == null) return const [];
    return [
      for (final value in option.values) (value, option.labelFor(value)),
    ];
  }

  String? _selectedFor(String id) {
    if (id == _modelMenuId) return widget.currentModel;
    return _list.effectiveOption(id);
  }

  void _pick(String id, String value) {
    _closeMenu();
    if (id == _modelMenuId) {
      widget.onModelChanged?.call(value);
    } else {
      widget.onOptionChanged?.call(id, value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    final options = <PeerModelOption>[
      for (final id in cursorModelOptionOrder)
        if (model?.optionById(id) case final option?) option,
    ];
    final parameters = options.where((option) => !option.isSwitch).toList();
    final fast = model?.optionById('fast');
    final colorScheme = Theme.of(context).colorScheme;
    final openId = _openId;
    return OverlayPortal(
      controller: _portal,
      overlayChildBuilder: (context) {
        if (openId == null) return const SizedBox.shrink();
        return CompositedTransformFollower(
          link: _link(openId),
          showWhenUnlinked: false,
          targetAnchor: _openToRight ? Alignment.topRight : Alignment.topLeft,
          followerAnchor: _openToRight ? Alignment.topLeft : Alignment.topRight,
          offset: Offset(_openToRight ? _menuGap : -_menuGap, _dy),
          child: UnconstrainedBox(
            alignment: _openToRight ? Alignment.topLeft : Alignment.topRight,
            child: _SideMenu(
              width: _menuWidth,
              choices: _choicesFor(openId),
              selected: _selectedFor(openId),
              onSelected: (value) => _pick(openId, value),
            ),
          ),
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (fast != null)
            _FastRow(
              title: fast.displayName,
              value: _list.effectiveOption('fast') == 'true',
              enabled: widget.enabled && widget.onFastChanged != null,
              onChanged: widget.onFastChanged,
            ),
          for (final option in parameters)
            _SubmenuRow(
              title: option.displayName,
              valueLabel: _list.effectiveOptionLabel(option.id) ?? '',
              enabled: widget.enabled && widget.onOptionChanged != null,
              opened: openId == option.id,
              link: _link(option.id),
              onTap: (rowContext) => _toggle(option.id, rowContext),
            ),
          if (fast != null || parameters.isNotEmpty)
            Divider(height: 1, thickness: 1, color: colorScheme.outlineVariant),
          _SubmenuRow(
            title: widget.modelLabel,
            valueLabel: model?.displayName ?? '',
            enabled: widget.enabled && widget.onModelChanged != null,
            opened: openId == _modelMenuId,
            link: _link(_modelMenuId),
            onTap: (rowContext) => _toggle(_modelMenuId, rowContext),
          ),
        ],
      ),
    );
  }
}

class _SideMenu extends StatelessWidget {
  final double width;
  final List<(String, String)> choices;
  final String? selected;
  final ValueChanged<String> onSelected;

  const _SideMenu({
    required this.width,
    required this.choices,
    required this.selected,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final screen = MediaQuery.sizeOf(context);
    final maxHeight = math.min(360.0, screen.height - 16);
    return Material(
      elevation: 8,
      shadowColor: Colors.black26,
      color: colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints.tightFor(width: width).copyWith(maxHeight: maxHeight),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          children: [
            for (final choice in choices)
              InkWell(
                onTap: () => onSelected(choice.$1),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          choice.$2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15),
                        ),
                      ),
                      if (choice.$1 == selected) ...[
                        const SizedBox(width: 12),
                        Icon(Icons.check, size: 16, color: colorScheme.primary),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FastRow extends StatelessWidget {
  final String title;
  final bool value;
  final bool enabled;
  final ValueChanged<bool>? onChanged;

  const _FastRow({
    required this.title,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w500,
                color: enabled
                    ? colorScheme.onSurface
                    : colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
          ),
          Switch(
            value: value,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }
}

class _SubmenuRow extends StatelessWidget {
  final String title;
  final String valueLabel;
  final bool enabled;
  final bool opened;
  final LayerLink link;
  final void Function(BuildContext rowContext) onTap;

  const _SubmenuRow({
    required this.title,
    required this.valueLabel,
    required this.enabled,
    required this.opened,
    required this.link,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fg = enabled
        ? colorScheme.onSurface
        : colorScheme.onSurface.withValues(alpha: 0.4);
    final valueColor = enabled
        ? colorScheme.onSurfaceVariant
        : colorScheme.onSurfaceVariant.withValues(alpha: 0.4);
    return CompositedTransformTarget(
      link: link,
      child: Material(
        color: opened ? colorScheme.surfaceContainerHighest : Colors.transparent,
        child: InkWell(
          onTap: enabled ? () => onTap(context) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: fg,
                  ),
                ),
                const Spacer(),
                Flexible(
                  child: Text(
                    valueLabel,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(fontSize: 15, color: valueColor),
                  ),
                ),
                Icon(Icons.chevron_right, size: 18, color: valueColor),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
