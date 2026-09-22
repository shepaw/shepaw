import 'dart:io';

import '../../cli_base.dart';
import '../../../models/jade_slip.dart';
import '../../../models/store_attachment_ref.dart';
import '../../../services/jade_slip_service.dart';
import '../../../services/local_database_service.dart';
import '../../../services/local_user_identity.dart';
import '../../../services/she_service.dart';
import '../chat/chat_agent_scope.dart';

/// [TOOLING 层] notes 命名空间 — 储物袋「玉简」待办。
///
/// 用户把待办写在玉简里，Agent 用本命名空间领取、勾选、完成：
/// - `list`     列出待办（`--status open|in_progress|done`）
/// - `get`      读取一条完整玉简（含清单 item id）
/// - `add`      新建玉简（用户口述时也可代记）
/// - `update`   改标题/正文/状态/优先级/负责人
/// - `item`     勾选/反勾/追加/删除清单项
/// - `attach`   添加附件（`--file` 本地路径或 `--uri` store://）
/// - `detach`   删除附件
/// - `complete` 整条完成
/// - `delete`   删除（仅用户 / She）
class NotesNamespace extends CliNamespace {
  static final instance = NotesNamespace._();
  NotesNamespace._();

  @override
  String get namespace => 'notes';

  @override
  String get description =>
      'Jade slips (玉简): the user\'s to-do notebook in Nexus Pouch. '
      'List/get open tasks, check items off as you finish them, and mark '
      'the slip complete. Prefer this over ad-hoc chat when the user asks '
      'you to work through their to-dos.';

  @override
  String get icon => '📜';

  @override
  Map<String, CliCommand> get commands => {
        'list': NotesListCommand(),
        'get': NotesGetCommand(),
        'add': NotesAddCommand(),
        'update': NotesUpdateCommand(),
        'item': NotesItemCommand(),
        'comment': NotesCommentCommand(),
        'attach': NotesAttachCommand(),
        'detach': NotesDetachCommand(),
        'complete': NotesCompleteCommand(),
        'delete': NotesDeleteCommand(),
      };
}

Map<String, dynamic> _slipJson(JadeSlip slip, {bool full = false}) {
  return {
    'id': slip.id,
    'title': slip.title,
    'status': slip.status.wire,
    'priority': slip.priority.wire,
    'done': '${slip.doneCount}/${slip.itemCount}',
    if (slip.assigneeAgentId.isNotEmpty)
      'assignee_agent_id': slip.assigneeAgentId,
    if (slip.assigneeAgentName.isNotEmpty)
      'assignee_agent_name': slip.assigneeAgentName,
    if (slip.dueAtMs != null) 'due_at': slip.dueAtMs,
    'updated_at': slip.updatedAt,
    if (full) ...{
      'body': slip.body,
      'items': [
        for (final item in slip.items)
          {'id': item.id, 'text': item.text, 'done': item.done},
      ],
      if (slip.comments.isNotEmpty)
        'comments': [
          for (final c in slip.comments)
            {
              'id': c.id,
              'author_id': c.authorId,
              'author': c.displayName,
              'text': c.text,
              'created_at': c.createdAt,
            },
        ],
      if (slip.attachments.isNotEmpty)
        'attachments': [
          for (final a in slip.attachments)
            {
              'id': a.id,
              'name': a.name,
              'uri': a.uriFor(slip.deviceId),
              'size': a.sizeBytes,
            },
        ],
      'device_id': slip.deviceId,
      'created_at': slip.createdAt,
    } else if (slip.items.isNotEmpty)
      'open_items': [
        for (final item in slip.items)
          if (!item.done) {'id': item.id, 'text': item.text},
      ],
  };
}

class NotesListCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description =>
      'List jade slips. Default: open + in_progress. '
      'Use --status all to include completed.';

  @override
  String get usage =>
      'shepaw notes list [--status open|in_progress|done|all] [--query <text>]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final raw = (flags['status'] ?? '').trim();
    JadeSlipStatus? status;
    var includeArchived = false;
    if (raw == 'all') {
      includeArchived = true;
    } else if (raw.isNotEmpty) {
      status = JadeSlipStatus.parse(raw);
    }
    final list = await JadeSlipService.instance.list(
      status: status,
      query: flags['query'],
      includeArchived: includeArchived,
    );
    final shown = status != null || includeArchived
        ? list
        : list.where((s) => s.isOpen).toList();
    return {
      'count': shown.length,
      'slips': [for (final s in shown) _slipJson(s)],
      'hint': shown.isEmpty
          ? 'No matching jade slips.'
          : 'Use shepaw notes get --id <id> then notes item / notes complete.',
    };
  }
}

