import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/clis/shepaw/os/location/location_namespace.dart';
import 'package:shepaw/clis/shepaw/os/os_executor.dart';
import 'package:shepaw/clis/shepaw/os/os_tool_registry.dart';
import 'package:shepaw/services/location_service.dart';

class _FakeBackend implements LocationBackend {
  _FakeBackend({
    this.serviceEnabled = true,
    this.permission = 'whileInUse',
    this.requestResult = 'whileInUse',
    this.fix,
    this.place,
    this.throwOnFix,
  });

  bool serviceEnabled;
  String permission;
  String requestResult;
  LocationFix? fix;
  Map<String, dynamic>? place;
  Exception? throwOnFix;
  int requestCount = 0;

  @override
  Future<bool> isServiceEnabled() async => serviceEnabled;

  @override
  Future<String> checkPermission() async => permission;

  @override
  Future<String> requestPermission() async {
    requestCount++;
    permission = requestResult;
    return requestResult;
  }

  @override
  Future<LocationFix> getCurrentPosition({
    required String accuracy,
    required Duration timeout,
  }) async {
    if (throwOnFix != null) throw throwOnFix!;
    return fix ??
        LocationFix(
          latitude: 31.2304,
          longitude: 121.4737,
          accuracyM: 12.5,
          timestamp: DateTime.utc(2026, 8, 28, 6, 57),
        );
  }

  @override
  Future<Map<String, dynamic>?> reverseGeocode(
    double latitude,
    double longitude,
  ) async =>
      place;
}

void main() {
  late LocationService original;

  setUp(() {
    original = LocationService.instance;
  });

  tearDown(() {
    LocationService.instance = original;
  });

  group('OsToolRegistry location', () {
    test('registers location_get and location_status', () {
      final getDef = OsToolRegistry.instance.getDefinition('location_get');
      final statusDef = OsToolRegistry.instance.getDefinition('location_status');
      expect(getDef, isNotNull);
      expect(getDef!.cliPath, 'os.location.get');
      expect(getDef.category, 'location');
      expect(statusDef, isNotNull);
      expect(statusDef!.cliPath, 'os.location.status');
      expect(
        OsToolRegistry.instance.resolveToolName('os.location.get'),
        'location_get',
      );
    });

    test('classifyRisk: get is lowRisk, status is safe', () {
      expect(classifyRisk('location_get', {}), RiskLevel.lowRisk);
      expect(classifyRisk('location_status', {}), RiskLevel.safe);
    });
  });

  group('LocationService', () {
    test('status reports available when service and permission are on', () async {
      LocationService.instance = LocationService(
        backend: _FakeBackend(permission: 'always'),
      );
      final result = await LocationService.instance.status();
      expect(result['success'], isTrue);
      expect(result['available'], isTrue);
      expect(result['permission'], 'always');
    });

    test('getCurrent returns coordinates and place', () async {
      LocationService.instance = LocationService(
        backend: _FakeBackend(
          place: {'locality': 'Shanghai', 'country': 'China'},
        ),
      );
      final result = await LocationService.instance.getCurrent();
      expect(result['success'], isTrue);
      expect(result['latitude'], 31.2304);
      expect(result['longitude'], 121.4737);
      expect(result['place']['locality'], 'Shanghai');
    });

    test('getCurrent skips reverse geocode when disabled', () async {
      LocationService.instance = LocationService(
        backend: _FakeBackend(
          place: {'locality': 'Shanghai'},
        ),
      );
      final result = await LocationService.instance.getCurrent(
        reverseGeocode: false,
      );
      expect(result['success'], isTrue);
      expect(result.containsKey('place'), isFalse);
    });

    test('getCurrent requests permission when denied', () async {
      final backend = _FakeBackend(
        permission: 'denied',
        requestResult: 'whileInUse',
      );
      LocationService.instance = LocationService(backend: backend);
      final result = await LocationService.instance.getCurrent();
      expect(backend.requestCount, 1);
      expect(result['success'], isTrue);
    });

    test('getCurrent fails when services are disabled', () async {
      LocationService.instance = LocationService(
        backend: _FakeBackend(serviceEnabled: false),
      );
      final result = await LocationService.instance.getCurrent();
      expect(result['success'], isFalse);
      expect(result['code'], 'service_disabled');
    });

    test('getCurrent fails when permission denied forever', () async {
      LocationService.instance = LocationService(
        backend: _FakeBackend(permission: 'deniedForever'),
      );
      final result = await LocationService.instance.getCurrent();
      expect(result['success'], isFalse);
      expect(result['code'], 'permission_denied_forever');
    });
  });

  group('os.location CLI', () {
    test('location.get delegates to LocationService', () async {
      LocationService.instance = LocationService(
        backend: _FakeBackend(
          place: {'locality': 'Shanghai'},
        ),
      );
      final result = await LocationNamespace.instance.execute('get', {
        'accuracy': 'medium',
        'reverse_geocode': 'true',
      });
      expect(result['success'], isTrue);
      expect(result['latitude'], 31.2304);
    });

    test('location.status does not read GPS', () async {
      final backend = _FakeBackend(throwOnFix: Exception('should not read GPS'));
      LocationService.instance = LocationService(backend: backend);
      final result = await LocationNamespace.instance.execute('status', {});
      expect(result['success'], isTrue);
      expect(result['available'], isTrue);
    });
  });
}
