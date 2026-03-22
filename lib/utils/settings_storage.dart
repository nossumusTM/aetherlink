import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../config/stream_settings.dart';

enum PersistedSettingsScope { camera, monitor }

abstract final class SettingsStorage {
  static const _cameraSettingsKey = 'sputni.camera_settings.v1';
  static const _monitorSettingsKey = 'sputni.monitor_settings.v1';
  static const _legacyCameraSettingsKey = 'teleck.camera_settings.v1';
  static const _legacyMonitorSettingsKey = 'teleck.monitor_settings.v1';

  static Future<StreamSettings> load(
    PersistedSettingsScope scope, {
    required StreamSettings fallback,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final rawValue = preferences.getString(_keyFor(scope)) ??
        preferences.getString(_legacyKeyFor(scope));
    if (rawValue == null || rawValue.isEmpty) {
      return fallback;
    }

    try {
      final decoded = jsonDecode(rawValue);
      if (decoded is! Map<String, dynamic>) {
        return fallback;
      }
      return StreamSettings.fromPersistenceMap(decoded, fallback: fallback);
    } catch (_) {
      return fallback;
    }
  }

  static Future<void> save(
    PersistedSettingsScope scope,
    StreamSettings settings,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _keyFor(scope),
      jsonEncode(settings.toPersistenceMap()),
    );
  }

  static String _keyFor(PersistedSettingsScope scope) {
    switch (scope) {
      case PersistedSettingsScope.camera:
        return _cameraSettingsKey;
      case PersistedSettingsScope.monitor:
        return _monitorSettingsKey;
    }
  }

  static String _legacyKeyFor(PersistedSettingsScope scope) {
    switch (scope) {
      case PersistedSettingsScope.camera:
        return _legacyCameraSettingsKey;
      case PersistedSettingsScope.monitor:
        return _legacyMonitorSettingsKey;
    }
  }
}