class NotesGetCommand extends CliCommand {
  @override
  String get name => 'get';

  @override
  String get description =>
      'Get one jade slip including checklist item ids for notes item';

  @override
  String get usage => 'shepaw notes get --id <id>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id']?.trim() ?? '';
    if (id.isEmpty) return {'error': 'Missing --id. Usage: $usage'};
    final slip = await JadeSlipService.instance.getById(id);
    if (slip == null) return {'error': 'Jade slip not found: $id'};
    return {'success': true, 'slip': _slipJson(slip, full: true)};
  }
}

class NotesAddCommand extends CliCommand {
  @override
  String get name => 'add';

  @override
  String get description =>
      'Create a jade slip. --items is semicolon-separated checklist text. '
      'Markdown "- [ ] item" in --body is also parsed into checklist items.';

  @override
  String get usage =>
      'shepaw notes add --title "Book flights" '
      '[--body "..."] [--items "compare prices;buy tickets"] '
      '[--priority low|medium|high]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final title = flags['title']?.trim() ?? '';
    if (title.isEmpty) return {'error': 'Missing --title. Usage: $usage'};
    final items = <JadeSlipItem>[];
    final rawItems = flags['items']?.trim() ?? '';
    if (rawItems.isNotEmpty) {
      for (final part in rawItems.split(RegExp(r'[;；\n]'))) {
        final text = part.trim();
        if (text.isEmpty) continue;
        items.add(JadeSlipItem(id: JadeSlipItem.newId(), text: text));
      }
    }
    try {
      final slip = await JadeSlipService.instance.create(
        title: title,
        body: flags['body'] ?? '',
        items: items,
        priority: JadeSlipPriority.parse(flags['priority']),
        dueAtMs: _parseDue(flags['due']),
      );
      return {
        'success': true,
        'action': 'created',
        'slip': _slipJson(slip, full: true),
      };
    } catch (e) {
      return {'error': '$e'};
    }
  }
}

class NotesUpdateCommand extends CliCommand {
  @override
  String get name => 'update';

  @override
  String get description =>
      'Update title/body/status/priority/assignee/due of a jade slip';

  @override
  String get usage =>
      'shepaw notes update --id <id> [--title t] [--body b] '
      '[--status open|in_progress|done|archived] [--priority high] '
      '[--assignee <agent_id>] [--due <iso-or-ms>]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id']?.trim() ?? '';
    if (id.isEmpty) return {'error': 'Missing --id. Usage: $usage'};
    final existing = await JadeSlipService.instance.getById(id);
    if (existing == null) return {'error': 'Jade slip not found: $id'};

    var next = existing;
    if (flags.containsKey('title')) {
      next = next.copyWith(title: flags['title']!.trim());
    }
    if (flags.containsKey('body')) {
      next = next.copyWith(body: flags['body'] ?? '');
    }
    if (flags.containsKey('status')) {
      next = next.copyWith(status: JadeSlipStatus.parse(flags['status']));
    }
    if (flags.containsKey('priority')) {
      next = next.copyWith(priority: JadeSlipPriority.parse(flags['priority']));
    }
    if (flags.containsKey('assignee')) {
      next = next.copyWith(assigneeAgentId: flags['assignee']!.trim());
    }
    if (flags.containsKey('due')) {
      final due = flags['due']?.trim() ?? '';
      next = due.isEmpty
          ? next.copyWith(clearDue: true)
          : next.copyWith(dueAtMs: _parseDue(due));
    }
    try {
      final slip = await JadeSlipService.instance.update(next);
      return {'success': true, 'slip': _slipJson(slip, full: true)};
    } catch (e) {
      return {'error': '$e'};
    }
  }
}

class NotesItemCommand extends CliCommand {
  @override
  String get name => 'item';

  @override
  String get description =>
      'Check off (--item + --done true), uncheck, append (--text), '
      'retitle (--item + --text), or remove (--item + --delete) a '
      'checklist row. Call this as soon as you finish a step.';

