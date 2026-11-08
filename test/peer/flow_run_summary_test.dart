import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/peer/models/flow_models.dart';

void main() {
  test('运行列表读出开跑标题，旧主机没有这个字段就留空', () {
    final runs = FlowRunSummary.listFromResponse({
      'success': true,
      'runs': [
        {
          'run_id': 'run_goal',
          'flow': 'dev',
          'status': 'succeeded',
          'input_title': '  修好登录页  ',
        },
        {
          'run_id': 'run_old',
          'flow': 'dev',
          'status': 'failed',
        },
      ],
    });

    expect(runs, hasLength(2));
    expect(runs[0].inputTitle, '修好登录页');
    expect(runs[1].inputTitle, isEmpty);
  });
}
