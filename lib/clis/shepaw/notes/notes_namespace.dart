import 'dart:io';

import '../../cli_base.dart';
import '../../../models/jade_slip.dart';
import '../../../models/store_attachment_ref.dart';
import '../../../services/jade_slip_service.dart';
import '../../../services/jade_slip_wake.dart';
import '../../../services/local_database_service.dart';
import '../../../services/local_user_identity.dart';
import '../../../services/she_service.dart';
import '../chat/chat_agent_scope.dart';

/// 玉简：人把目标交给 Agent，Agent 再把清单项交给其他 Agent。
/// 进度写回同一条简，不散落在各会话里。
class NotesNamespace extends CliNamespace {
  static final instance = NotesNamespace._();
  NotesNamespace._();

  @override
  String get namespace => 'slip';

  @override
  String get description =>
      'Jade slips (玉简): the shared contract between a person and agents. '
      'The human writes the goal; agents check items off and hand an item '
      'to another agent with slip item --assignee. Prefer this over ad-hoc '
      'chat when work must stay visible after the session ends.';

  @override
  String get icon => '📜';

  @override
  Map<String, CliCommand> get commands => {
        'list': NotesListCommand(),
        'get': NotesGetCommand(),
        'add': NotesAddCommand(),
        'update': NotesUpdateCommand(),
        'item': NotesItemCommand(),
        'split': NotesSplitCommand(),
        'accept': NotesAcceptCommand(),
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
    if (slip.goal.isNotEmpty) 'goal': slip.goal,
    if (full && slip.constraints.isNotEmpty) 'constraints': slip.constraints,
    if (full && slip.doneWhen.isNotEmpty) 'done_when': slip.doneWhen,
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
          {'id': item.id, 'text': item.text, 'state': item.state.wire, 'done': item.done, ..._itemAssignee(item), if (item.blockedReason.isNotEmpty) 'blocked_reason': item.blockedReason, if (item.evidence.isNotEmpty) 'evidence': item.evidence, if (item.sessionId.isNotEmpty) 'session_id': item.sessionId},
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
      if (slip.sourceChannelId.isNotEmpty)
        'source_channel_id': slip.sourceChannelId,
      if (slip.events.isNotEmpty)
        'events': [
          for (final e in slip.events)
            {
              'id': e.id,
              'kind': e.kind,
              'actor': e.displayName,
              'item_id': e.itemId,
              'text': e.text,
              'created_at': e.createdAt,
            },
        ],
      'created_at': slip.createdAt,
    } else if (slip.items.isNotEmpty)
      'open_items': [
        for (final item in slip.items)
          if (!item.done) {'id': item.id, 'text': item.text, ..._itemAssignee(item)},
      ],
  };
}

Map<String, dynamic> _itemAssignee(JadeSlipItem item) => {
      if (item.assigneeAgentId.isNotEmpty)
        'assignee_agent_id': item.assigneeAgentId,
      if (item.assigneeAgentName.isNotEmpty)
        'assignee_agent_name': item.assigneeAgentName,
    };

class NotesListCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description =>
      'List jade slips. Default: open + in_progress. '
      'Use --status all to include completed.';

  @override
  String get usage =>
      'shepaw slip list [--status open|in_progress|done|all] [--query <text>]';

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
          : 'Use shepaw slip get --id <id> then slip item / slip complete.',
    };
  }
}

class NotesGetCommand extends CliCommand {
  @override
  String get name => 'get';

  @override
  String get description =>
      'Get one jade slip including checklist item ids for slip item';

  @override
  String get usage => 'shepaw slip get --id <id>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id']?.trim() ?? '';
    if (id.isEmpty) return {'error': 'Missing --id. Usage: $usage'};
    final slip = await JadeSlipService.instance.getById(id);
    if (slip == null) return {'error': 'Jade slip not found: $id'};
    final json = _slipJson(slip, full: true);
    if (slip.parentId.isNotEmpty) json['parent_id'] = slip.parentId;
    if (slip.sourceItemId.isNotEmpty) {
      json['source_item_id'] = slip.sourceItemId;
    }
    final children = await JadeSlipService.instance.childrenOf(slip.id);
    json['children'] = [
      for (final child in children)
        {'id': child.id, 'title': child.title, 'status': child.status.wire},
    ];
    return {'success': true, 'slip': json};
  }
}

class NotesAddCommand extends CliCommand {
  @override
  String get name => 'add';

