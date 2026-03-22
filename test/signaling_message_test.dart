import 'package:sputni/signaling/signaling_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SignalingMessage serialization', () {
    test('round-trips offer payload', () {
      const message = SignalingMessage(
        type: SignalingMessageType.offer,
        payload: {'type': 'offer', 'sdp': 'abc'},
      );

      final decoded = SignalingMessage.decode(message.encode());

      expect(decoded.type, SignalingMessageType.offer);
      expect(decoded.payload['sdp'], 'abc');
    });

    test('throws on unknown type', () {
      expect(
        () => SignalingMessage.decode('{"type":"unknown","payload":{}}'),
        throwsFormatException,
      );
    });
  });
}
