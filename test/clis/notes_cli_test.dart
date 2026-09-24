import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/chat/chat_agent_scope.dart';
import 'package:shepaw/clis/shepaw/notes/notes_namespace.dart';
import 'package:shepaw/models/jade_slip.dart';
import 'package:shepaw/services/jade_slip_service.dart';
import 'package:shepaw/services/she_service.dart';
import 'package:shepaw/storage/local_store.dart';

void main() {
  late Directory tmp;
  late LocalStore store;
  const self = 'aaaaaaaaaaaaaaaa';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jade_slip_test');
    store = LocalStore(root: tmp)..debugSkipVolumeQuota = true;
    JadeSlipService.instance.debugStore = store;
    JadeSlipService.instance.debugDeviceId = self;
  });

  tearDown(() async {
    JadeSlipService.instance.debugStore = null;
    JadeSlipService.instance.debugDeviceId = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<T> asAgent<T>(String agentId, Future<T> Function() body) =>
      ChatAgentScope.runScoped(agentId: agentId, body: body);

  test('create / list / complete via service', () async {
    final created = await JadeSlipService.instance.create(
      title: 'Book flights',
      items: [
        JadeSlipItem(id: 'a1', text: 'compare'),
        JadeSlipItem(id: 'a2', text: 'buy'),
      ],
    );
    expect(created.deviceId, self);
    expect((await JadeSlipService.instance.list()).length, 1);

    await JadeSlipService.instance.setItemDone(
      id: created.id,
      itemId: 'a1',
      done: true,
    );
    final mid = await JadeSlipService.instance.getById(created.id);
    expect(mid!.status, JadeSlipStatus.inProgress);
    expect(mid.submittedCount, 1);

    await JadeSlipService.instance.removeItem(
      id: created.id,
      itemId: 'a2',
    );
    final trimmed = await JadeSlipService.instance.getById(created.id);
    expect(trimmed!.items.map((e) => e.id).toList(), ['a1']);
    expect(trimmed.status, JadeSlipStatus.needsReview);

    await JadeSlipService.instance.acceptItem(id: created.id, itemId: 'a1');
    final done = await JadeSlipService.instance.getById(created.id);
    expect(done!.status, JadeSlipStatus.done);
    expect(done.allItemsDone, isTrue);
  });

  test('notes CLI add / item / complete / delete', () async {
    final help = await NotesNamespace.instance.getHelpAsync();
    final commands = help['commands'] as Map<String, dynamic>;
    for (final name in [
      'list',
      'get',
      'add',
      'update',
      'item',
      'comment',
      'attach',
      'detach',
      'complete',
      'delete',
    ]) {
      expect(commands.containsKey(name), isTrue, reason: name);
    }

    final added = await NotesAddCommand().execute({
      'title': 'Pack',
      'items': 'passport;charger',
    });
    expect(added['success'], isTrue);
    final slip = (added['slip'] as Map)['id'] as String;

    final listed = await NotesListCommand().execute({});
    expect(listed['count'], 1);

    final got = await NotesGetCommand().execute({'id': slip});
    final items = ((got['slip'] as Map)['items'] as List).cast<Map>();
    expect(items.length, 2);
    final firstId = items.first['id'] as String;

    final checked = await NotesItemCommand().execute({
      'id': slip,
      'item': firstId,
      'done': 'true',
    });
    expect(checked['success'], isTrue);

    final removed = await NotesItemCommand().execute({
      'id': slip,
      'item': firstId,
      'delete': 'true',
    });
    expect(removed['success'], isTrue);
    expect(removed['action'], 'removed');
    expect(((removed['slip'] as Map)['items'] as List).length, 1);

    final tmpFile = File('${tmp.path}/note.txt');
    await tmpFile.writeAsString('hello');
    final attached = await NotesAttachCommand().execute({
      'id': slip,
      'file': tmpFile.path,
    });
    expect(attached['success'], isTrue);
    final atts = ((attached['slip'] as Map)['attachments'] as List).cast<Map>();
    expect(atts.length, 1);
    expect(atts.first['name'], 'note.txt');
    final detached = await NotesDetachCommand().execute({
      'id': slip,
      'attachment': atts.first['id'] as String,
    });
    expect(detached['success'], isTrue);
    expect((detached['slip'] as Map)['attachments'], isNull);

    final renamed = await NotesItemCommand().execute({
      'id': slip,
      'item': ((removed['slip'] as Map)['items'] as List).cast<Map>().first['id']
          as String,
      'text': 'charger + cable',
    });
    expect(renamed['success'], isTrue);
    expect(renamed['action'], 'renamed');
    expect(
      ((renamed['slip'] as Map)['items'] as List).cast<Map>().first['text'],
      'charger + cable',
    );

    final posted = await asAgent(
      SheService.sheId,
      () => NotesCommentCommand().execute({
        'id': slip,
        'text': '已改完第一步',
      }),
    );
    expect(posted['success'], isTrue);
    final comments = ((posted['slip'] as Map)['comments'] as List).cast<Map>();
    expect(comments.single['author'], 'She');
    expect(comments.single['text'], '已改完第一步');

    final listedComments = await NotesCommentCommand().execute({'id': slip});
    expect(listedComments['count'], 1);

    final removedComment = await NotesCommentCommand().execute({
      'id': slip,
      'comment': comments.single['id'] as String,
      'delete': 'true',
    });
    expect(removedComment['success'], isTrue);
    expect((removedComment['slip'] as Map)['comments'], isNull);

    final completed = await NotesCompleteCommand().execute({'id': slip});
    expect(completed['success'], isTrue);
    expect((completed['slip'] as Map)['status'], 'needs_review');

    final denied = await asAgent(
      'agent-other',
      () => NotesDeleteCommand().execute({'id': slip}),
    );
    expect(denied['error'], contains('Permission denied'));

    final deleted = await asAgent(
      SheService.sheId,
      () => NotesDeleteCommand().execute({'id': slip}),
    );
    expect(deleted['success'], isTrue);
    expect(await JadeSlipService.instance.list(includeArchived: true), isEmpty);
  });

  test('notes CLI writes the goal and assigns an item to another agent', () async {
    final tasked = await NotesAddCommand().execute({
      'title': 'Plan trip',
      'goal': '订好下周行程',
      'constraints': '预算 3000',
      'done-when': '日程写进备注',
      'items': '查机票',
    });
    expect(tasked['success'], isTrue);
    final taskedId = (tasked['slip'] as Map)['id'] as String;
    expect((tasked['slip'] as Map)['goal'], '订好下周行程');
    expect((tasked['slip'] as Map)['done_when'], '日程写进备注');

    final itemId =
        ((tasked['slip'] as Map)['items'] as List).cast<Map>().first['id']
            as String;
    final assigned = await NotesItemCommand().execute({
      'id': taskedId,
      'item': itemId,
      'assignee': 'agent-b',
      'assignee-name': 'Beta',
    });
    expect(assigned['action'], 'assigned');
    final assignedItem =
        ((assigned['slip'] as Map)['items'] as List).cast<Map>().first;
    expect(assignedItem['assignee_agent_name'], 'Beta');

    final cleared = await NotesItemCommand().execute({
      'id': taskedId,
      'item': itemId,
      'assignee': '',
    });
    expect(cleared['action'], 'unassigned');
    expect(
      ((cleared['slip'] as Map)['items'] as List)
          .cast<Map>()
          .first['assignee_agent_id'],
      isNull,
    );
  });

  test('split a item into a child slip and accepting the child submits the parent item', () async {
    final parent = await JadeSlipService.instance.create(
      title: '出行',
      items: [JadeSlipItem(id: 'flight', text: '订机票')],
    );
    final split = await NotesSplitCommand().execute({
      'id': parent.id,
      'item': 'flight',
    });
    expect(split['success'], isTrue);
    final childId = split['child_id'] as String;

    final got = await NotesGetCommand().execute({'id': parent.id});
    final children = (got['slip'] as Map)['children'] as List;
    expect(children.single['id'], childId);

    final childGot = await NotesGetCommand().execute({'id': childId});
    expect((childGot['slip'] as Map)['parent_id'], parent.id);
    expect((childGot['slip'] as Map)['source_item_id'], 'flight');

    final accepted = await NotesAcceptCommand().execute({'id': childId});
    expect(accepted['success'], isTrue);
    expect((accepted['slip'] as Map)['status'], 'done');

    final parentAfter = await JadeSlipService.instance.getById(parent.id);
    expect(parentAfter!.items.single.state, JadeSlipItemState.submitted);
    expect(parentAfter.status, JadeSlipStatus.needsReview);
  });
}