  @override
  String get description =>
      'Create a jade slip. --items is semicolon-separated checklist text. '
      'Markdown "- [ ] item" in --body is also parsed into checklist items. '
      '--goal is what the human wants done; --constraints and --done-when '
      'travel with the slip when another agent picks up an item.';

  @override
  String get usage =>
      'shepaw slip add --title "Book flights" '
      '[--goal "..."] [--constraints "..."] [--done-when "..."] '
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
        goal: flags['goal'] ?? '',
        constraints: flags['constraints'] ?? '',
        doneWhen: _flag(flags, 'done-when', 'done_when') ?? '',
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
      'Update title/body/goal/constraints/done-when/status/priority/assignee/due';

  @override
  String get usage =>
      'shepaw slip update --id <id> [--title t] [--body b] '
      '[--goal g] [--constraints c] [--done-when d] '
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
    if (flags.containsKey('goal')) {
      next = next.copyWith(goal: flags['goal'] ?? '');
    }
    if (flags.containsKey('constraints')) {
      next = next.copyWith(constraints: flags['constraints'] ?? '');
    }
    final doneWhen = _flag(flags, 'done-when', 'done_when');
    if (doneWhen != null) {
      next = next.copyWith(doneWhen: doneWhen);
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
    if (flags.containsKey('parent')) {
      next = next.copyWith(parentId: flags['parent']!.trim());
    }
    if (flags.containsKey('blocked-by') || flags.containsKey('blocked_by')) {
      next = next.copyWith(
        blockedBySlipId: (flags['blocked-by'] ?? flags['blocked_by'] ?? '').trim(),
      );
    }
    try {
      final slip = await JadeSlipService.instance.update(next);
      return {'success': true, 'slip': _slipJson(slip, full: true)};
    } catch (e) {
      return {'error': '$e'};
    }
  }
}

class NotesSplitCommand extends CliCommand {
  @override
  String get name => 'split';

  @override
  String get description =>
      'Turn one checklist item into a child jade slip. The child remembers '
      'the parent slip and the source item. Accepting the child submits '
      'that item on the parent.';

