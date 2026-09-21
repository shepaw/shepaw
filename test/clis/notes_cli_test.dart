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
    expect(mid.doneCount, 1);

    await JadeSlipService.instance.removeItem(
      id: created.id,
      itemId: 'a2',
    );
    final trimmed = await JadeSlipService.instance.getById(created.id);
    expect(trimmed!.items.map((e) => e.id).toList(), ['a1']);
    expect(trimmed.status, JadeSlipStatus.done);

    await JadeSlipService.instance.complete(created.id);
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

    final completed = await NotesCompleteCommand().execute({'id': slip});
    expect(completed['success'], isTrue);
    expect((completed['slip'] as Map)['status'], 'done');

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
}
