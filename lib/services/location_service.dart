import 'dart:async';

import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';

/// A single GPS fix. Coordinates only — no address.
class LocationFix {
  final double latitude;
  final double longitude;
  final double? accuracyM;
  final double? altitudeM;
  final double? heading;
  final double? speedMps;
  final DateTime timestamp;
  final bool isMocked;

  const LocationFix({
    required this.latitude,
    required this.longitude,
    this.accuracyM,
    this.altitudeM,
    this.heading,
    this.speedMps,
    required this.timestamp,
    this.isMocked = false,
  });

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        if (accuracyM != null) 'accuracy_m': accuracyM,
        if (altitudeM != null) 'altitude_m': altitudeM,
        if (heading != null) 'heading': heading,
        if (speedMps != null) 'speed_mps': speedMps,
        'timestamp': timestamp.toIso8601String(),
        'is_mocked': isMocked,
      };
}

/// Platform GPS + geocoder. Tests inject a fake.
abstract class LocationBackend {
  Future<bool> isServiceEnabled();
  Future<String> checkPermission();
  Future<String> requestPermission();
  Future<bool> openAppSettings();
  Future<bool> openLocationSettings();
  Future<LocationFix> getCurrentPosition({
    required String accuracy,
    required Duration timeout,
  });
  Future<Map<String, dynamic>?> reverseGeocode(double latitude, double longitude);
}

/// On-demand device location for agents/CLI. Does not start a tracking stream.
class LocationService {
  LocationService({LocationBackend? backend})
      : _backend = backend ?? GeolocatorLocationBackend();

  /// Process-wide instance. Tests replace this with a fake-backed service.
  static LocationService instance = LocationService();

  final LocationBackend _backend;

  /// Permission + whether the OS location service is on. Does not read GPS.
  Future<Map<String, dynamic>> status() async {
    try {
      final serviceEnabled = await _backend.isServiceEnabled();
      final permission = await _backend.checkPermission();
      final granted = permission == 'whileInUse' || permission == 'always';
      return {
        'success': true,
        'service_enabled': serviceEnabled,
        'permission': permission,
        'available': serviceEnabled && granted,
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
        'code': 'unavailable',
      };
    }
  }

  /// Ask for location permission without reading GPS.
  ///
  /// Used by Settings. If the OS location service is off, returns
  /// `service_disabled` instead of prompting.
  Future<Map<String, dynamic>> requestAccess() async {
    try {
      final serviceEnabled = await _backend.isServiceEnabled();
      if (!serviceEnabled) {
        return {
          'success': false,
          'service_enabled': false,
          'permission': await _backend.checkPermission(),
          'available': false,
          'code': 'service_disabled',
          'error': 'Location services are disabled on this device.',
        };
      }

      var permission = await _backend.checkPermission();
      if (permission == 'denied') {
        permission = await _backend.requestPermission();
      }
      final granted = permission == 'whileInUse' || permission == 'always';
      if (granted) {
        return {
          'success': true,
          'service_enabled': true,
          'permission': permission,
          'available': true,
        };
      }
      return {
        'success': false,
        'service_enabled': true,
        'permission': permission,
        'available': false,
        'code': permission == 'deniedForever'
            ? 'permission_denied_forever'
            : 'permission_denied',
        'error': permission == 'deniedForever'
            ? 'Location permission is permanently denied. Enable it in system settings.'
            : 'Location permission was denied.',
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
        'code': 'unavailable',
      };
    }
  }

  /// App info page (needed after "Don't ask again" / deniedForever).
  Future<bool> openAppSettings() => _backend.openAppSettings();

  /// OS location-services page (needed when GPS is switched off).
  Future<bool> openLocationSettings() => _backend.openLocationSettings();

