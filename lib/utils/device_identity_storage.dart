import 'package:shared_preferences/shared_preferences.dart';

import 'room_security.dart';

abstract final class DeviceIdentityStorage {
  static const _deviceIdKey = 'sputni.device_id.v1';
  static const _roleSecretKeyPrefix = 'sputni.role_secret.v1.';

  static Future<String> loadOrCreateDeviceId() async {
    final preferences = await SharedPreferences.getInstance();
    final existingValue = preferences.getString(_deviceIdKey)?.trim();
    if (existingValue != null && existingValue.isNotEmpty) {
      return existingValue;
    }

    final generatedValue =
        generateSecureRoomToken().replaceFirst('enc_', 'dev_');
    await preferences.setString(_deviceIdKey, generatedValue);
    return generatedValue;
  }

  static Future<String> roomIdForRole(String role) async {
    final deviceId = await loadOrCreateDeviceId();
    return secureRoomToken('device:$deviceId:${role.trim().toLowerCase()}');
  }

  static Future<String> pairingSecretForRole(String role) async {
    final preferences = await SharedPreferences.getInstance();
    final normalizedRole = role.trim().toLowerCase();
    final key = '$_roleSecretKeyPrefix$normalizedRole';
    final existingValue = preferences.getString(key)?.trim();
    if (existingValue != null && existingValue.isNotEmpty) {
      return existingValue;
    }

    final generatedValue =
        generateSecureRoomToken().replaceFirst('enc_', 'pair_');
    await preferences.setString(key, generatedValue);
    return generatedValue;
  }
}
