import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_logger.dart';

abstract final class PlatformPermissions {
  static const MethodChannel _channel = MethodChannel('sputni/permissions');

  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<bool> requestBackgroundLocationAccess() async {
    if (!_isAndroid) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>(
            'requestBackgroundLocationAccess',
          ) ??
          false;
    } on PlatformException catch (error, stackTrace) {
      AppLogger.error(
        'Failed to request background location access',
        error,
        stackTrace,
      );
      return false;
    }
  }

  static Future<bool> requestNotificationAccess() async {
    if (!_isAndroid) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>('requestNotificationAccess') ??
          false;
    } on PlatformException catch (error, stackTrace) {
      AppLogger.error(
        'Failed to request notification access',
        error,
        stackTrace,
      );
      return false;
    }
  }
}
