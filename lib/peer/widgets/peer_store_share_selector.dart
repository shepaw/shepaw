import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../peer/models/peer_store_share.dart';
import '../../storage/device_identity.dart';
import '../../storage/store_protocol.dart';
import '../../storage/store_service.dart';

/// 配对/设置用的储物袋分享选择状态（按 space）。
class PeerStoreShareSpaceState {
  final String space;
  /// true = 整区；false = 仅勾选的 top-level 目录。
  bool wholeSpace;
  bool enabled;
  final Set<String> selectedFolders;
  List<String> availableFolders;

  PeerStoreShareSpaceState({
    required this.space,
    this.wholeSpace = true,
    this.enabled = false,
    Set<String>? selectedFolders,
    List<String>? availableFolders,
  })  : selectedFolders = selectedFolders ?? <String>{},
        availableFolders = availableFolders ?? <String>[];

  List<PeerStoreShareEntry> toEntries() {
    if (!enabled) return const [];
    if (wholeSpace) {
      return [PeerStoreShareEntry(space: space)];
    }
    return [
      for (final f in selectedFolders)
        PeerStoreShareEntry(space: space, path: f),
    ];
  }
}

/// 从已有分享条目构建各 space 的初始状态。
Map<String, PeerStoreShareSpaceState> storeShareStatesFromEntries(
  Iterable<PeerStoreShareEntry> entries, {
  Iterable<String> candidateSpaces = StoreSpace.sharedReadable,
}) {
  final bySpace = <String, List<PeerStoreShareEntry>>{};
  for (final e in entries) {
    if (!e.shared) continue;
    bySpace.putIfAbsent(e.space, () => []).add(e);
  }
  final map = <String, PeerStoreShareSpaceState>{};
  for (final space in candidateSpaces) {
    final list = bySpace[space] ?? const <PeerStoreShareEntry>[];
    if (list.isEmpty) {
      map[space] = PeerStoreShareSpaceState(space: space, enabled: false);
      continue;
    }
    final whole = list.any((e) => e.isWholeSpace);
    map[space] = PeerStoreShareSpaceState(
      space: space,
      enabled: true,
      wholeSpace: whole,
      selectedFolders: {
        for (final e in list)
          if (!e.isWholeSpace) e.path.split('/').first,
      },
    );
  }
  return map;
}

/// 按信任级别给出默认分享状态。
Map<String, PeerStoreShareSpaceState> defaultStoreShareStates(String trustLevel) {
  final owner = trustLevel == TrustLevel.owner;
  return {
    for (final space in StoreSpace.sharedReadable)
      space: PeerStoreShareSpaceState(
        space: space,
        enabled: owner,
        wholeSpace: true,
      ),
  };
}

/// 内嵌储物袋分享选择器：分区 + 整区/顶层目录。
class PeerStoreShareSelector extends StatefulWidget {
  final Map<String, PeerStoreShareSpaceState> initialStates;
  final ValueChanged<List<PeerStoreShareEntry>> onChanged;

  const PeerStoreShareSelector({
    super.key,
    required this.initialStates,
    required this.onChanged,
  });

  @override
  State<PeerStoreShareSelector> createState() => _PeerStoreShareSelectorState();
}

class _PeerStoreShareSelectorState extends State<PeerStoreShareSelector> {
  late Map<String, PeerStoreShareSpaceState> _states;
  bool _loadingFolders = true;

  @override
  void initState() {
    super.initState();
    _states = {
      for (final e in widget.initialStates.entries)
        e.key: PeerStoreShareSpaceState(
          space: e.value.space,
          wholeSpace: e.value.wholeSpace,
          enabled: e.value.enabled,
          selectedFolders: Set<String>.from(e.value.selectedFolders),
          availableFolders: List<String>.from(e.value.availableFolders),
        ),
    };
    _loadFolders();
  }

  @override
  void didUpdateWidget(covariant PeerStoreShareSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部重置（如切换 trust）时同步初始状态
    if (oldWidget.initialStates != widget.initialStates) {
      _states = {
        for (final e in widget.initialStates.entries)
          e.key: PeerStoreShareSpaceState(
            space: e.value.space,
            wholeSpace: e.value.wholeSpace,
            enabled: e.value.enabled,
            selectedFolders: Set<String>.from(e.value.selectedFolders),
            availableFolders: List<String>.from(e.value.availableFolders),
          ),
      };
      _loadFolders();
      _notify();
    }
  }

  Future<void> _loadFolders() async {
    try {
      final store = await StoreService.instance.localStore();
      final self = await DeviceIdentity.deviceId();
      for (final space in _states.keys.toList()) {
        final entries = await store.list(self, space, depth: 1, limit: 500);
        final folders = <String>{};
        for (final e in entries) {
          if (e.isDir) {
            folders.add(e.path.split('/').first);
          } else if (e.path.contains('/')) {
            folders.add(e.path.split('/').first);
          }
        }
        _states[space]!.availableFolders = folders.toList()..sort();
      }
    } catch (_) {
      // 目录加载失败时仍可勾选整区
    }
    if (mounted) {
      setState(() => _loadingFolders = false);
    }
  }

  void _notify() {
    final out = <PeerStoreShareEntry>[];
    for (final s in _states.values) {
      out.addAll(s.toEntries());
    }
    widget.onChanged(out);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final space in _states.keys) ...[
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _states[space]!.enabled,
            onChanged: (v) {
              setState(() {
                _states[space]!.enabled = v ?? false;
                if (_states[space]!.enabled &&
                    !_states[space]!.wholeSpace &&
                    _states[space]!.selectedFolders.isEmpty &&
                    _states[space]!.availableFolders.isNotEmpty) {
                  _states[space]!.wholeSpace = true;
                }
              });
              _notify();
            },
            title: Text(space),
            subtitle: Text(
              _states[space]!.enabled
                  ? (_states[space]!.wholeSpace
                      ? l10n.peerStoreShare_wholeSpace
                      : l10n.peerStoreShare_foldersCount(
                          _states[space]!.selectedFolders.length))
                  : l10n.peerStoreShare_notShared,
              style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
            ),
          ),
          if (_states[space]!.enabled) ...[
            Padding(
              padding: const EdgeInsets.only(left: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.peerStoreShare_wholeSpaceToggle),
                    value: _states[space]!.wholeSpace,
                    onChanged: (v) {
                      setState(() => _states[space]!.wholeSpace = v);
                      _notify();
                    },
                  ),
                  if (!_states[space]!.wholeSpace) ...[
                    if (_loadingFolders)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else if (_states[space]!.availableFolders.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          l10n.peerStoreShare_noFolders,
                          style: TextStyle(
                            color: colorScheme.onSurfaceVariant,
                            fontSize: 12,
                          ),
                        ),
                      )
                    else
                      ..._states[space]!.availableFolders.map((folder) {
                        final selected =
                            _states[space]!.selectedFolders.contains(folder);
                        return CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          secondary: const Icon(Icons.folder_outlined, size: 20),
                          title: Text(folder),
                          value: selected,
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _states[space]!.selectedFolders.add(folder);
                              } else {
                                _states[space]!.selectedFolders.remove(folder);
                              }
                            });
                            _notify();
                          },
                        );
                      }),
                  ],
                ],
              ),
            ),
          ],
        ],
      ],
    );
  }
}
