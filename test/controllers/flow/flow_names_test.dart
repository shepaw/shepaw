import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/flow/flow_names.dart';

void main() {
  group('FlowNameRules', () {
    test('正常名字放行', () {
      expect(FlowNameRules.check('dev'), isNull);
      expect(FlowNameRules.check('my-flow'), isNull);
      expect(FlowNameRules.check('my_flow'), isNull);
      expect(FlowNameRules.check('v1.2'), isNull);
    });

    test('空名字、保留字、非法字符', () {
      expect(FlowNameRules.check(''), FlowNameProblem.empty);
      expect(FlowNameRules.check('   '), FlowNameProblem.empty);
      // 这几个是储物袋自己占的，拼进 scope 会撞。
      expect(FlowNameRules.check('shared'), FlowNameProblem.reserved);
      expect(FlowNameRules.check('session'), FlowNameProblem.reserved);
      expect(FlowNameRules.check('task'), FlowNameProblem.reserved);
      expect(FlowNameRules.check('member'), FlowNameProblem.reserved);
      expect(FlowNameRules.check('has space'), FlowNameProblem.invalid);
      expect(FlowNameRules.check('a/b'), FlowNameProblem.invalid);
      expect(FlowNameRules.check('中文'), FlowNameProblem.invalid);
    });
  });

  test('空白骨架是合法的最小流程', () {
    final yaml = FlowBlankFlow.skeleton('dev');
    expect(yaml, 'flow: dev\nversion: 1\nsteps: []\n');
    // 根层 steps 为空不算问题（validate 只查容器自己的 steps）。
    expect(yaml.contains('steps: []'), isTrue);
  });
}
