import 'dart:convert';

import 'package:http/http.dart' as http;

class PairingPresenceStatus {
  const PairingPresenceStatus({
    required this.online,
    required this.activePeers,
  });

  final bool online;
  final int activePeers;
}

abstract final class PairingPresenceService {
  static Future<PairingPresenceStatus?> fetchPresence({
    required String signalingUrl,
    required String roomId,
    String? deviceId,
  }) async {
    final uri = _presenceUriFor(
      signalingUrl: signalingUrl,
      roomId: roomId,
      deviceId: deviceId,
    );
    if (uri == null) {
      return null;
    }

    try {
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      return PairingPresenceStatus(
        online: decoded['online'] == true,
        activePeers: (decoded['activePeers'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  static Uri? _presenceUriFor({
    required String signalingUrl,
    required String roomId,
    String? deviceId,
  }) {
    final signalingUri = Uri.tryParse(signalingUrl);
    if (signalingUri == null ||
        signalingUri.scheme.isEmpty ||
        signalingUri.host.isEmpty) {
      return null;
    }

    final scheme = switch (signalingUri.scheme) {
      'wss' => 'https',
      'ws' => 'http',
      _ => signalingUri.scheme,
    };

    return signalingUri.replace(
      scheme: scheme,
      path: '/presence',
      queryParameters: {
        'roomId': roomId,
        if (deviceId != null && deviceId.trim().isNotEmpty)
          'deviceId': deviceId,
      },
    );
  }
}
