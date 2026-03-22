import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/app_logger.dart';

class GeoBackgroundRelayConfig {
  const GeoBackgroundRelayConfig({
    required this.roomId,
    required this.signalingUrl,
    required this.updateIntervalSeconds,
    required this.distanceFilterMeters,
    required this.highAccuracy,
    required this.shareHeading,
    required this.shareSpeed,
    required this.keepAwake,
    this.deviceId,
    this.keyMaterial,
  });

  final String roomId;
  final String signalingUrl;
  final String? deviceId;
  final String? keyMaterial;
  final int updateIntervalSeconds;
  final int distanceFilterMeters;
  final bool highAccuracy;
  final bool shareHeading;
  final bool shareSpeed;
  final bool keepAwake;

  Map<String, Object?> toMap() => {
        'roomId': roomId,
        'signalingUrl': signalingUrl,
        'deviceId': deviceId,
        'keyMaterial': keyMaterial,
        'updateIntervalSeconds': updateIntervalSeconds,
        'distanceFilterMeters': distanceFilterMeters,
        'highAccuracy': highAccuracy,
        'shareHeading': shareHeading,
        'shareSpeed': shareSpeed,
        'keepAwake': keepAwake,
      };
}

abstract final class GeoBackgroundRelay {
  static const MethodChannel _channel = MethodChannel('sputni/geo_background');

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> activate(GeoBackgroundRelayConfig config) async {
    if (!isSupported) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('activate', config.toMap());
    } on PlatformException catch (error, stackTrace) {
      AppLogger.error(
          'Failed to activate geo background relay', error, stackTrace);
    }
  }

  static Future<void> deactivate() async {
    if (!isSupported) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('deactivate');
    } on PlatformException catch (error, stackTrace) {
      AppLogger.error(
          'Failed to deactivate geo background relay', error, stackTrace);
    }
  }

  static Future<void> stop() async {
    if (!isSupported) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (error, stackTrace) {
      AppLogger.error('Failed to stop geo background relay', error, stackTrace);
    }
  }
}
