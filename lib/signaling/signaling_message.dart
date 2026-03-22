import 'dart:convert';

enum SignalingMessageType {
  error,
  join,
  offer,
  answer,
  iceCandidate,
  control,
  data,
  secureSignal,
}

/// Typed signaling message contract exchanged over WebSocket.
///
/// Payload is intentionally generic, but each message type expects:
/// - join: {"roomId": "...", "role": "camera|monitor"}
/// - offer/answer: {"sdp": "...", "type": "offer|answer"}
/// - ice-candidate: {"candidate": "...", "sdpMid": "...", "sdpMLineIndex": 0}
/// - control: {"action": "start|stop|camera-ready|monitor-ready"}
/// - data: {"channel": "...", ...}
/// - secure-signal: {"nonce": "...", "ciphertext": "...", "mac": "..."}
class SignalingMessage {
  const SignalingMessage({
    required this.type,
    required this.payload,
  });

  final SignalingMessageType type;
  final Map<String, dynamic> payload;

  factory SignalingMessage.fromJson(Map<String, dynamic> json) {
    final rawType = json['type'] as String?;
    if (rawType == null) {
      throw const FormatException('Missing signaling type');
    }

    final type = _parseType(rawType);
    final payload = (json['payload'] as Map?)?.cast<String, dynamic>() ??
        <String, dynamic>{};

    return SignalingMessage(type: type, payload: payload);
  }

  Map<String, dynamic> toJson() => {
        'type': _typeToWire(type),
        'payload': payload,
      };

  String encode() => jsonEncode(toJson());

  static SignalingMessage decode(String data) {
    final json = jsonDecode(data) as Map<String, dynamic>;
    return SignalingMessage.fromJson(json);
  }

  static SignalingMessageType _parseType(String wireType) {
    switch (wireType) {
      case 'error':
        return SignalingMessageType.error;
      case 'join':
        return SignalingMessageType.join;
      case 'offer':
        return SignalingMessageType.offer;
      case 'answer':
        return SignalingMessageType.answer;
      case 'ice-candidate':
        return SignalingMessageType.iceCandidate;
      case 'control':
        return SignalingMessageType.control;
      case 'data':
        return SignalingMessageType.data;
      case 'secure-signal':
        return SignalingMessageType.secureSignal;
      default:
        throw FormatException('Unsupported signaling type: $wireType');
    }
  }

  static String _typeToWire(SignalingMessageType type) {
    switch (type) {
      case SignalingMessageType.error:
        return 'error';
      case SignalingMessageType.join:
        return 'join';
      case SignalingMessageType.offer:
        return 'offer';
      case SignalingMessageType.answer:
        return 'answer';
      case SignalingMessageType.iceCandidate:
        return 'ice-candidate';
      case SignalingMessageType.control:
        return 'control';
      case SignalingMessageType.data:
        return 'data';
      case SignalingMessageType.secureSignal:
        return 'secure-signal';
    }
  }
}
