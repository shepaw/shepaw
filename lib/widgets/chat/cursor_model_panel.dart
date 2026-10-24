import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../peer/services/peer_agent_client_service.dart';

/// 菜单行顺序，和 Cursor 客户端一致：Fast、Context、Effort，最后是模型。
const cursorModelOptionOrder = ['fast', 'context', 'reasoning_effort'];

const _modelMenuId = '__model__';
const _menuGap = 4.0;

/// 一级参数面板的宽度上下限（宽屏、以及手机上还没展开二级时沿用）。
const _panelMinWidth = 176.0;
const _panelMaxWidth = 216.0;

/// 二级菜单的宽度上下限。模型名的长度决定它的宽度需求，太窄会被截成
/// 省略号——一级面板里能显示全的名字，二级里也应该能。
const _sideMenuMinWidth = 160.0;
const _sideMenuMaxWidth = 240.0;

/// 小于这个宽度视为手机：展开二级时两级改成贴边铺满，不再浮在芯片旁边。
const _fillScreenBreakpoint = 480.0;

const _screenEdge = 8.0;

/// 一级参数面板在未展开二级时的宽度。
///
/// 手机屏上收到半屏以内；宽屏固定宽度。展开二级之后改走
/// [cursorModelFilledLayout]，这里的宽度只决定收起时的样子。
double cursorModelPanelWidth(double screenWidth) {
  if (screenWidth >= _fillScreenBreakpoint) return _panelMaxWidth;
  return (screenWidth * 0.46).clamp(_panelMinWidth, _panelMaxWidth);
}

/// 手机上两级同时展开时的横向排布：一级贴左，二级贴右，中间留 [_menuGap]。
class CursorModelFilledLayout {
  final double panelLeft;
  final double panelWidth;
  final double sideWidth;

  const CursorModelFilledLayout({
    required this.panelLeft,
    required this.panelWidth,
    required this.sideWidth,
  });

  double sideLeft(double screenWidth, double rightInset) {
    final right = math.max(_screenEdge, rightInset);
    return screenWidth - right - sideWidth;
  }
}

/// 窄屏展开二级时，按屏幕宽度把两级铺满内容区。
///
/// 宽屏返回 null，面板继续锚在模型芯片上。一级约占内容区的 44%，
/// 至少留出开关和当前值的位置，其余宽度给模型名。
CursorModelFilledLayout? cursorModelFilledLayout({
  required double screenWidth,
  double leftInset = 0,
  double rightInset = 0,
}) {
  if (screenWidth >= _fillScreenBreakpoint) return null;
  final left = math.max(_screenEdge, leftInset);
  final right = math.max(_screenEdge, rightInset);
  final available = screenWidth - left - right - _menuGap;
  if (available <= 0) return null;
  final minPanel = math.min(150.0, available * 0.46);
  final panelWidth =
      (available * 0.44).clamp(minPanel, available * 0.5);
  return CursorModelFilledLayout(
    panelLeft: left,
    panelWidth: panelWidth,
    sideWidth: available - panelWidth,
  );
}

/// 锚定在模型 chip 上的 Cursor 风格参数面板。点外面关闭。
///
/// 面板插在根 Overlay 上。桌面聊天区在右栏 Navigator 里，外层还有
/// ClipRect，最近一层 Overlay 出不了右栏，二级菜单伸到左侧对话列表上
/// 会被裁掉。会话列表抽屉在根 Navigator 上，也会压住右栏里弹出的菜单。
/// 根 Overlay 盖住这两块面板，后弹出的菜单才在最上面。
class CursorModelPanelHandle {
  OverlayEntry? _entry;
  final submenuOpen = ValueNotifier<bool>(false);
  bool _closed = false;

  void refresh() => _entry?.markNeedsBuild();

  void close() {
    if (_closed) return;
    _closed = true;
    _entry?.remove();
    _entry = null;
    submenuOpen.dispose();
  }
}

typedef CursorModelPanelBuilder = Widget Function(
  BuildContext context,
  ValueNotifier<bool> submenuOpen,
);

