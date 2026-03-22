import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../config/app_config.dart';
import '../config/stream_settings.dart';
import '../crypto/pairing_cipher.dart';
import '../signaling/control_actions.dart';
import '../signaling/signaling_client.dart';
import '../signaling/signaling_message.dart';
import '../ui/azure_theme.dart';
import '../utils/app_logger.dart';
import '../utils/device_identity_storage.dart';
import '../utils/paired_devices_storage.dart';
import '../utils/pairing_secret.dart';
import '../utils/platform_permissions.dart';
import '../utils/room_security.dart';
import '../webrtc/rtc_manager.dart';
import '../widgets/app_shell_ui.dart';
import '../widgets/pairing_panel.dart';
import 'geo_background_relay.dart';
import 'geo_location_service.dart';
import 'geo_map_surface.dart';
import 'geo_models.dart';
import 'geo_settings.dart';
import 'geo_settings_sheet.dart';
import 'geo_settings_storage.dart';

class GeoPositionScreen extends StatefulWidget {
  const GeoPositionScreen({
    super.key,
    this.initialPairingLink,
    this.autoStartOnLoad = false,
  });

  final String? initialPairingLink;
  final bool autoStartOnLoad;

  @override
  State<GeoPositionScreen> createState() => _GeoPositionScreenState();
}

