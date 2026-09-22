import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/jade_slip.dart';

void main() {
  test('markdown checkboxes become items', () {
    const md = '''
Buy tickets

- [ ] compare prices
- [x] pick dates
* [ ] pay
''';
    final items = JadeSlip.itemsFromMarkdown(md);
    expect(items.map((e) => e.text).toList(),
        ['compare prices', 'pick dates', 'pay']);
    expect(items[1].done, isTrue);
    expect(items[0].done, isFalse);
  });

  test('blank draft matches untitled placeholder with no content', () {
    final blank = JadeSlip(
      id: 'a',
      title: '未题玉简',
      deviceId: 'dev',
      createdAt: 1,
      updatedAt: 1,
    );
    expect(blank.isBlankDraft(untitledTitle: '未题玉简'), isTrue);
    expect(blank.isBlankDraft(untitledTitle: 'Untitled slip'), isFalse);
    expect(
      blank.copyWith(title: '买菜').isBlankDraft(untitledTitle: '未题玉简'),
      isFalse,
    );
    expect(
      blank.copyWith(body: '备注').isBlankDraft(untitledTitle: '未题玉简'),
      isFalse,
    );
    expect(
      blank
          .copyWith(items: const [JadeSlipItem(id: '1', text: 'x')])
          .isBlankDraft(untitledTitle: '未题玉简'),
      isFalse,
    );
  });

  test('withDerivedStatus follows checklist', () {
    final now = 1;
    final base = JadeSlip(
      id: 'a',
      title: 't',
      items: const [
        JadeSlipItem(id: '1', text: 'one'),
        JadeSlipItem(id: '2', text: 'two'),
      ],
      deviceId: 'aaaaaaaaaaaaaaaa',
      createdAt: now,
      updatedAt: now,
    );
    expect(base.withDerivedStatus().status, JadeSlipStatus.open);
    final oneDone = base.copyWith(items: [
      base.items[0].copyWith(done: true),
      base.items[1],
    ]).withDerivedStatus();
    expect(oneDone.status, JadeSlipStatus.inProgress);
    final allDone = base.copyWith(items: [
      base.items[0].copyWith(done: true),
      base.items[1].copyWith(done: true),
    ]).withDerivedStatus();
    expect(allDone.status, JadeSlipStatus.done);
  });

  test('agent prompt includes item ids and CLI hints', () {
    final slip = JadeSlip(
      id: 'slip-1',
      title: 'Book flights',
      items: const [JadeSlipItem(id: 'ab12cd34', text: 'compare')],
      deviceId: 'aaaaaaaaaaaaaaaa',
      createdAt: 0,
      updatedAt: 0,
    );
    final prompt = slip.toAgentPrompt();
    expect(prompt, contains('id=slip-1'));
    expect(prompt, contains('item=ab12cd34'));
    expect(prompt, contains('shepaw notes item'));
    expect(prompt, contains('shepaw notes complete'));
  });

  test('json roundtrip', () {
    final slip = JadeSlip(
      id: 'id1',
      title: 'Title',
      body: 'notes',
      status: JadeSlipStatus.inProgress,
      priority: JadeSlipPriority.high,
      items: const [JadeSlipItem(id: 'i1', text: 'x', done: true)],
      attachments: const [
        JadeSlipAttachment(
          id: 'att1',
          name: 'shot.png',
          path: 'slips/id1/files/att1-shot.png',
          sizeBytes: 12,
        ),
      ],
      assigneeAgentId: 'she-builtin-agent-001',
      dueAtMs: 100,
      tags: const ['travel'],
      deviceId: 'aaaaaaaaaaaaaaaa',
      createdAt: 1,
      updatedAt: 2,
    );
    final copy = JadeSlip.fromJson(slip.toJson());
    expect(copy.id, slip.id);
    expect(copy.status, JadeSlipStatus.inProgress);
    expect(copy.priority, JadeSlipPriority.high);
    expect(copy.items.single.done, isTrue);
    expect(copy.attachments.single.name, 'shot.png');
    expect(copy.dueAtMs, 100);
    expect(copy.relPath, 'slips/id1.json');
  });

  test('isRecordPath only matches slips/<id>.json', () {
    expect(JadeSlip.isRecordPath('slips/id1.json'), isTrue);
    expect(JadeSlip.idFromRecordPath('slips/id1.json'), 'id1');
    expect(JadeSlip.isRecordPath('slips/id1/files/a.png'), isFalse);
    expect(JadeSlip.isRecordPath('other/id1.json'), isFalse);
    expect(JadeSlip.idFromRecordPath('slips/id1/files/a.png'), isNull);
  });
}
