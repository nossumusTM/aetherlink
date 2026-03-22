import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../widgets/pairing_panel.dart';

class SavedPairingLink {
  const SavedPairingLink({
    required this.payload,
    required this.lastUsedAt,
    this.launchRole,
    this.peerPayload,
  });

  final String payload;
  final DateTime lastUsedAt;
  final String? launchRole;
  final String? peerPayload;

  Map<String, dynamic> toMap() {
    return {
      'payload': payload,
      'lastUsedAt': lastUsedAt.millisecondsSinceEpoch,
      if (launchRole != null && launchRole!.isNotEmpty) 'launchRole': launchRole,
      if (peerPayload != null && peerPayload!.isNotEmpty) 'peerPayload': peerPayload,
    };
  }

  static SavedPairingLink? fromMap(Map<String, dynamic> map) {
    final payload = (map['payload'] as String?)?.trim();
    if (payload == null || payload.isEmpty) {
      return null;
    }

    final lastUsedAtMillis = map['lastUsedAt'] as int?;
    final launchRole = (map['launchRole'] as String?)?.trim();
    final peerPayload = (map['peerPayload'] as String?)?.trim();
    return SavedPairingLink(
      payload: payload,
      lastUsedAt: lastUsedAtMillis == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.fromMillisecondsSinceEpoch(lastUsedAtMillis),
      launchRole: launchRole == null || launchRole.isEmpty ? null : launchRole,
      peerPayload:
          peerPayload == null || peerPayload.isEmpty ? null : peerPayload,
    );
  }
}

abstract final class PairedDevicesStorage {
  static const _pairedDevicesKey = 'sputni.paired_devices.v1';
  static const _legacyPairedDevicesKey = 'teleck.paired_devices.v1';
  static const _maxSavedLinks = 20;

  static Future<List<SavedPairingLink>> loadAll() async {
    final preferences = await SharedPreferences.getInstance();
    final rawValue = preferences.getString(_pairedDevicesKey) ??
        preferences.getString(_legacyPairedDevicesKey);
    if (rawValue == null || rawValue.isEmpty) {
      return const [];
    }

    try {
      final decoded = jsonDecode(rawValue);
      if (decoded is! List) {
        return const [];
      }

      final links = decoded
          .whereType<Map>()
          .map((item) => SavedPairingLink.fromMap(item.cast<String, dynamic>()))
          .whereType<SavedPairingLink>()
          .toList(growable: false);

      links.sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
      return links;
    } catch (_) {
      return const [];
    }
  }

  static Future<void> savePayload(
    String payload, {
    String? launchRole,
    String? peerPayload,
  }) async {
    final trimmedPayload = payload.trim();
    if (trimmedPayload.isEmpty) {
      return;
    }

    final preferences = await SharedPreferences.getInstance();
    final existing = await loadAll();
    final normalizedLaunchRole = launchRole?.trim().toLowerCase();
    final normalizedPeerPayload = peerPayload?.trim();
    final identityKey = _payloadIdentityKey(
      trimmedPayload,
      launchRole: normalizedLaunchRole,
      peerPayload: normalizedPeerPayload,
    );
    final updated = <SavedPairingLink>[
      SavedPairingLink(
        payload: trimmedPayload,
        lastUsedAt: DateTime.now(),
        launchRole: normalizedLaunchRole,
        peerPayload: normalizedPeerPayload,
      ),
      ...existing.where(
        (item) =>
            _payloadIdentityKey(
              item.payload,
              launchRole: item.launchRole,
              peerPayload: item.peerPayload,
            ) !=
            identityKey,
      ),
    ];

    await preferences.setString(
      _pairedDevicesKey,
      jsonEncode(
        updated.take(_maxSavedLinks).map((item) => item.toMap()).toList(),
      ),
    );
  }

  static Future<void> removePayload(
    String payload, {
    String? launchRole,
    String? peerPayload,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final existing = await loadAll();
    final identityKey = _payloadIdentityKey(
      payload,
      launchRole: launchRole?.trim().toLowerCase(),
      peerPayload: peerPayload?.trim(),
    );
    final updated = existing
        .where(
          (item) =>
              _payloadIdentityKey(
                item.payload,
                launchRole: item.launchRole,
                peerPayload: item.peerPayload,
              ) !=
              identityKey,
        )
        .toList();

    await preferences.setString(
      _pairedDevicesKey,
      jsonEncode(updated.map((item) => item.toMap()).toList()),
    );
  }

  static String _payloadIdentityKey(
    String payload, {
    String? launchRole,
    String? peerPayload,
  }) {
    final pairingData = parsePairingPayload(peerPayload?.trim().isNotEmpty == true
        ? peerPayload!
        : payload);
    final deviceId = pairingData?.deviceId?.trim();
    final role = pairingData?.role?.trim().toLowerCase();
    final normalizedLaunchRole = launchRole?.trim().toLowerCase() ?? 'auto';
    if (deviceId != null && deviceId.isNotEmpty) {
      return '$deviceId|${role ?? 'unknown'}|$normalizedLaunchRole';
    }

    return '${payload.trim()}|$normalizedLaunchRole';
  }
}
