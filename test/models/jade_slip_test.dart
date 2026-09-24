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

  /// 顶栏「交给 Agent」只交待办项：已完成的留在玉简里，但进度摘要仍给到
  /// Agent，免得它以为这条玉简只有一件事。
  test('onlyOpenItems 只列未完成项，并保留进度摘要', () {
    const slip = JadeSlip(
      id: 'slip-1',
      title: 'Book flights',
      items: [
        JadeSlipItem(id: 'done1', text: '已完成的事', done: true),
        JadeSlipItem(id: 'open1', text: '待办的事'),
        JadeSlipItem(id: 'open2', text: '另一件待办'),
      ],
      deviceId: 'aaaaaaaaaaaaaaaa',
      createdAt: 0,
      updatedAt: 0,
    );

    final prompt = slip.toAgentPrompt(onlyOpenItems: true);
    expect(prompt, contains('待办 2/3 项'));
    expect(prompt, contains('已完成 1 项'));
    expect(prompt, contains('item=open1'));
    expect(prompt, contains('item=open2'));
    expect(prompt, isNot(contains('item=done1')));
    // 全部完成才建议 complete；这条还有待办，仍然可以建议。
    expect(prompt, contains('shepaw notes complete'));
  });

  /// 单项派发（清单项菜单）：只给这一项，且不能建议 complete——
  /// 那会把整条玉简标记为完成。
  test('focusItem 只派发一项，且不建议 complete', () {
    const slip = JadeSlip(
      id: 'slip-1',
      title: 'Book flights',
      items: [
        JadeSlipItem(id: 'itemA', text: '甲'),
        JadeSlipItem(id: 'itemB', text: '乙'),
      ],
      deviceId: 'aaaaaaaaaaaaaaaa',
      createdAt: 0,
      updatedAt: 0,
    );

    final prompt = slip.toAgentPrompt(
      focusItem: slip.items[1],
      onlyOpenItems: true,
    );
    expect(prompt, contains('中的这一项'));
    expect(prompt, contains('item=itemB'));
    expect(prompt, isNot(contains('item=itemA')));
    expect(prompt, isNot(contains('shepaw notes complete')));
    // 勾一项、留言仍然要教。
    expect(prompt, contains('shepaw notes item'));
    expect(prompt, contains('shepaw notes comment'));
  });

  /// 待办为空但清单非空：如实说明，别让 Agent 以为没有清单。
  test('onlyOpenItems 且全部完成时说明无待办', () {
    const slip = JadeSlip(
      id: 'slip-1',
      title: 'Book flights',
      items: [JadeSlipItem(id: 'done1', text: '做完了', done: true)],
      deviceId: 'aaaaaaaaaaaaaaaa',
      createdAt: 0,
      updatedAt: 0,
    );

    final prompt = slip.toAgentPrompt(onlyOpenItems: true);
    expect(prompt, contains('全部已完成，无待办'));
    expect(prompt, isNot(contains('- [x] 做完了')));
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