class _GeoPositionScreenState extends State<GeoPositionScreen>
    with WidgetsBindingObserver {
  static const Duration _relayPromotionDelay = Duration(seconds: 6);

  final _roomController = TextEditingController();
  final _pairingLinkController = TextEditingController();
  final GeoLocationService _locationService = GeoLocationService();

  late final AppConfig _config;
  GeoSettings _settings = GeoSettings.positionDefaults;
  SignalingClient? _signaling;
  RtcManager? _rtc;
  Timer? _offerRetryTimer;
  Timer? _relayHeartbeatTimer;
  Timer? _relayPromotionTimer;
  bool _isSendingOffer = false;
  bool _awaitingAnswer = false;
  String _status = 'Standby';
  String _connectionReport = 'Data channel first · waiting to start';
  PairingMethod _pairingMethod = PairingMethod.qrCode;
  String? _qrPairingRoomId;
  String? _localDeviceId;
  String? _qrPairingSecret;
  bool _hasTriggeredInitialAutoStart = false;
  bool _isQrModalVisible = false;
  BuildContext? _qrDialogContext;
  GeoPoint? _latestPoint;
  final List<GeoPoint> _history = [];
  bool _isDataChannelOpen = false;
  String _rtcDiagnostics = 'WebRTC route pending';
  Future<void> _locationTransition = Future<void>.value();
  bool _relayFallbackAllowed = false;
  bool _isAppInForeground = true;
  bool _backgroundRelayPermissionGranted = false;
  bool _isBackgroundRelayActive = false;
  bool _hasJoinedSignalingRoom = false;

  bool get _hasActiveSecureLink =>
      _isDataChannelOpen || _status == 'Secure link active';

  PairingPayloadData? get _pairingPayloadData {
    final value = _pairingLinkController.text.trim();
    if (value.isEmpty) return null;
    return parsePairingPayload(value);
  }

  String? get _pairingLinkErrorText {
    final value = _pairingLinkController.text.trim();
    if (value.isEmpty) return null;
    final payloadData = _pairingPayloadData;
    if (payloadData == null) {
      return 'Enter a valid Sputni pairing link';
    }
    return pairingPayloadCompatibilityError(
      payloadData: payloadData,
      expectedFamily: PairingFeatureFamily.geo,
    );
  }

  bool get _usesQrPairing => _pairingMethod == PairingMethod.qrCode;

  bool get _hasValidPairingSelection => _usesQrPairing
      ? _pairingLinkController.text.trim().isNotEmpty &&
          _pairingLinkErrorText == null
      : _roomController.text.trim().isNotEmpty;

  String get _resolvedRoomId {
    final pairedRoomId = _pairingPayloadData?.roomId;
    if (pairedRoomId != null && pairedRoomId.isNotEmpty) {
      return pairedRoomId;
    }
    final qrRoomId = _qrPairingRoomId;
    if (_usesQrPairing && qrRoomId != null && qrRoomId.isNotEmpty) {
      return qrRoomId;
    }
    return _roomController.text.trim();
  }

  String get _transmissionRoomId => secureRoomToken(_resolvedRoomId);

  String get _resolvedSignalingUrl =>
      _pairingPayloadData?.signalingUrl ?? _config.signalingUrl;

  String get _generatedQrPairingPayload => buildPairingPayload(
        roomId: _transmissionRoomId,
        signalingUrl: _resolvedSignalingUrl,
        role: 'geo-position',
        deviceId: _localDeviceId,
        secret: _qrPairingSecret,
      );

  String? get _ownPairingPayloadForSync {
    final roomId = _qrPairingRoomId?.trim();
    if (roomId == null || roomId.isEmpty) {
      return null;
    }

    final payload = _generatedQrPairingPayload.trim();
    return payload.isEmpty ? null : payload;
  }

  String get _savedPairingPayload {
    final payload = _pairingLinkController.text.trim();
    if (payload.isNotEmpty) {
      return payload;
    }
    return _generatedQrPairingPayload.trim();
  }

  void _seedOwnQrPairingPayload({bool force = false}) {
    final payload = _generatedQrPairingPayload.trim();
    if (payload.isEmpty) {
      return;
    }
    if (force || _pairingLinkController.text.trim().isEmpty) {
      _pairingLinkController.text = payload;
    }
  }

  StreamSettings _rtcTransportSettings() {
    return StreamSettings.monitorDefaults.copyWith(
      preferDirectP2P: _settings.preferDirectP2P,
      enableTurnFallback: _settings.enableTurnFallback,
      useMultipleStunServers: _settings.useMultipleStunServers,
      showConnectionReport: _settings.showConnectionReport,
    );
  }

  GeoBackgroundRelayConfig? _backgroundRelayConfig() {
    final roomId = _transmissionRoomId.trim();
    final signalingUrl = _resolvedSignalingUrl.trim();
    if (roomId.isEmpty || signalingUrl.isEmpty) {
      return null;
    }

    return GeoBackgroundRelayConfig(
      roomId: roomId,
      signalingUrl: signalingUrl,
      deviceId: _localDeviceId,
      keyMaterial: resolvePairingKeyMaterial(
        pairingPayloadData: _pairingPayloadData,
        rawRoomId: _roomController.text,
      ),
      updateIntervalSeconds: _settings.updateIntervalSeconds,
      distanceFilterMeters: _settings.distanceFilterMeters,
      highAccuracy: _settings.highAccuracy,
      shareHeading: _settings.shareHeading,
      shareSpeed: _settings.shareSpeed,
      keepAwake: _settings.keepAwake,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _config = AppConfig.fromEnvironment();
    final initialPairingLink = widget.initialPairingLink?.trim();
    if (initialPairingLink != null && initialPairingLink.isNotEmpty) {
      _pairingLinkController.text = initialPairingLink;
      _pairingMethod = PairingMethod.qrCode;
    }
    unawaited(_loadPairingIdentity());
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final settings = await GeoSettingsStorage.load(
      GeoSettingsScope.position,
      fallback: GeoSettings.positionDefaults,
    );
    if (!mounted) return;
    setState(() => _settings = settings);
    _maybeAutoStart();
  }

  Future<void> _loadPairingIdentity() async {
    final deviceId = await DeviceIdentityStorage.loadOrCreateDeviceId();
    final pairingRoomId =
        await DeviceIdentityStorage.roomIdForRole('geo-position');
    final pairingSecret =
        await DeviceIdentityStorage.pairingSecretForRole('geo-position');
    if (!mounted) return;
    setState(() {
      _localDeviceId = deviceId;
      _qrPairingRoomId = pairingRoomId;
      _qrPairingSecret = pairingSecret;
      if (_pairingMethod == PairingMethod.qrCode) {
        _seedOwnQrPairingPayload();
      }
    });
  }

  Future<PairingCipher?> _buildPairingCipher() async {
    final keyMaterial = resolvePairingKeyMaterial(
      pairingPayloadData: _pairingPayloadData,
      rawRoomId: _roomController.text,
    );
    if (keyMaterial == null || keyMaterial.isEmpty) {
      return null;
    }
    return PairingCipher.fromKeyMaterial(keyMaterial);
  }

  Future<void> _saveRemotePairingPayload(String? rawPayload) async {
    final payload = rawPayload?.trim();
    if (payload == null || payload.isEmpty) {
      return;
    }

    final pairingData = parsePairingPayload(payload);
    if (pairingData == null ||
        pairingData.role?.trim().toLowerCase() != 'geo-monitor' ||
        pairingPayloadCompatibilityError(
              payloadData: pairingData,
              expectedFamily: PairingFeatureFamily.geo,
            ) !=
            null) {
      return;
    }

    final remoteDeviceId = pairingData.deviceId?.trim();
    if (remoteDeviceId != null &&
        remoteDeviceId.isNotEmpty &&
        remoteDeviceId == _localDeviceId) {
      return;
    }

    await PairedDevicesStorage.savePayload(
      _savedPairingPayload,
      launchRole: 'geo-position',
      peerPayload: payload,
    );
  }

  void _sendOwnPairingPayload([SignalingClient? signalingOverride]) {
    if (!_usesQrPairing) {
      return;
    }

    final signaling = signalingOverride ?? _signaling;
    final payload = _ownPairingPayloadForSync;
    if (signaling == null ||
        !signaling.isConnected ||
        !_hasJoinedSignalingRoom ||
        payload == null) {
      return;
    }

    signaling.send(
      SignalingMessage(
        type: SignalingMessageType.control,
        payload: {
          'action': SignalingControlAction.pairingLinkSync,
          'pairingPayload': payload,
        },
      ),
    );
  }

  Future<void> _handlePairingMethodChange(PairingMethod method) async {
    setState(() {
      _pairingMethod = method;
      if (method == PairingMethod.roomId) {
        _pairingLinkController.clear();
      } else {
        _seedOwnQrPairingPayload(force: true);
      }
    });

    if (method == PairingMethod.roomId) {
      _dismissQrModalIfVisible();
    }
  }

  Future<void> _openQrCodeModal(String payload) {
    _isQrModalVisible = true;
    return showPairingQrCodeModal(
      context: context,
      payload: payload,
      title: 'QR pairing',
      subtitle: 'Scan this code on Geo Monitor to pair instantly.',
      onDialogReady: (dialogContext) => _qrDialogContext = dialogContext,
    ).whenComplete(() {
      _isQrModalVisible = false;
      _qrDialogContext = null;
    });
  }

  Future<void> _scanQrCodeLink() async {
    final scannedValue = await scanPairingPayloadValue(context);
    if (!mounted || scannedValue == null || scannedValue.isEmpty) return;
    final payloadData = parsePairingPayload(scannedValue);
    final compatibilityError = pairingPayloadCompatibilityError(
      payloadData: payloadData,
      expectedFamily: PairingFeatureFamily.geo,
    );
    if (payloadData == null || compatibilityError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            compatibilityError ?? 'Enter a valid Sputni pairing link',
          ),
        ),
      );
      return;
    }

    await PairedDevicesStorage.savePayload(
      scannedValue,
      launchRole: 'geo-position',
      peerPayload: scannedValue,
    );
    _pairingLinkController.text = scannedValue;
    setState(() => _pairingMethod = PairingMethod.qrCode);
  }

  Future<void> _startSharing() async {
    if (_signaling != null || _rtc != null) {
      return;
    }

    await _ensureLocationPermissionsForStart();

    final signaling = SignalingClient(
      serverUrl: _resolvedSignalingUrl,
      cipher: await _buildPairingCipher(),
    );
    final rtc = RtcManager(
      role: PeerRole.geoPosition,
      config: _config,
      settings: _rtcTransportSettings(),
    );

    signaling.onConnected = () {
      _hasJoinedSignalingRoom = false;
      if (mounted) {
        setState(() {
          if (!_hasActiveSecureLink) {
            _status = 'Session broker ready';
          }
          _updateConnectionReport();
        });
      }
      signaling.send(
        SignalingMessage(
          type: SignalingMessageType.join,
          payload: {
            'roomId': _transmissionRoomId,
            'role': 'geo-position',
            if (_localDeviceId != null) 'deviceId': _localDeviceId,
            if (_usesQrPairing && _ownPairingPayloadForSync != null)
              'pairingPayload': _ownPairingPayloadForSync,
          },
        ),
      );
    };

    signaling.onMessage = (message) async {
      if (message.type == SignalingMessageType.error) {
        final text = message.payload['message']?.toString();
        if (mounted && text != null && text.isNotEmpty) {
          setState(() => _status = text);
        }
      }
      if (message.type == SignalingMessageType.control &&
          message.payload['action'] == SignalingControlAction.sessionJoined) {
        _hasJoinedSignalingRoom = true;
        _sendGeoPositionReady(signaling);
        _sendOwnPairingPayload(signaling);
        unawaited(_sendLatestPointIfAvailable());
      }
      if (message.type == SignalingMessageType.join &&
          message.payload['role'] == 'geo-monitor') {
        _dismissQrModalIfVisible();
        await _saveRemotePairingPayload(
          message.payload['pairingPayload']?.toString(),
        );
        _sendOwnPairingPayload(signaling);
        _sendGeoPositionReady(signaling);
        _sendLatestPointIfAvailable();
        await _sendOfferIfPossible(
          rtc: rtc,
          signaling: signaling,
          reason: 'geo-monitor-joined',
        );
      }
      if (message.type == SignalingMessageType.control &&
          message.payload['action'] == SignalingControlAction.geoMonitorReady) {
        await _saveRemotePairingPayload(
          message.payload['pairingPayload']?.toString(),
        );
        _sendOwnPairingPayload(signaling);
        _sendLatestPointIfAvailable();
        await _sendOfferIfPossible(
          rtc: rtc,
          signaling: signaling,
          reason: 'geo-monitor-ready',
        );
      }
      if (message.type == SignalingMessageType.control &&
          message.payload['action'] == SignalingControlAction.pairingLinkSync) {
        await _saveRemotePairingPayload(
          message.payload['pairingPayload']?.toString(),
        );
      }
      if (message.type == SignalingMessageType.data) {
        _handleFallbackData(message.payload);
      }
      if (message.type == SignalingMessageType.answer) {
        _offerRetryTimer?.cancel();
        _offerRetryTimer = null;
        _awaitingAnswer = false;
      }
      await rtc.handleSignalingMessage(message);
    };

    signaling.onDisconnected = () {
      _hasJoinedSignalingRoom = false;
      _resetNegotiationState();
      if (mounted) {
        setState(() {
          if (_isBackgroundRelayActive) {
            _status = 'Background relay active';
          } else if (!_hasActiveSecureLink) {
            _status = 'Session closed';
          }
          _updateConnectionReport();
        });
      }
    };

    signaling.onError = (error, [stack]) {
      final shouldSurfaceAsPrimaryStatus =
          !_hasActiveSecureLink && !_isBackgroundRelayActive;
      if (mounted && shouldSurfaceAsPrimaryStatus) {
        setState(() => _status = 'Connection issue');
      }
      AppLogger.error('Geo position signaling error', error, stack);
    };

    rtc.onSignal = signaling.send;
    rtc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _offerRetryTimer?.cancel();
        _offerRetryTimer = null;
        _awaitingAnswer = false;
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _promoteRelayFallback();
        unawaited(
          _recoverDirectTransport(
            rtc: rtc,
            signaling: signaling,
            reason: 'peer-${state.name}',
          ),
        );
      }
      if (mounted) {
        setState(() {
          _status = _peerStateLabel(state);
          _updateConnectionReport();
        });
      }
    };
    rtc.onDiagnosticsChanged = (diagnostics) {
      if (mounted) {
        setState(() {
          _rtcDiagnostics = diagnostics;
          _updateConnectionReport();
        });
      }
    };
    rtc.onDataChannelState = (state) {
      if (!mounted) return;
      setState(() {
        _isDataChannelOpen = state == RTCDataChannelState.RTCDataChannelOpen;
        if (_isDataChannelOpen) {
          _relayPromotionTimer?.cancel();
          _relayFallbackAllowed = false;
        }
        _updateConnectionReport();
      });
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        unawaited(_sendLatestPointIfAvailable());
      } else if (state == RTCDataChannelState.RTCDataChannelClosing ||
          state == RTCDataChannelState.RTCDataChannelClosed) {
        _promoteRelayFallback();
        unawaited(
          _recoverDirectTransport(
            rtc: rtc,
            signaling: signaling,
            reason: 'data-channel-${state.name}',
          ),
        );
      }
    };
    rtc.onDataMessage = _handleRtcDataMessage;

    try {
      await rtc.initialize();
      await signaling.connect();
      _rtc = rtc;
      _signaling = signaling;
      await _restartForegroundLocationTracking();
      _backgroundRelayPermissionGranted =
          await _ensureBackgroundRelayPermissionsIfNeeded();

      if (!mounted) return;
      setState(() {
        _status = 'Sharing position';
        _rtcDiagnostics = rtc.connectionSummary;
        _updateConnectionReport();
      });
      await _syncAndroidBackgroundRelay();
      _startRelayHeartbeat();
    } catch (error, stackTrace) {
      AppLogger.error('Failed to start Geo position', error, stackTrace);
      await signaling.disconnect();
      await rtc.dispose();
      await _stopForegroundLocationTracking();
      if (!mounted) return;
      setState(() {
        _rtc = null;
        _signaling = null;
        _isDataChannelOpen = false;
        _status = error.toString();
        _connectionReport = 'Idle';
      });
      _stopRelayHeartbeat();
    }
  }

  Future<void> _stopSharing() async {
    _signaling?.send(
      const SignalingMessage(
        type: SignalingMessageType.control,
        payload: {'action': SignalingControlAction.geoPositionStopped},
      ),
    );
    await GeoBackgroundRelay.stop();
    _stopRelayHeartbeat();
    _relayPromotionTimer?.cancel();
    await _stopForegroundLocationTracking();
    await _signaling?.disconnect();
    await _rtc?.dispose();
    _resetNegotiationState();
    if (!mounted) return;
    setState(() {
      _rtc = null;
      _signaling = null;
      _isDataChannelOpen = false;
      _relayFallbackAllowed = false;
      _status = 'Standby';
      _connectionReport = 'WebRTC or WebSocket relay waiting to start';
    });
  }

  Future<void> _openSettings() async {
    final updatedSettings = await showGeoSettingsSheet(
      context: context,
      title: 'Position settings',
      initialSettings: _settings,
      turnAvailable: _config.hasTurnServer,
      mode: GeoSettingsSheetMode.position,
    );
    if (updatedSettings == null || !mounted) return;

    setState(() => _settings = updatedSettings);
    await GeoSettingsStorage.save(GeoSettingsScope.position, updatedSettings);
    _startRelayHeartbeat();
    if (_signaling != null && _rtc != null) {
      await _restartForegroundLocationTracking();
      _backgroundRelayPermissionGranted =
          await _ensureBackgroundRelayPermissionsIfNeeded();
      await _syncAndroidBackgroundRelay();
    } else if (!updatedSettings.backgroundTracking) {
      await GeoBackgroundRelay.stop();
    }
  }

  void _handleLocalPoint(GeoPoint point) {
    if (!mounted) return;
    final previousPoint = _latestPoint;
    final shouldAppendToHistory = _shouldAppendHistoryPoint(
      previousPoint: previousPoint,
      nextPoint: point,
    );
    setState(() {
      _latestPoint = point;
      if (shouldAppendToHistory) {
        _history.add(point);
        if (_history.length > 120) {
          _history.removeRange(0, _history.length - 120);
        }
      } else if (_history.isEmpty) {
        _history.add(point);
      } else {
        _history[_history.length - 1] = point;
      }
    });
    unawaited(_sendGeoPoint(point));
  }

  bool _shouldAppendHistoryPoint({
    required GeoPoint? previousPoint,
    required GeoPoint nextPoint,
  }) {
    if (previousPoint == null) {
      return true;
    }

    const coordinateDelta = 0.00001;
    return (previousPoint.latitude - nextPoint.latitude).abs() >
            coordinateDelta ||
        (previousPoint.longitude - nextPoint.longitude).abs() > coordinateDelta;
  }

  void _clearPathHistory() {
    if (!mounted) return;
    setState(() {
      _history
        ..clear()
        ..addAll(_latestPoint == null ? const <GeoPoint>[] : [_latestPoint!]);
    });
  }

  Future<void> _sendGeoPoint(GeoPoint point) async {
    final envelope = GeoEnvelope(
      type: 'position-update',
      payload: {'point': point.toMap()},
    ).encode();

    final rtc = _rtc;
    if (rtc != null && rtc.isDataChannelOpen) {
      try {
        await rtc.sendDataMessage(envelope);
        return;
      } catch (error, stackTrace) {
        AppLogger.error(
            'Failed to send geo point over data channel', error, stackTrace);
        _promoteRelayFallback();
      }
    }

    final signaling = _signaling;
    if (signaling != null &&
        signaling.isConnected &&
        _hasJoinedSignalingRoom &&
        (_relayFallbackAllowed || !_settings.preferDirectP2P)) {
      signaling.send(
        SignalingMessage(
          type: SignalingMessageType.data,
          payload: {
            'channel': 'geo-position',
            'envelope': envelope,
          },
        ),
      );
      return;
    }

    _ensureRelayReconnect();
  }

  Future<void> _sendLatestPointIfAvailable() async {
    final point = _latestPoint;
    if (point == null) {
      return;
    }
    await _sendGeoPoint(point);
  }

  void _ensureRelayReconnect() {
    if (_isBackgroundRelayActive) {
      return;
    }
    final signaling = _signaling;
    if (signaling == null || signaling.isConnected || signaling.isConnecting) {
      return;
    }
    unawaited(signaling.connect());
  }

  void _startRelayHeartbeat() {
    _relayHeartbeatTimer?.cancel();
    _relayHeartbeatTimer = Timer.periodic(
      Duration(seconds: math.max(_settings.updateIntervalSeconds * 3, 15)),
      (_) {
        if (_rtc == null && _signaling == null) {
          return;
        }

        if (!_isDataChannelOpen) {
          _ensureRelayReconnect();
        }
        if (_signaling?.isConnected == true) {
          _sendGeoPositionReady();
        }
        if (_relayFallbackAllowed || _isDataChannelOpen) {
          unawaited(_sendLatestPointIfAvailable());
        }
      },
    );
  }

  void _stopRelayHeartbeat() {
    _relayHeartbeatTimer?.cancel();
    _relayHeartbeatTimer = null;
  }

  Future<void> _queueLocationTransition(
    Future<void> Function() transition,
  ) {
    final nextTransition =
        _locationTransition.catchError((_) {}).then((_) => transition());
    _locationTransition = nextTransition.catchError((_) {});
    return nextTransition;
  }

  Future<void> _restartForegroundLocationTracking() {
    return _queueLocationTransition(() async {
      await _locationService.stop();
      await _locationService.start(
        settings: _settings,
        onPoint: _handleLocalPoint,
      );
    });
  }

  Future<void> _stopForegroundLocationTracking() {
    return _queueLocationTransition(() => _locationService.stop());
  }

  Future<void> _syncAndroidBackgroundRelay() async {
    if (_rtc == null || !_settings.backgroundTracking) {
      _isBackgroundRelayActive = false;
      await GeoBackgroundRelay.stop();
      return;
    }

    if (GeoBackgroundRelay.isSupported && !_backgroundRelayPermissionGranted) {
      _isBackgroundRelayActive = false;
      await GeoBackgroundRelay.stop();
      return;
    }

    if (_isAppInForeground) {
      _isBackgroundRelayActive = false;
      await GeoBackgroundRelay.deactivate();
      return;
    }

    final config = _backgroundRelayConfig();
    if (config == null) {
      return;
    }

    _isBackgroundRelayActive = GeoBackgroundRelay.isSupported;
    await GeoBackgroundRelay.activate(config);
  }

  void _updateConnectionReport() {
    if (_isBackgroundRelayActive) {
      _connectionReport = 'Android background relay active · app session paused';
      return;
    }

    if (_isDataChannelOpen) {
      final rtcLabel = _rtcDiagnostics.startsWith('WebRTC active')
          ? _rtcDiagnostics.replaceFirst('WebRTC active', 'WebRTC DataChannel')
          : 'WebRTC DataChannel active';
      _connectionReport = '$rtcLabel · encrypted WebSocket broker standby';
      return;
    }

    if (_signaling?.isConnected == true && _rtc != null) {
      _connectionReport = _relayFallbackAllowed
          ? 'WebSocket relay active · WebRTC recovery in progress'
          : 'WebSocket broker active · promoting WebRTC data channel';
      return;
    }

    if (_signaling?.isConnected == true) {
      _connectionReport = 'WebSocket session ready · waiting for WebRTC route';
      return;
    }

    if (_signaling?.isConnecting == true) {
      _connectionReport =
          'WebSocket relay reconnecting · latest location queued';
      return;
    }

    _connectionReport = 'WebRTC or WebSocket relay waiting to start';
  }

  void _handleRtcDataMessage(String rawValue) {
    final envelope = GeoEnvelope.decode(rawValue);
    if (envelope.type == 'monitor-ready') {
      _sendGeoPositionReady();
      unawaited(_sendLatestPointIfAvailable());
    }
  }

  void _handleFallbackData(Map<String, dynamic> payload) {
    final envelopeRaw = payload['envelope'] as String?;
    if (envelopeRaw == null || envelopeRaw.isEmpty) {
      return;
    }
    final envelope = GeoEnvelope.decode(envelopeRaw);
    if (envelope.type == 'monitor-ready') {
      _sendGeoPositionReady();
      unawaited(_sendLatestPointIfAvailable());
    }
  }

  void _sendGeoPositionReady([SignalingClient? signalingOverride]) {
    final signaling = signalingOverride ?? _signaling;
    if (signaling == null ||
        !signaling.isConnected ||
        !_hasJoinedSignalingRoom) {
      return;
    }
    signaling.send(
      SignalingMessage(
        type: SignalingMessageType.control,
        payload: {
          'action': SignalingControlAction.geoPositionReady,
          if (_usesQrPairing && _ownPairingPayloadForSync != null)
            'pairingPayload': _ownPairingPayloadForSync,
        },
      ),
    );
  }

  Future<void> _sendOfferIfPossible({
    required RtcManager rtc,
    required SignalingClient signaling,
    required String reason,
    bool iceRestart = false,
  }) async {
    if (_isSendingOffer ||
        _awaitingAnswer ||
        !signaling.isConnected ||
        !_hasJoinedSignalingRoom) {
      return;
    }

    _isSendingOffer = true;
    try {
      _armRelayPromotionWindow();
      final offer = iceRestart
          ? await rtc.createIceRestartOffer()
          : await rtc.createOffer();
      if (!signaling.isConnected) return;
      signaling.send(offer);
      _awaitingAnswer = true;
      _scheduleOfferRetry(
        rtc: rtc,
        signaling: signaling,
        iceRestart: iceRestart,
      );
      AppLogger.info('Geo position sent offer after $reason');
    } catch (error, stackTrace) {
      AppLogger.error('Failed to create geo position offer', error, stackTrace);
    } finally {
      _isSendingOffer = false;
    }
  }

  void _scheduleOfferRetry({
    required RtcManager rtc,
    required SignalingClient signaling,
    required bool iceRestart,
  }) {
    _offerRetryTimer?.cancel();
    _offerRetryTimer = Timer(const Duration(seconds: 3), () {
      _awaitingAnswer = false;
      unawaited(
        _sendOfferIfPossible(
          rtc: rtc,
          signaling: signaling,
          reason: 'answer-timeout',
          iceRestart: iceRestart,
        ),
      );
    });
  }

  void _resetNegotiationState() {
    _offerRetryTimer?.cancel();
    _offerRetryTimer = null;
    _isSendingOffer = false;
    _awaitingAnswer = false;
  }

  void _armRelayPromotionWindow() {
    _relayPromotionTimer?.cancel();
    if (!_settings.preferDirectP2P || _isDataChannelOpen) {
      _setRelayFallbackAllowed(true, resendLatest: true);
      return;
    }

    _setRelayFallbackAllowed(false);
    _relayPromotionTimer = Timer(_relayPromotionDelay, () {
      _setRelayFallbackAllowed(true, resendLatest: true);
    });
  }

  void _promoteRelayFallback() {
    _relayPromotionTimer?.cancel();
    _setRelayFallbackAllowed(true, resendLatest: true);
  }

  void _setRelayFallbackAllowed(
    bool isAllowed, {
    bool resendLatest = false,
  }) {
    if (_relayFallbackAllowed == isAllowed) {
      if (resendLatest && isAllowed) {
        unawaited(_sendLatestPointIfAvailable());
      }
      return;
    }

    void apply() {
      _relayFallbackAllowed = isAllowed;
      _updateConnectionReport();
    }
    if (mounted) {
      setState(apply);
    } else {
      apply();
    }

    if (resendLatest && isAllowed) {
      unawaited(_sendLatestPointIfAvailable());
    }
  }

  Future<void> _recoverDirectTransport({
    required RtcManager rtc,
    required SignalingClient signaling,
    required String reason,
  }) async {
    if (!identical(_rtc, rtc) ||
        !identical(_signaling, signaling) ||
        _isDataChannelOpen ||
        !signaling.isConnected) {
      return;
    }

    await _sendOfferIfPossible(
      rtc: rtc,
      signaling: signaling,
      reason: reason,
      iceRestart: true,
    );
  }

  void _dismissQrModalIfVisible() {
    if (!_isQrModalVisible) return;
    final dialogContext = _qrDialogContext;
    if (dialogContext != null && Navigator.of(dialogContext).canPop()) {
      Navigator.of(dialogContext).pop();
    }
  }

  void _maybeAutoStart() {
    if (_hasTriggeredInitialAutoStart ||
        !widget.autoStartOnLoad ||
        _signaling != null ||
        _rtc != null) {
      return;
    }

    final initialPairingLink = widget.initialPairingLink?.trim();
    if (initialPairingLink == null || initialPairingLink.isEmpty) {
      return;
    }

    _hasTriggeredInitialAutoStart = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_startSharing());
    });
  }

  String _peerStateLabel(RTCPeerConnectionState state) {
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateNew:
        return 'Preparing secure link';
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        return 'Establishing secure link';
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        return 'Secure link active';
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        return 'Link interrupted';
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        return 'Connection failed';
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        return 'Session closed';
    }
  }

  MetricTone _statusTone() {
    if (_rtc == null) return MetricTone.neutral;
    if (_status == 'Secure link active') return MetricTone.good;
    if (_status == 'Link interrupted' || _status == 'Connection failed') {
      return MetricTone.danger;
    }
    return MetricTone.warning;
  }

  Future<void> _ensureLocationPermissionsForStart() async {
    final locationEnabled = await Geolocator.isLocationServiceEnabled();
    if (!locationEnabled) {
      throw StateError('Location services are disabled');
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (_settings.backgroundTracking &&
        permission == LocationPermission.whileInUse &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw StateError('Location permission denied');
    }
    if (permission == LocationPermission.deniedForever) {
      throw StateError('Location permission denied permanently');
    }

    _backgroundRelayPermissionGranted =
        await _ensureBackgroundRelayPermissionsIfNeeded();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_rtc == null && _signaling == null) {
      return;
    }

    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_handleAppResumed());
        break;
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        unawaited(_handleAppBackgrounded());
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _handleAppResumed() async {
    _isAppInForeground = true;
    _isBackgroundRelayActive = false;
    await _syncAndroidBackgroundRelay();
    _startRelayHeartbeat();
    try {
      await _restartForegroundLocationTracking();
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to restart foreground geo tracking after resume',
        error,
        stackTrace,
      );
      if (mounted) {
        setState(() => _status = 'Location issue');
      }
    }
    _ensureRelayReconnect();
    if (_signaling?.isConnected == true) {
      _sendGeoPositionReady();
    }
    await _sendLatestPointIfAvailable();
    final rtc = _rtc;
    final signaling = _signaling;
    if (rtc != null && signaling != null && !_isDataChannelOpen) {
      await _recoverDirectTransport(
        rtc: rtc,
        signaling: signaling,
        reason: 'app-resumed',
      );
    }
  }

  Future<void> _handleAppBackgrounded() async {
    _isAppInForeground = false;
    _promoteRelayFallback();
    final canUseBackgroundRelay = GeoBackgroundRelay.isSupported &&
        _settings.backgroundTracking &&
        _backgroundRelayPermissionGranted;
    if (!canUseBackgroundRelay) {
      _ensureRelayReconnect();
      if (_signaling?.isConnected == true) {
        _sendGeoPositionReady();
      }
      await _sendLatestPointIfAvailable();
      return;
    }

    await _sendLatestPointIfAvailable();
    await _syncAndroidBackgroundRelay();
    _stopRelayHeartbeat();
    await _signaling?.disconnect();
    if (!mounted) {
      return;
    }
    setState(_updateConnectionReport);
  }

  Future<bool> _ensureBackgroundRelayPermissionsIfNeeded() async {
    if (!GeoBackgroundRelay.isSupported || !_settings.backgroundTracking) {
      return false;
    }

    final notificationsGranted =
        await PlatformPermissions.requestNotificationAccess();
    final backgroundLocationGranted =
        await PlatformPermissions.requestBackgroundLocationAccess();
    final isGranted = notificationsGranted && backgroundLocationGranted;
    if (mounted && !isGranted) {
      setState(() {
        _status = 'Background relay permission needed';
        _updateConnectionReport();
      });
    }
    return isGranted;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _offerRetryTimer?.cancel();
    _stopRelayHeartbeat();
    _relayPromotionTimer?.cancel();
    _roomController.dispose();
    _pairingLinkController.dispose();
    _signaling?.send(
      const SignalingMessage(
        type: SignalingMessageType.control,
        payload: {'action': SignalingControlAction.geoPositionStopped},
      ),
    );
    _signaling?.disconnect();
    _rtc?.dispose();
    unawaited(_stopForegroundLocationTracking());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isSharing = _rtc != null;
    final isMobilePlatform = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final previewAspectRatio = isMobilePlatform ? 9 / 16 : 16 / 9;

    return AppShell(
      title: 'Position',
      subtitle:
          'Share live GPS location with encrypted transport and relay fallback.\nDouble tap to enable or disable map drag.',
      hero: SurfacePanel(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: StatusPill(
                          label: _status,
                          color: _status == 'Secure link active'
                              ? AzureTheme.success
                              : AzureTheme.azureDark,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: _openSettings,
                  icon: const Icon(Icons.tune_rounded),
                ),
              ],
            ),
            const SizedBox(height: 12),
            AspectRatio(
              aspectRatio: previewAspectRatio,
              child: GeoMapSurface(
                primaryPoint: _latestPoint,
                history: _history,
                onClearPath: _clearPathHistory,
              ),
            ),
          ],
        ),
      ),
      panels: [
        SurfacePanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PairingMethodTabs(
                activeMethod: _pairingMethod,
                onChanged: (method) =>
                    unawaited(_handlePairingMethodChange(method)),
              ),
              const SizedBox(height: 16),
              if (_pairingMethod == PairingMethod.roomId)
                TextField(
                  controller: _roomController,
                  decoration: const InputDecoration(
                    labelText: 'Room ID',
                    hintText: 'Insert room ID to share',
                  ),
                  onChanged: (_) => setState(() {}),
                )
              else
                TextField(
                  controller: _pairingLinkController,
                  decoration: InputDecoration(
                    labelText: 'QR-Code Link',
                    errorText: _pairingLinkErrorText,
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 96,
                      minHeight: 48,
                    ),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Open QR code',
                          onPressed: () => unawaited(
                            _openQrCodeModal(
                              _pairingLinkController.text.trim().isEmpty
                                  ? _generatedQrPairingPayload
                                  : _pairingLinkController.text.trim(),
                            ),
                          ),
                          icon: const Icon(Icons.qr_code_2_rounded),
                        ),
                        IconButton(
                          tooltip: 'Scan QR code',
                          onPressed: _scanQrCodeLink,
                          icon: const Icon(Icons.qr_code_scanner_rounded),
                        ),
                      ],
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
            ],
          ),
        ),
        if (_settings.showConnectionReport)
          ConnectionReportPanel(
            title: 'Connection report',
            summary:
                'Route status: $_connectionReport. Geo sharing uses the data channel first and falls back to encrypted signaling relay when required.',
            highlights: const [],
            statusTone: _statusTone(),
          ),
        SurfacePanel(
          child: Text(
            _latestPoint == null
                ? 'Waiting for the first location update.'
                : 'Latest: ${_latestPoint!.latitude.toStringAsFixed(5)}, ${_latestPoint!.longitude.toStringAsFixed(5)} · ${_latestPoint!.timestamp.toLocal()}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AzureTheme.ink.withValues(alpha: 0.76),
                ),
          ),
        ),
      ],
      actions: [
        ElevatedButton(
          onPressed:
              !isSharing && _hasValidPairingSelection ? _startSharing : null,
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.play_circle_fill_rounded),
              SizedBox(width: 8),
              Text('Start sharing'),
            ],
          ),
        ),
        OutlinedButton(
          onPressed: isSharing ? _stopSharing : null,
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.stop_circle_rounded),
              SizedBox(width: 8),
              Text('Stop'),
            ],
          ),
        ),
      ],
    );
  }
}
