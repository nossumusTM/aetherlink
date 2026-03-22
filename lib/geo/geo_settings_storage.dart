import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'geo_settings.dart';

enum GeoSettingsScope { position, monitor }

abstract final class GeoSettingsStorage {
  static const _positionKey = 'sputni.geo.position_settings.v1';
  static const _monitorKey = 'sputni.geo.monitor_settings.v1';

  static Future<GeoSettings> load(
    GeoSettingsScope scope, {
    required GeoSettings fallback,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final rawValue = preferences.getString(_keyFor(scope));
    if (rawValue == null || rawValue.isEmpty) {
      return fallback;
    }

    try {
      final decoded = jsonDecode(rawValue);
      if (decoded is! Map<String, dynamic>) {
        return fallback;
      }
      return GeoSettings.fromMap(decoded, fallback: fallback);
    } catch (_) {
      return fallback;
    }
  }

  static Future<void> save(GeoSettingsScope scope, GeoSettings settings) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_keyFor(scope), jsonEncode(settings.toMap()));
  }

  static String _keyFor(GeoSettingsScope scope) {
    switch (scope) {
      case GeoSettingsScope.position:
        return _positionKey;
      case GeoSettingsScope.monitor:
        return _monitorKey;
    }
  }
}