CursorModelPanelHandle showCursorModelPanel({
  required BuildContext context,
  required GlobalKey anchorKey,
  required CursorModelPanelBuilder panel,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final handle = CursorModelPanelHandle();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) {
      return ValueListenableBuilder<bool>(
        valueListenable: handle.submenuOpen,
        builder: (context, submenuOpen, _) {
          final box =
              anchorKey.currentContext?.findRenderObject() as RenderBox?;
          final overlayBox =
              overlay.context.findRenderObject() as RenderBox?;
          if (box == null ||
              !box.attached ||
              !box.hasSize ||
              overlayBox == null) {
            return const SizedBox.shrink();
          }
          final origin =
              box.localToGlobal(Offset.zero, ancestor: overlayBox);
          final anchor = box.size;
          final screen = overlayBox.size;
          final padding = MediaQuery.paddingOf(overlayContext);
          final filled = submenuOpen
              ? cursorModelFilledLayout(
                  screenWidth: screen.width,
                  leftInset: padding.left,
                  rightInset: padding.right,
                )
              : null;
          final width = filled?.panelWidth ?? cursorModelPanelWidth(screen.width);
          var left = filled?.panelLeft ?? (origin.dx + anchor.width - width);
          if (filled == null) {
            if (left < _screenEdge) left = _screenEdge;
            if (left + width > screen.width - _screenEdge) {
              left = screen.width - _screenEdge - width;
            }
          }
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
                  child: panel(overlayContext, handle.submenuOpen),
                ),
              ),
            ],
          );
        },
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

  /// 由 [showCursorModelPanel] 传入。展开二级时置 true，面板据此改到贴边铺满。
  final ValueNotifier<bool>? submenuOpen;

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
    this.submenuOpen,
  });

  @override
  State<CursorModelSettings> createState() => _CursorModelSettingsState();
}

class _CursorModelSettingsState extends State<CursorModelSettings> {
  final _portal = OverlayPortalController();
  final _links = <String, LayerLink>{};
  bool _portalShown = false;
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

  void _setSubmenuOpen(bool open) {
    final notifier = widget.submenuOpen;
    if (notifier == null || notifier.value == open) return;
    notifier.value = open;
  }

  void _closeMenu() {
    if (_openId == null) return;
    setState(() => _openId = null);
    _portalShown = false;
    _setSubmenuOpen(false);
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
    final filled = cursorModelFilledLayout(
      screenWidth: screen.width,
      leftInset: padding.left,
      rightInset: padding.right,
    );
    var toRight = true;
    var dy = 0.0;
    if (filled != null) {
      // 一级会被挪到左边，二级固定向右展开并吃掉剩余宽度。
      toRight = true;
      _menuWidth = filled.sideWidth;
    }
    if (box != null && box.hasSize && box.attached) {
      final origin = box.localToGlobal(Offset.zero);
      final choices = _choicesFor(id).length;
      final menuHeight = math.min(choices * 44.0 + 8, math.min(360.0, screen.height - 16));
      if (filled == null) {
        final spaceRight = screen.width - (origin.dx + box.size.width) - 8;
        final spaceLeft = origin.dx - 8;
        // 宽屏菜单挂在整窗上，左边的空档包含对话列表。按哪边更宽来选
        // 方向，会把二级菜单翻到一级菜单左边。右边放得下最小宽度就向右，
        // 贴着屏幕右缘放不下时才向左。
        toRight = spaceRight >= _sideMenuMinWidth || spaceRight >= spaceLeft;
        final space = math.max(0.0, toRight ? spaceRight : spaceLeft);
        // 空间够就至少给到 [_sideMenuMinWidth]（模型名比参数值长得多）；
        // 不够才退回剩余空间，免得菜单被顶出屏幕。
        final want =
            math.max(_sideMenuMinWidth, math.min(space, _sideMenuMaxWidth));
        _menuWidth = math.min(want, space);
      }
      final minTop = padding.top + 8;
      final maxBottom = screen.height - padding.bottom - 8;
      final spaceBelow = maxBottom - origin.dy;
      if (menuHeight > spaceBelow) {
        dy = spaceBelow - menuHeight;
        if (origin.dy + dy < minTop) dy = minTop - origin.dy;
      }
    }
    final alreadyShowing = _portalShown;
    setState(() {
      _openId = id;
      _openToRight = toRight;
      _dy = dy;
    });
    _setSubmenuOpen(true);
    if (filled != null && !alreadyShowing) {
      // 一级要先挪到左边并改宽度，下一帧再把二级贴到它右边。
      // 同一帧展开的话，跟随层还会按挪动前的行位置摆，菜单会偏出屏幕。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _openId != id) return;
        _portalShown = true;
        _portal.show();
      });
      return;
    }
    _portalShown = true;
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
    // 二级菜单画在本面板这条 OverlayEntry 后面。面板插在根 Overlay 最上层，
    // 菜单才会跟着盖住对话列表和会话列表。
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