  @override
  String get usage => 'shepaw slip split --id <slipId> --item <itemId>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id']?.trim() ?? '';
    final itemId = flags['item']?.trim() ?? '';
    if (id.isEmpty || itemId.isEmpty) {
      return {'error': 'Missing --id or --item. Usage: $usage'};
    }
    try {
      final child = await JadeSlipService.instance.splitItem(
        id: id,
        itemId: itemId,
      );
      return {
        'success': true,
        'action': 'split',
        'child_id': child.id,
        'parent_id': child.parentId,
        'source_item_id': child.sourceItemId,
        'slip': _slipJson(child, full: true),
      };
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
      'Check off submits an item (--done true) for the human to accept. '
      'Also: uncheck, append, retitle, --assignee, --block --reason, '
      '--evidence <uri>, or --delete.';

  @override
  String get usage =>
      'shepaw slip item --id <slipId> --item <itemId> --done true\n'
      'shepaw slip item --id <slipId> --item <itemId> --block --reason "..."\n'
      'shepaw slip item --id <slipId> --item <itemId> --evidence <uri>\n'
      'shepaw slip item --id <slipId> --item <itemId> --assignee <agent_id>';

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
      if (flags.containsKey('assignee')) {
        if (itemId.isEmpty) {
          return {'error': 'Missing --item. Usage: $usage'};
        }
        final agentId = flags['assignee']!.trim();
        final slip = await JadeSlipService.instance.assignItem(
          id: id,
          itemId: itemId,
          assigneeAgentId: agentId,
          assigneeAgentName: await _agentName(agentId, flags),
        );
        if (agentId.isNotEmpty) {
          await JadeSlipWake.notify(slip, '有一项改派给 $agentId');
        }
        return {
          'success': true,
          'action': agentId.isEmpty ? 'unassigned' : 'assigned',
          'slip': _slipJson(slip, full: true),
        };
      }
      if (flags.containsKey('evidence')) {
        if (itemId.isEmpty) return {'error': 'Missing --item. Usage: $usage'};
        final slip = await JadeSlipService.instance.addEvidence(
          id: id,
          itemId: itemId,
          uri: flags['evidence'] ?? '',
        );
        return {'success': true, 'action': 'evidence', 'slip': _slipJson(slip, full: true)};
      }
      if (flags.containsKey('block')) {
        if (itemId.isEmpty) return {'error': 'Missing --item. Usage: $usage'};
        final slip = await JadeSlipService.instance.blockItem(
          id: id,
          itemId: itemId,
          reason: flags['reason'] ?? '',
        );
        return {'success': true, 'action': 'blocked', 'slip': _slipJson(slip, full: true)};
      }
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
      final actor = ChatAgentScope.agentId.trim();
      var actorName = '';
      if (done && actor.isNotEmpty && actor != SheService.sheId) {
        final agent = await LocalDatabaseService().getRemoteAgentById(actor);
        actorName = agent?.name ?? '';
      } else if (done && actor == SheService.sheId) {
        actorName = SheService.sheName;
      }
      final slip = await JadeSlipService.instance.setItemDone(
        id: id,
        itemId: itemId,
        done: done,
        actorId: done ? actor : '',
        actorName: actorName,
        sessionId: done ? ChatAgentScope.channelId.trim() : '',
      );
      if (done) await JadeSlipWake.notify(slip, '有一项已提交，等验收');
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

/// 人验收已提交的项。Agent 不能把自己的提交标成完成。
class NotesAcceptCommand extends CliCommand {
  @override
  String get name => 'accept';

  @override
  String get description =>
      'Accept a submitted item (--item) or every submitted item on the slip. '
      'Only the user or She.';

  @override
  String get usage =>
      'shepaw slip accept --id <slipId> [--item <itemId>]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final denied = _denyUnlessUserOrShe();
    if (denied != null) return denied;
    final id = flags['id']?.trim() ?? '';
    if (id.isEmpty) return {'error': 'Missing --id. Usage: $usage'};
    final itemId = (flags['item'] ?? '').trim();
    try {
      if (itemId.isEmpty) {
        final slip = await JadeSlipService.instance.acceptWhole(
          id: id,
          actorId: LocalUserIdentity.id,
          actorName: LocalUserIdentity.displayName,
        );
        await JadeSlipWake.notify(slip, '已验收');
        return {
          'success': true,
          'action': 'accepted',
          'slip': _slipJson(slip, full: true),
        };
      }
      final slip = await JadeSlipService.instance.acceptItem(
        id: id,
        itemId: itemId,
        actorId: LocalUserIdentity.id,
        actorName: LocalUserIdentity.displayName,
      );
      await JadeSlipWake.notify(slip, '有一项已验收');
      return {
        'success': true,
        'action': 'accepted',
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
      'shepaw slip comment --id <slipId> --text "已改完，待验证"\n'
      'shepaw slip comment --id <slipId>\n'
      'shepaw slip comment --id <slipId> --comment <commentId> --delete';

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
        itemId: (flags['item'] ?? '').trim(),
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
      'shepaw slip attach --id <slipId> --file /path/to/file\n'
      'shepaw slip attach --id <slipId> --uri store://files/<device>/...';

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
      'shepaw slip detach --id <slipId> --attachment <attachmentId>';

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
  String get usage => 'shepaw slip complete --id <id>';

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
  String get usage => 'shepaw slip delete --id <id>';

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
            'Mark it done with slip complete instead.',
      };
    }
    final existing = await JadeSlipService.instance.getById(id);
    if (existing == null) return {'error': 'Jade slip not found: $id'};
    await JadeSlipService.instance.delete(id);
    return {'success': true, 'deleted': id, 'title': existing.title};
  }
}

Map<String, dynamic>? _denyUnlessUserOrShe() {
  final actor = ChatAgentScope.agentId.trim();
  if (actor.isNotEmpty &&
      actor != SheService.sheId &&
      actor != LocalUserIdentity.id) {
    return {
      'error': 'Permission denied: only the user or She can accept jade slip items.',
    };
  }
  return null;
}

int? _parseDue(String? raw) {
  final s = raw?.trim() ?? '';
  if (s.isEmpty) return null;
  final asInt = int.tryParse(s);
  if (asInt != null) return asInt < 100000000000 ? asInt * 1000 : asInt;
  return DateTime.tryParse(s)?.millisecondsSinceEpoch;
}

String? _flag(Map<String, String> flags, String a, String b) {
  if (flags.containsKey(a)) return flags[a] ?? '';
  if (flags.containsKey(b)) return flags[b] ?? '';
  return null;
}

Future<String> _agentName(String agentId, Map<String, String> flags) async {
  final given = (flags['assignee-name'] ?? flags['assignee_name'] ?? '').trim();
  if (given.isNotEmpty || agentId.isEmpty) return given;
  if (agentId == SheService.sheId) return SheService.sheName;
  final agent = await LocalDatabaseService().getRemoteAgentById(agentId);
  return agent?.name ?? '';
}
