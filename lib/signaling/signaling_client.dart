import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../crypto/pairing_cipher.dart';
import '../utils/app_logger.dart';
import 'signaling_message.dart';

typedef MessageCallback = void Function(SignalingMessage message);
typedef ErrorCallback = void Function(Object error, [StackTrace? stackTrace]);
typedef VoidCallback = void Function();

class SignalingClient {
  SignalingClient({
    required this.serverUrl,
    this.cipher,
    this.reconnectDelay = const Duration(seconds: 2),
    this.maxReconnectAttempts = 0,
  });

  final String serverUrl;
  final PairingCipher? cipher;
  final Duration reconnectDelay;
  final int maxReconnectAttempts;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  int _reconnectAttempts = 0;
  bool _manualClose = false;
  bool _isConnecting = false;
  Future<void> _pendingSend = Future<void>.value();

  MessageCallback? onMessage;
  VoidCallback? onConnected;
  VoidCallback? onDisconnected;
  ErrorCallback? onError;

  bool get isConnected => _channel != null;
  bool get isConnecting => _isConnecting;

  Future<void> connect() async {
    if (_channel != null || _isConnecting) {
      return;
    }

    _manualClose = false;
    _isConnecting = true;
    try {
      _channel = WebSocketChannel.connect(Uri.parse(serverUrl));
      _subscription = _channel!.stream.listen(
        _handleRawMessage,
        onError: (Object error, StackTrace stackTrace) {
          AppLogger.error('WebSocket stream error', error, stackTrace);
          onError?.call(error, stackTrace);
          _handleDisconnect();
        },
        onDone: _handleDisconnect,
      );
      _reconnectAttempts = 0;
      onConnected?.call();
    } catch (error, stackTrace) {
      AppLogger.error(
          'Failed to connect to signaling server', error, stackTrace);
      onError?.call(error, stackTrace);
      _scheduleReconnect();
    } finally {
      _isConnecting = false;
    }
  }

  void send(SignalingMessage message) {
    _pendingSend = _pendingSend.catchError((_) {}).then((_) => _send(message));
  }

  Future<void> _send(SignalingMessage message) async {
    final channel = _channel;
    if (channel == null) {
      onError?.call(StateError('Cannot send before signaling is connected'));
      return;
    }

    final encodedMessage = await _encodeMessage(message);
    channel.sink.add(encodedMessage);
  }

  Future<void> disconnect() async {
    _manualClose = true;
    await _subscription?.cancel();
    await _channel?.sink.close();
    _channel = null;
    onDisconnected?.call();
  }

  void _handleRawMessage(dynamic data) {
    if (data is! String) {
      onError?.call(FormatException(
          'Unexpected signaling payload type: ${data.runtimeType}'));
      return;
    }

    unawaited(_decodeAndDispatch(data));
  }

  Future<void> _decodeAndDispatch(String data) async {
    try {
      final message = await _decodeMessage(data);
      onMessage?.call(message);
    } catch (error, stackTrace) {
      AppLogger.error('Failed to parse signaling message', error, stackTrace);
      onError?.call(error, stackTrace);
    }
  }

  void _handleDisconnect() {
    _subscription?.cancel();
    _subscription = null;
    _channel = null;
    _isConnecting = false;
    onDisconnected?.call();

    if (!_manualClose) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (maxReconnectAttempts > 0 &&
        _reconnectAttempts >= maxReconnectAttempts) {
      onError?.call(StateError('Max reconnect attempts reached'));
      return;
    }
    _reconnectAttempts += 1;
    Future<void>.delayed(reconnectDelay, connect);
  }

  Future<String> _encodeMessage(SignalingMessage message) async {
    if (cipher == null ||
        message.type == SignalingMessageType.join ||
        message.type == SignalingMessageType.secureSignal) {
      return message.encode();
    }

    final encryptedPayload = await cipher!.encryptObject(message.toJson());
    return SignalingMessage(
      type: SignalingMessageType.secureSignal,
      payload: encryptedPayload,
    ).encode();
  }

  Future<SignalingMessage> _decodeMessage(String rawMessage) async {
    final decoded = SignalingMessage.decode(rawMessage);
    if (decoded.type != SignalingMessageType.secureSignal || cipher == null) {
      return decoded;
    }

    final clearPayload = await cipher!.decryptObject(decoded.payload);
    return SignalingMessage.fromJson(clearPayload);
  }
}
