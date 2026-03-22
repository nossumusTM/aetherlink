import 'package:flutter_test/flutter_test.dart';
import 'package:sputni/config/app_config.dart';

void main() {
  group('AppConfig ICE server configuration', () {
    test('keeps STUN primary when TURN is excluded', () {
      const config = AppConfig(
        signalingUrl: 'wss://signal.teleck.live/ws',
        enableTurn: true,
        stunUrls: [
          'stun:stun1.example.com:3478',
          'stun:stun2.example.com:3478',
        ],
        turnUrls: [
          'turn:turn.teleck.live:3478?transport=udp',
          'turn:turn.teleck.live:3478?transport=tcp',
          'turns:turn.teleck.live:5349?transport=tcp',
        ],
        turnUsername: 'user',
        turnCredential: 'credential',
      );

      expect(
        config.iceServers(includeTurn: false, useMultipleStunServers: true),
        [
          {
            'urls': [
              'stun:stun1.example.com:3478',
              'stun:stun2.example.com:3478',
            ],
          },
        ],
      );
    });

    test('adds the Sputni TURN relay pool for fallback', () {
      const config = AppConfig(
        signalingUrl: 'wss://signal.teleck.live/ws',
        enableTurn: true,
        stunUrls: ['stun:stun1.example.com:3478'],
        turnUrls: [
          'turn:turn.teleck.live:3478?transport=udp',
          'turn:turn.teleck.live:3478?transport=tcp',
          'turns:turn.teleck.live:5349?transport=tcp',
        ],
        turnUsername: 'user',
        turnCredential: 'credential',
      );

      expect(config.hasTurnServer, isTrue);
      expect(
        config.iceServers(includeTurn: true, useMultipleStunServers: true),
        [
          {
            'urls': ['stun:stun1.example.com:3478'],
          },
          {
            'urls': [
              'turn:turn.teleck.live:3478?transport=udp',
              'turn:turn.teleck.live:3478?transport=tcp',
              'turns:turn.teleck.live:5349?transport=tcp',
            ],
            'username': 'user',
            'credential': 'credential',
          },
        ],
      );
    });

    test('requires credentials before enabling TURN fallback', () {
      const config = AppConfig(
        signalingUrl: 'wss://signal.teleck.live/ws',
        enableTurn: true,
        stunUrls: ['stun:stun1.example.com:3478'],
        turnUrls: ['turn:turn.teleck.live:3478?transport=udp'],
      );

      expect(config.hasTurnServer, isFalse);
      expect(
        config.iceServers(includeTurn: true, useMultipleStunServers: true),
        [
          {
            'urls': ['stun:stun1.example.com:3478'],
          },
        ],
      );
    });
  });
}
