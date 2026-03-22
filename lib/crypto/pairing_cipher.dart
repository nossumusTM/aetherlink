import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

class PairingCipher {
  PairingCipher._(this._secretKey);

  static final AesGcm _algorithm = AesGcm.with256bits();
  static final Hkdf _keyDerivation = Hkdf(
    hmac: Hmac.sha256(),
    outputLength: 32,
  );

  final SecretKey _secretKey;

  static Future<PairingCipher> fromKeyMaterial(String keyMaterial) async {
    final materialBytes = utf8.encode(keyMaterial.trim());
    if (materialBytes.isEmpty) {
      throw ArgumentError.value(
        keyMaterial,
        'keyMaterial',
        'Pairing key material cannot be empty',
      );
    }

    final secretKey = await _keyDerivation.deriveKey(
      secretKey: SecretKey(materialBytes),
      nonce: const [115, 112, 117, 116, 110, 105],
      info: utf8.encode('sputni-secure-channel-v1'),
    );
    return PairingCipher._(secretKey);
  }

  Future<Map<String, dynamic>> encryptObject(
    Map<String, dynamic> payload,
  ) async {
    final random = Random.secure();
    final nonce = List<int>.generate(12, (_) => random.nextInt(256));
    final cleartext = utf8.encode(jsonEncode(payload));
    final secretBox = await _algorithm.encrypt(
      cleartext,
      secretKey: _secretKey,
      nonce: nonce,
    );

    return {
      'nonce': base64UrlEncode(secretBox.nonce),
      'ciphertext': base64UrlEncode(secretBox.cipherText),
      'mac': base64UrlEncode(secretBox.mac.bytes),
    };
  }

  Future<Map<String, dynamic>> decryptObject(
    Map<String, dynamic> payload,
  ) async {
    final nonce = base64Url.decode(payload['nonce'] as String);
    final ciphertext = base64Url.decode(payload['ciphertext'] as String);
    final mac = Mac(base64Url.decode(payload['mac'] as String));
    final secretBox = SecretBox(ciphertext, nonce: nonce, mac: mac);
    final cleartext = await _algorithm.decrypt(
      secretBox,
      secretKey: _secretKey,
    );
    final decoded = jsonDecode(utf8.decode(cleartext));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
          'Encrypted payload did not contain an object');
    }
    return decoded;
  }
}
