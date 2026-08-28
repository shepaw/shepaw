import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shepaw/services/location_access_policy.dart';
import 'package:shepaw/services/she_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocationAccessPolicy.sheAutoApproveOverride = null;
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    LocationAccessPolicy.sheAutoApproveOverride = null;
  });

  group('shouldSkipOsConfirmation', () {
    test('She skips location_get when auto-approve is on', () {
      expect(
        LocationAccessPolicy.shouldSkipOsConfirmation(
          agentId: SheService.sheId,
          toolName: 'location_get',
          sheAutoApprove: true,
        ),
        isTrue,
      );
    });

    test('She still confirms location_get when auto-approve is off', () {
      expect(
        LocationAccessPolicy.shouldSkipOsConfirmation(
          agentId: SheService.sheId,
          toolName: 'location_get',
          sheAutoApprove: false,
        ),
        isFalse,
      );
    });

    test('other agents always confirm location_get', () {
      expect(
        LocationAccessPolicy.shouldSkipOsConfirmation(
          agentId: 'some-other-agent',
          toolName: 'location_get',
          sheAutoApprove: true,
        ),
        isFalse,
      );
    });

    test('does not skip unrelated OS tools', () {
      expect(
        LocationAccessPolicy.shouldSkipOsConfirmation(
          agentId: SheService.sheId,
          toolName: 'file_write',
          sheAutoApprove: true,
        ),
        isFalse,
      );
    });
  });

  group('prefs', () {
    test('defaults to auto-approve for She', () async {
      expect(await LocationAccessPolicy.sheAutoApprove(), isTrue);
    });

    test('persists the toggle', () async {
      await LocationAccessPolicy.setSheAutoApprove(false);
      expect(await LocationAccessPolicy.sheAutoApprove(), isFalse);
      await LocationAccessPolicy.setSheAutoApprove(true);
      expect(await LocationAccessPolicy.sheAutoApprove(), isTrue);
    });
  });
}