  @override
  String get usage =>
      'shepaw notes item --id <slipId> --item <itemId> --done true\n'
      'shepaw notes item --id <slipId> --text "new checklist row"\n'
      'shepaw notes item --id <slipId> --item <itemId> --text "new text"\n'
      'shepaw notes item --id <slipId> --item <itemId> --delete';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id']?.trim() ?? '';
    if (id.isEmpty) return {'error': 'Missing --id. Usage: $usage'};
    final text = flags['text']?.trim() ?? '';
    final itemId = flags['item']?.trim() ?? '';
    final deleteRaw = (flags['delete'] ?? '').trim().toLowerCase();
    final delete = deleteRaw == 'true' ||
        deleteRaw == '1' ||
        deleteRaw == 'yes' ||
        flags.containsKey('delete') && deleteRaw.isEmpty;
    try {
      if (itemId.isNotEmpty && text.isNotEmpty) {
        final slip = await JadeSlipService.instance.updateItemText(
          id: id,
          itemId: itemId,
          text: text,
        );
        return {
          'success': true,
          'action': 'renamed',
          'slip': _slipJson(slip, full: true),
        };
      }
      if (text.isNotEmpty) {
        final slip = await JadeSlipService.instance.addItem(id: id, text: text);
        return {'success': true, 'action': 'added', 'slip': _slipJson(slip, full: true)};
      }
      if (itemId.isEmpty) {
        return {'error': 'Missing --item or --text. Usage: $usage'};
      }
      if (delete) {
        final slip = await JadeSlipService.instance.removeItem(
          id: id,
          itemId: itemId,
        );
        return {
          'success': true,
          'action': 'removed',
          'slip': _slipJson(slip, full: true),
        };
      }
      final doneRaw = (flags['done'] ?? 'true').trim().toLowerCase();
      final done = doneRaw != 'false' && doneRaw != '0';
      final slip = await JadeSlipService.instance.setItemDone(
        id: id,
        itemId: itemId,
        done: done,
      );
      return {
        'success': true,
        'action': done ? 'checked' : 'unchecked',
        'slip': _slipJson(slip, full: true),
      };
    } catch (e) {
      return {'error': '$e'};
    }
  }
}

/// 玉简留言：Agent 把处理过程记回玉简，用户在 App 里能直接看到。
class NotesCommentCommand extends CliCommand {
  @override
  String get name => 'comment';

  @override
  String get description =>
      'Add a comment (--text) to a jade slip, list them (no --text), '
      'or remove one (--comment <id> --delete). The author is the running '
      'agent, so the user can follow your progress on the slip itself.';

  @override
  String get usage =>
      'shepaw notes comment --id <slipId> --text "已改完，待验证"\n'
      'shepaw notes comment --id <slipId>\n'
      'shepaw notes comment --id <slipId> --comment <commentId> --delete';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id']?.trim() ?? '';
    if (id.isEmpty) return {'error': 'Missing --id. Usage: $usage'};
    final slip = await JadeSlipService.instance.getById(id);
    if (slip == null) return {'error': 'Jade slip not found: $id'};

    final commentId = (flags['comment'] ?? '').trim();
    final deleteRaw = (flags['delete'] ?? '').trim().toLowerCase();
    final delete = deleteRaw == 'true' ||
        deleteRaw == '1' ||
        deleteRaw == 'yes' ||
        flags.containsKey('delete') && deleteRaw.isEmpty;
    try {
      if (commentId.isNotEmpty && delete) {
        final next = await JadeSlipService.instance.removeComment(
          id: id,
          commentId: commentId,
        );
        return {
          'success': true,
          'action': 'removed',
          'slip': _slipJson(next, full: true),
        };
      }
      final text = flags['text']?.trim() ?? '';
      if (text.isEmpty) {
        return {
          'success': true,
          'count': slip.comments.length,
          'comments': [
            for (final c in slip.comments)
              {
                'id': c.id,
                'author_id': c.authorId,
                'author': c.displayName,
                'text': c.text,
                'created_at': c.createdAt,
              },
          ],
        };
      }
      final actor = ChatAgentScope.agentId.trim();
      var authorName = '';
      if (actor == SheService.sheId) {
        authorName = SheService.sheName;
      } else if (actor.isNotEmpty) {
        final agent = await LocalDatabaseService().getRemoteAgentById(actor);
        authorName = agent?.name ?? '';
      }
      final next = await JadeSlipService.instance.addComment(
        id: id,
        text: text,
        authorId: actor,
        authorName: authorName,
      );
      return {
        'success': true,
        'action': 'added',
        'slip': _slipJson(next, full: true),
      };
    } catch (e) {
      return {'error': '$e'};
    }
  }
}

