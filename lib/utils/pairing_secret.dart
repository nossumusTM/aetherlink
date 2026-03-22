import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../widgets/pairing_panel.dart';

String deriveRoomKeyMaterial(String rawRoomId) {
  final normalized = rawRoomId.trim();
  if (normalized.isEmpty) {
    throw ArgumentError.value(rawRoomId, 'rawRoomId', 'Room ID cannot be empty');
  }

  return 'room:${base64UrlEncode(sha256.convert(utf8.encode(normalized)).bytes)}';
}

String? resolvePairingKeyMaterial({
  required PairingPayloadData? pairingPayloadData,
  required String rawRoomId,
}) {
  final payloadSecret = pairingPayloadData?.secret?.trim();
  if (payloadSecret != null && payloadSecret.isNotEmpty) {
    return payloadSecret;
  }

  final payloadRoomId = pairingPayloadData?.roomId.trim();
  if (payloadRoomId != null && payloadRoomId.isNotEmpty) {
    return 'payload:$payloadRoomId';
  }

  final normalizedRoomId = rawRoomId.trim();
  if (normalizedRoomId.isEmpty) {
    return null;
  }

  return deriveRoomKeyMaterial(normalizedRoomId);
}
