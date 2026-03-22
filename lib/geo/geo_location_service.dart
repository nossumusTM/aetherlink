import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'geo_models.dart';
import 'geo_settings.dart';

class GeoLocationService {
  StreamSubscription<Position>? _subscription;
  Timer? _pollTimer;
  GeoSettings? _settings;
  void Function(GeoPoint point)? _onPoint;
  bool _isRunning = false;
  bool _restartScheduled = false;
  bool _isPolling = false;
  DateTime? _lastDeliveredPointAt;

  Future<void> start({
    required GeoSettings settings,
    required void Function(GeoPoint point) onPoint,
  }) async {
    _settings = settings;
    _onPoint = onPoint;
    _isRunning = true;

    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      throw StateError('Location services are disabled');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (settings.backgroundTracking &&
        permission == LocationPermission.whileInUse &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError('Location permission denied');
    }

    if (settings.keepAwake) {
      await WakelockPlus.enable();
    } else {
      await WakelockPlus.disable();
    }

    try {
      final currentPosition = await Geolocator.getCurrentPosition(
        locationSettings: _buildLocationSettings(settings),
      );
      _lastDeliveredPointAt = DateTime.now();
      onPoint(_toGeoPoint(currentPosition, settings));
    } catch (_) {
      // Keep the live stream running even if the one-shot lookup is unavailable.
    }

    await _subscription?.cancel();
    _subscription = null;
    _subscription = Geolocator.getPositionStream(
      locationSettings: _buildLocationSettings(settings),
    ).listen(
      (position) {
        _lastDeliveredPointAt = DateTime.now();
        onPoint(_toGeoPoint(position, settings));
      },
      onError: (_, __) => _scheduleRestart(),
      onDone: _scheduleRestart,
    );

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      Duration(seconds: math.max(settings.updateIntervalSeconds * 2, 15)),
      (_) => _pollCurrentPositionIfStale(),
    );
  }

  Future<void> stop() async {
    _isRunning = false;
    _lastDeliveredPointAt = null;
    await _subscription?.cancel();
    _subscription = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    await WakelockPlus.disable();
  }

  Future<void> _pollCurrentPositionIfStale() async {
    if (!_isRunning || _isPolling) {
      return;
    }

    final settings = _settings;
    final onPoint = _onPoint;
    if (settings == null || onPoint == null) {
      return;
    }

    final lastDeliveredPointAt = _lastDeliveredPointAt;
    final staleAfter = Duration(
      seconds: math.max(settings.updateIntervalSeconds * 3, 20),
    );
    if (lastDeliveredPointAt != null &&
        DateTime.now().difference(lastDeliveredPointAt) < staleAfter) {
      return;
    }

    _isPolling = true;
    try {
      final currentPosition = await Geolocator.getCurrentPosition(
        locationSettings: _buildLocationSettings(settings),
      );
      _lastDeliveredPointAt = DateTime.now();
      onPoint(_toGeoPoint(currentPosition, settings));
    } catch (_) {
      // Keep the background tracking loop alive even if a one-shot poll fails.
    } finally {
      _isPolling = false;
    }
  }

  void _scheduleRestart() {
    if (!_isRunning || _restartScheduled) {
      return;
    }

    final settings = _settings;
    final onPoint = _onPoint;
    if (settings == null || onPoint == null) {
      return;
    }

    _restartScheduled = true;
    Future<void>.delayed(const Duration(seconds: 2), () async {
      _restartScheduled = false;
      if (!_isRunning) {
        return;
      }
      try {
        await start(settings: settings, onPoint: onPoint);
      } catch (_) {
        _scheduleRestart();
      }
    });
  }

  LocationSettings _buildLocationSettings(GeoSettings settings) {
    final accuracy = settings.highAccuracy
        ? LocationAccuracy.bestForNavigation
        : LocationAccuracy.medium;

    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: settings.distanceFilterMeters,
        intervalDuration: Duration(seconds: settings.updateIntervalSeconds),
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: 'Sputni Geo tracking active',
          notificationText:
              'Sharing your position in the background for paired devices.',
          enableWakeLock: settings.keepAwake,
          setOngoing: settings.backgroundTracking,
        ),
      );
    }

    if (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return AppleSettings(
        accuracy: accuracy,
        distanceFilter: settings.distanceFilterMeters,
        activityType: ActivityType.otherNavigation,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: settings.backgroundTracking,
        allowBackgroundLocationUpdates: settings.backgroundTracking,
      );
    }

    return LocationSettings(
      accuracy: accuracy,
      distanceFilter: settings.distanceFilterMeters,
    );
  }

  GeoPoint _toGeoPoint(Position position, GeoSettings settings) {
    return GeoPoint(
      latitude: position.latitude,
      longitude: position.longitude,
      timestampMillis: position.timestamp.millisecondsSinceEpoch,
      accuracy: position.accuracy,
      altitude: position.altitude,
      speed: settings.shareSpeed ? position.speed : null,
      heading: settings.shareHeading ? position.heading : null,
    );
  }
}