class NotesAttachCommand extends CliCommand {
  @override
  String get name => 'attach';

  @override
  String get description =>
      'Attach a local file (--file) or an existing pouch file (--uri store://)';

  @override
  String get usage =>
      'shepaw notes attach --id <slipId> --file /path/to/file\n'
      'shepaw notes attach --id <slipId> --uri store://files/<device>/...';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id']?.trim() ?? '';
    if (id.isEmpty) return {'error': 'Missing --id. Usage: $usage'};
    final local = (flags['file'] ?? flags['path'] ?? '').trim();
    final uri = (flags['uri'] ?? '').trim();
    try {
      File? file;
      String? name;
      if (local.isNotEmpty) {
        file = File(local);
        name = file.uri.pathSegments.isNotEmpty
            ? file.uri.pathSegments.last
            : file.path;
      } else if (uri.isNotEmpty) {
        file = await StoreAttachmentRef.fileFromStoreUri(uri);
        name = uri.split('/').last;
      } else {
        return {'error': 'Missing --file or --uri. Usage: $usage'};
      }
      if (file == null || !await file.exists()) {
        return {'error': 'Attachment file not found'};
      }
      final slip = await JadeSlipService.instance.addAttachment(
        id: id,
        file: file,
        displayName: name,
      );
      return {
        'success': true,
        'action': 'attached',
        'slip': _slipJson(slip, full: true),
      };
    } catch (e) {
      return {'error': '$e'};
    }
  }
}

class NotesDetachCommand extends CliCommand {
  @override
  String get name => 'detach';

  @override
  String get description =>
      'Remove an attachment from a jade slip (--attachment <id>)';

  @override
  String get usage =>
      'shepaw notes detach --id <slipId> --attachment <attachmentId>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id']?.trim() ?? '';
    if (id.isEmpty) return {'error': 'Missing --id. Usage: $usage'};
    final attId =
        (flags['attachment'] ?? flags['att'] ?? flags['item'] ?? '').trim();
    if (attId.isEmpty) {
      return {'error': 'Missing --attachment. Usage: $usage'};
    }
    try {
      final slip = await JadeSlipService.instance.removeAttachment(
        id: id,
        attachmentId: attId,
      );
      return {
        'success': true,
        'action': 'detached',
        'slip': _slipJson(slip, full: true),
      };
    } catch (e) {
      return {'error': '$e'};
    }
  }
}

class NotesCompleteCommand extends CliCommand {
  @override
  String get name => 'complete';

  @override
  String get description =>
      'Mark the whole jade slip done (all checklist items checked)';

  @override
  String get usage => 'shepaw notes complete --id <id>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id']?.trim() ?? '';
    if (id.isEmpty) return {'error': 'Missing --id. Usage: $usage'};
    try {
      final slip = await JadeSlipService.instance.complete(id);
      return {'success': true, 'action': 'completed', 'slip': _slipJson(slip, full: true)};
    } catch (e) {
      return {'error': '$e'};
    }
  }
}

class NotesDeleteCommand extends CliCommand {
  @override
  String get name => 'delete';

  @override
  String get description =>
      'Delete a jade slip (only the user or She)';

  @override
  String get usage => 'shepaw notes delete --id <id>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id']?.trim() ?? '';
    if (id.isEmpty) return {'error': 'Missing --id. Usage: $usage'};
    final actor = ChatAgentScope.agentId.trim();
    if (actor.isNotEmpty &&
        actor != SheService.sheId &&
        actor != LocalUserIdentity.id) {
      return {
        'error': 'Permission denied: only the user or She can delete jade slips. '
            'Mark it done with notes complete instead.',
      };
    }
    final existing = await JadeSlipService.instance.getById(id);
    if (existing == null) return {'error': 'Jade slip not found: $id'};
    await JadeSlipService.instance.delete(id);
    return {'success': true, 'deleted': id, 'title': existing.title};
  }
}

int? _parseDue(String? raw) {
  final s = raw?.trim() ?? '';
  if (s.isEmpty) return null;
  final asInt = int.tryParse(s);
  if (asInt != null) return asInt < 100000000000 ? asInt * 1000 : asInt;
  return DateTime.tryParse(s)?.millisecondsSinceEpoch;
}
