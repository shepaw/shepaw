import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/workflow_models.dart';

void main() {
  group('WorkflowCancellationToken.addOnCancelled', () {
    test('listener fires when cancel is called', () {
      final token = WorkflowCancellationToken();
      var fired = 0;
      token.addOnCancelled(() => fired++);

      expect(token.isCancelled, false);
      expect(fired, 0);

      token.cancel();

      expect(token.isCancelled, true);
      expect(fired, 1);
    });

    test('listener registered after cancel fires immediately', () {
      final token = WorkflowCancellationToken();
      token.cancel();

      var fired = 0;
      token.addOnCancelled(() => fired++);
      expect(fired, 1);
    });

    test('multiple listeners all fire in registration order', () {
      final token = WorkflowCancellationToken();
      final order = <int>[];
      token.addOnCancelled(() => order.add(1));
      token.addOnCancelled(() => order.add(2));
      token.addOnCancelled(() => order.add(3));

      token.cancel();
      expect(order, [1, 2, 3]);
    });

    test('cancel is idempotent — listeners fire only once', () {
      final token = WorkflowCancellationToken();
      var fired = 0;
      token.addOnCancelled(() => fired++);

      token.cancel();
      token.cancel();
      token.cancel();

      expect(fired, 1);
    });

    test('listeners are cleared after firing — late cancel does not re-fire', () {
      final token = WorkflowCancellationToken();
      var fired = 0;
      token.addOnCancelled(() => fired++);

      token.cancel();
      expect(fired, 1);

      // A second registration after cancel fires immediately (by design),
      // but the original listener must not fire again.
      token.cancel();
      expect(fired, 1);
    });
  });
}