  /// Current coordinates, optionally reverse-geocoded to a place name.
  Future<Map<String, dynamic>> getCurrent({
    String accuracy = 'high',
    bool reverseGeocode = true,
    int timeoutSeconds = 15,
  }) async {
    try {
      final serviceEnabled = await _backend.isServiceEnabled();
      if (!serviceEnabled) {
        return {
          'success': false,
          'error': 'Location services are disabled on this device.',
          'code': 'service_disabled',
        };
      }

      var permission = await _backend.checkPermission();
      if (permission == 'denied') {
        permission = await _backend.requestPermission();
      }
      if (permission == 'denied') {
        return {
          'success': false,
          'error': 'Location permission was denied.',
          'code': 'permission_denied',
        };
      }
      if (permission == 'deniedForever') {
        return {
          'success': false,
          'error':
              'Location permission is permanently denied. Enable it in system settings.',
          'code': 'permission_denied_forever',
        };
      }
      if (permission != 'whileInUse' && permission != 'always') {
        return {
          'success': false,
          'error': 'Location permission is not granted ($permission).',
          'code': 'permission_denied',
        };
      }

      final timeout = Duration(seconds: timeoutSeconds.clamp(3, 60));
      final fix = await _backend.getCurrentPosition(
        accuracy: accuracy,
        timeout: timeout,
      );

      Map<String, dynamic>? place;
      String? placeError;
      if (reverseGeocode) {
        try {
          place = await _backend.reverseGeocode(fix.latitude, fix.longitude);
        } catch (e) {
          placeError = e.toString();
        }
      }

      return {
        'success': true,
        ...fix.toJson(),
        if (place != null) 'place': place,
        if (placeError != null) 'place_error': placeError,
      };
    } on TimeoutException catch (e) {
      return {
        'success': false,
        'error': 'Timed out waiting for a GPS fix: $e',
        'code': 'timeout',
      };
    } catch (e) {
      return {
        'success': false,
        'error': e.toString(),
        'code': 'unavailable',
      };
    }
  }
}

/// Default backend using `geolocator` + platform geocoder (no API key).
class GeolocatorLocationBackend implements LocationBackend {
  @override
  Future<bool> isServiceEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<String> checkPermission() async =>
      _permissionName(await Geolocator.checkPermission());

  @override
  Future<String> requestPermission() async =>
      _permissionName(await Geolocator.requestPermission());

  @override
  Future<bool> openAppSettings() => Geolocator.openAppSettings();

  @override
  Future<bool> openLocationSettings() => Geolocator.openLocationSettings();

  @override
  Future<LocationFix> getCurrentPosition({
    required String accuracy,
    required Duration timeout,
  }) async {
    final position = await Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
        accuracy: _accuracyFrom(accuracy),
        timeLimit: timeout,
      ),
    );
    return LocationFix(
      latitude: position.latitude,
      longitude: position.longitude,
      accuracyM: position.accuracy.isFinite ? position.accuracy : null,
      altitudeM: position.altitude.isFinite ? position.altitude : null,
      heading: position.heading.isFinite ? position.heading : null,
      speedMps: position.speed.isFinite ? position.speed : null,
      timestamp: position.timestamp,
      isMocked: position.isMocked,
    );
  }

  @override
  Future<Map<String, dynamic>?> reverseGeocode(
    double latitude,
    double longitude,
  ) async {
    final marks = await geo.placemarkFromCoordinates(latitude, longitude);
    if (marks.isEmpty) return null;
    final p = marks.first;
    final map = <String, dynamic>{
      if (_nonEmpty(p.name)) 'name': p.name,
      if (_nonEmpty(p.street)) 'street': p.street,
      if (_nonEmpty(p.subLocality)) 'sub_locality': p.subLocality,
      if (_nonEmpty(p.locality)) 'locality': p.locality,
      if (_nonEmpty(p.subAdministrativeArea))
        'sub_administrative_area': p.subAdministrativeArea,
      if (_nonEmpty(p.administrativeArea))
        'administrative_area': p.administrativeArea,
      if (_nonEmpty(p.postalCode)) 'postal_code': p.postalCode,
      if (_nonEmpty(p.country)) 'country': p.country,
      if (_nonEmpty(p.isoCountryCode)) 'iso_country_code': p.isoCountryCode,
    };
    return map.isEmpty ? null : map;
  }

  static bool _nonEmpty(String? value) => value != null && value.trim().isNotEmpty;

  static String _permissionName(LocationPermission permission) {
    switch (permission) {
      case LocationPermission.denied:
        return 'denied';
      case LocationPermission.deniedForever:
        return 'deniedForever';
      case LocationPermission.whileInUse:
        return 'whileInUse';
      case LocationPermission.always:
        return 'always';
      case LocationPermission.unableToDetermine:
        return 'unableToDetermine';
    }
  }

  static LocationAccuracy _accuracyFrom(String value) {
    switch (value) {
      case 'lowest':
        return LocationAccuracy.lowest;
      case 'low':
        return LocationAccuracy.low;
      case 'medium':
        return LocationAccuracy.medium;
      case 'best':
        return LocationAccuracy.best;
      case 'bestForNavigation':
        return LocationAccuracy.bestForNavigation;
      case 'high':
      default:
        return LocationAccuracy.high;
    }
  }
}
