import 'package:flutter/material.dart';

import '../../peer/services/hub_group_sessions.dart';
import '../../screens/pouch_scope_browser_screen.dart';
import '../../storage/pouch_scope.dart';

/// 群会话列表（主机权威）：列出、切换、新建、改名、归档。
///
/// 切换只影响这一端之后的群回合（[PouchTurnRelay] 会带上 session_id）；
/// 主机自己的 current_session 只有新建第一条会话时才会动。
Future<void> showHubGroupSessionsSheet(
  BuildContext context, {
  required String groupId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => HubGroupSessionsSheet(groupId: groupId),
  );
}

class HubGroupSessionsSheet extends StatefulWidget {
  const HubGroupSessionsSheet({super.key, required this.groupId});

  final String groupId;

  @override
  State<HubGroupSessionsSheet> createState() => _HubGroupSessionsSheetState();
}

class _HubGroupSessionsSheetState extends State<HubGroupSessionsSheet> {
  final HubGroupSessions _sessions = HubGroupSessions();
  GroupSessionListResult? _listed;
  String _host = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final host = await _sessions.activeHost();
    if (!mounted) return;
    if (host.isEmpty) {
      setState(() {
        _loading = false;
        _error = '没有连上主机';
      });
      return;
    }
    final listed = await _sessions.list(host, widget.groupId);
    if (!mounted) return;
    setState(() {
      _host = host;
      _listed = listed;
      _loading = false;
      _error = listed == null ? '主机没有回应' : null;
    });
  }

  String get _selected {
    final remembered = GroupSessionSelection.of(widget.groupId) ?? '';
    if (remembered.isNotEmpty) return remembered;
    return _listed?.currentSession ?? '';
  }

  Future<void> _create() async {
    final title = await _askTitle('新建会话');
    if (title == null) return;
    final created = await _sessions.create(_host, widget.groupId, title: title);
    if (!mounted) return;
    if (created == null) {
      _toast('新建失败');
      return;
    }
    GroupSessionSelection.select(widget.groupId, created.id);
    await _load();
  }

  Future<void> _rename(GroupSessionInfo session) async {
    final title = await _askTitle('重命名', initial: session.title);
    if (title == null || title.isEmpty) return;
    final ok = await _sessions.rename(
      _host,
      widget.groupId,
      session.id,
      title,
    );
    if (!mounted) return;
    if (!ok) {
      _toast('改名失败');
      return;
    }
    await _load();
  }

  Future<void> _archive(GroupSessionInfo session) async {
    final ok = await _sessions.archive(_host, widget.groupId, session.id);
    if (!mounted) return;
    if (!ok) {
      _toast('归档失败');
      return;
    }
    if (_selected == session.id) {
      GroupSessionSelection.select(widget.groupId, '');
    }
    await _load();
  }

  Future<String?> _askTitle(String title, {String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '会话名'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            ListTile(
              title: const Text('群会话'),
              subtitle: const Text('切换只影响这一端之后的群回合'),
              trailing: IconButton(
                tooltip: '新建会话',
                onPressed: _loading || _host.isEmpty ? null : _create,
                icon: const Icon(Icons.add),
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final sessions = _listed?.sessions ?? const <GroupSessionInfo>[];
    if (sessions.isEmpty) {
      return const Center(child: Text('还没有会话'));
    }
    final selected = _selected;
    return ListView.builder(
      itemCount: sessions.length,
      itemBuilder: (context, index) {
        final session = sessions[index];
        final active = session.id == selected;
        return ListTile(
          leading: Icon(
            active ? Icons.radio_button_checked : Icons.radio_button_off,
          ),
          title: Text(session.title.isEmpty ? session.id : session.title),
          subtitle: Text(
            session.isArchived
                ? '已归档（只读）'
                : '${session.id} · ${_day(session.createdAt)}',
          ),
          onTap: session.isArchived
              ? null
              : () {
                  GroupSessionSelection.select(widget.groupId, session.id);
                  Navigator.of(context).pop();
                },
          trailing: PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'rename') _rename(session);
              if (value == 'archive') _archive(session);
              if (value == 'files') _openSessionFiles(session);
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'rename', child: Text('改名')),
              const PopupMenuItem(value: 'archive', child: Text('归档')),
              if (!session.isArchived)
                const PopupMenuItem(value: 'files', child: Text('会话文件')),
            ],
          ),
        );
      },
    );
  }

  /// 这条会话的附件/文件落在 group:<gid>:session:<sid> 下（G4）。
  void _openSessionFiles(GroupSessionInfo session) {
    final scope = PouchScope.groupSession(widget.groupId, session.id);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PouchScopeBrowserScreen(initialScope: scope),
      ),
    );
  }

  static String _day(int ms) {
    if (ms <= 0) return '';
    final time = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)}';
  }
}
