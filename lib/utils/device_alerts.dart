import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_logger.dart';

abstract final class DeviceAlertIds {
  static const geoFeedInterrupted = 3101;
  static const geoFeedStopped = 3102;
  static const geoFeedAppSwiped = 3103;
  static const cameraFeedStopped = 3201;
  static const cameraFeedInterrupted = 3202;
}

abstract final class DeviceAlerts {
  static const MethodChannel _channel = MethodChannel('sputni/alerts');

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!isSupported) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('showAlert', {
        'id': id,
        'title': title,
        'body': body,
      });
    } on PlatformException catch (error, stackTrace) {
      AppLogger.error('Failed to show device alert', error, stackTrace);
    }
  }
}
