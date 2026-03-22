import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/app_config.dart';
import '../config/stream_settings.dart';
import '../crypto/pairing_cipher.dart';
import '../signaling/control_actions.dart';
import '../signaling/signaling_client.dart';
import '../signaling/signaling_message.dart';
import '../ui/azure_theme.dart';
import '../utils/app_logger.dart';
import '../utils/device_alerts.dart';
import '../utils/device_identity_storage.dart';
import '../utils/paired_devices_storage.dart';
import '../utils/pairing_secret.dart';
import '../utils/room_security.dart';
import '../webrtc/rtc_manager.dart';
import '../widgets/app_shell_ui.dart';
import '../widgets/pairing_panel.dart';
import 'geo_map_surface.dart';
import 'geo_models.dart';
import 'geo_settings.dart';
import 'geo_settings_sheet.dart';
import 'geo_settings_storage.dart';

class GeoMonitorScreen extends StatefulWidget {
  const GeoMonitorScreen({
    super.key,
    this.initialPairingLink,
    this.autoConnectOnLoad = false,
  });

  final String? initialPairingLink;
  final bool autoConnectOnLoad;

  @override
  State<GeoMonitorScreen> createState() => _GeoMonitorScreenState();
}

class _GeoMonitorScreenState extends State<GeoMonitorScreen> {
  final _roomController = TextEditingController();
  final _pairingLinkController = TextEditingController();

  late final AppConfig _config;
  GeoSettings _settings = GeoSettings.monitorDefaults;
  SignalingClient? _signaling;
  RtcManager? _rtc;
  String _status = 'Standby';
  String _connectionReport = 'Data channel first · idle';
  PairingMethod _pairingMethod = PairingMethod.qrCode;
  String? _qrPairingRoomId;
  String? _localDeviceId;
  String? _qrPairingSecret;
  bool _hasTriggeredInitialAutoConnect = false;
  bool _isQrModalVisible = false;
  BuildContext? _qrDialogContext;
  GeoPoint? _remotePoint;
  final List<GeoPoint> _remoteHistory = [];
  DateTime? _lastRemoteUpdateAt;
  bool _isRemotePointFresh = true;
  Timer? _freshnessTimer;
  bool _isDataChannelOpen = false;
  String _rtcDiagnostics = 'WebRTC route pending';
  bool _lastInboundUpdateUsedRelay = false;
  bool _hasShownStaleAlert = false;
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
        role: 'geo-monitor',
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

  @override
  void initState() {
    super.initState();
    _config = AppConfig.fromEnvironment();
    final initialPairingLink = widget.initialPairingLink?.trim();
    if (initialPairingLink != null && initialPairingLink.isNotEmpty) {
      _pairingLinkController.text = initialPairingLink;
      _pairingMethod = PairingMethod.qrCode;
    }
    unawaited(_loadPairingIdentity());
    _loadSettings();
    _startFreshnessWatch();
  }

  Future<void> _loadSettings() async {
    final settings = await GeoSettingsStorage.load(
      GeoSettingsScope.monitor,
      fallback: GeoSettings.monitorDefaults,
    );
    if (!mounted) return;
    setState(() => _settings = settings);
    _maybeAutoConnect();
  }

  Future<void> _loadPairingIdentity() async {
    final deviceId = await DeviceIdentityStorage.loadOrCreateDeviceId();
    final pairingRoomId =
        await DeviceIdentityStorage.roomIdForRole('geo-monitor');
    final pairingSecret =
        await DeviceIdentityStorage.pairingSecretForRole('geo-monitor');
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
        pairingData.role?.trim().toLowerCase() != 'geo-position' ||
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
      launchRole: 'geo-monitor',
      peerPayload: payload,
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
      subtitle: 'Share this code with Position mode to pair instantly.',
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
      launchRole: 'geo-monitor',
      peerPayload: scannedValue,
    );
    _pairingLinkController.text = scannedValue;
    setState(() => _pairingMethod = PairingMethod.qrCode);
  }

  Future<void> _connect() async {
    if (_signaling != null || _rtc != null) {
      return;
    }

    final signaling = SignalingClient(
      serverUrl: _resolvedSignalingUrl,
      cipher: await _buildPairingCipher(),
    );
    final rtc = RtcManager(
      role: PeerRole.geoMonitor,
      config: _config,
      settings: _rtcTransportSettings(),
    );

    signaling.onConnected = () async {
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
            'role': 'geo-monitor',
            if (_localDeviceId != null) 'deviceId': _localDeviceId,
            if (_usesQrPairing && _ownPairingPayloadForSync != null)
              'pairingPayload': _ownPairingPayloadForSync,
          },
        ),
      );
      await _syncWakeMode();
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
        _sendGeoMonitorReady(signaling);
      }
      if (message.type == SignalingMessageType.join &&
          message.payload['role'] == 'geo-position') {
        _dismissQrModalIfVisible();
        await _saveRemotePairingPayload(
          message.payload['pairingPayload']?.toString(),
        );
        _sendGeoMonitorReady(signaling);
      }
      if (message.type == SignalingMessageType.control &&
          message.payload['action'] ==
              SignalingControlAction.geoPositionReady) {
        await _saveRemotePairingPayload(
          message.payload['pairingPayload']?.toString(),
        );
        _sendGeoMonitorReady(signaling);
      }
      if (message.type == SignalingMessageType.control) {
        final action = message.payload['action'];
        if (action == SignalingControlAction.pairingLinkSync) {
          await _saveRemotePairingPayload(
            message.payload['pairingPayload']?.toString(),
          );
        }
        if (action == SignalingControlAction.geoPositionStopped) {
          if (mounted) {
            setState(() => _status = 'Position sharing stopped');
          }
          unawaited(
            DeviceAlerts.show(
              id: DeviceAlertIds.geoFeedStopped,
              title: 'Position sharing stopped',
              body:
                  'The paired position device stopped sharing its live location.',
            ),
          );
        }
        if (action == SignalingControlAction.geoPositionAppSwiped) {
          if (mounted) {
            setState(() => _status = 'Position app removed from recents');
          }
          unawaited(
            DeviceAlerts.show(
              id: DeviceAlertIds.geoFeedAppSwiped,
              title: 'Position app was swiped away',
              body:
                  'The paired position app was removed from recents. Background relay should keep location sharing alive.',
            ),
          );
        }
      }
      if (message.type == SignalingMessageType.data) {
        _handleFallbackData(message.payload);
      }
      await rtc.handleSignalingMessage(message);
    };

    signaling.onDisconnected = () {
      _hasJoinedSignalingRoom = false;
      if (mounted) {
        setState(() {
          if (!_hasActiveSecureLink) {
            _status = 'Session closed';
          }
          _updateConnectionReport();
        });
      }
    };

    signaling.onError = (error, [stack]) {
      if (mounted) {
        setState(() => _status = 'Connection issue');
      }
      AppLogger.error('Geo monitor signaling error', error, stack);
    };

    rtc.onSignal = signaling.send;
    rtc.onConnectionState = (state) async {
      if (mounted) {
        setState(() => _status = _peerStateLabel(state));
      }
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        await _syncWakeMode();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateClosed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        await WakelockPlus.disable();
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
          _lastInboundUpdateUsedRelay = false;
          _hasShownStaleAlert = false;
        }
        _updateConnectionReport();
      });
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _sendGeoMonitorReady();
      }
    };
    rtc.onDataMessage = _handleRtcDataMessage;

    try {
      await rtc.initialize();
      await signaling.connect();
      if (!mounted) return;
      setState(() {
        _rtc = rtc;
        _signaling = signaling;
        _status = 'Waiting for position feed';
        _rtcDiagnostics = rtc.connectionSummary;
        _updateConnectionReport();
      });
    } catch (error, stackTrace) {
      AppLogger.error('Failed to connect Geo monitor', error, stackTrace);
      await signaling.disconnect();
      await rtc.dispose();
      await WakelockPlus.disable();
      if (!mounted) return;
      setState(() {
        _rtc = null;
        _signaling = null;
        _isDataChannelOpen = false;
        _lastInboundUpdateUsedRelay = false;
        _status = error.toString();
        _connectionReport = 'Idle';
      });
    }
  }

  Future<void> _disconnect() async {
    await _signaling?.disconnect();
    await _rtc?.dispose();
    await WakelockPlus.disable();
    if (!mounted) return;
    setState(() {
      _rtc = null;
      _signaling = null;
      _isDataChannelOpen = false;
      _lastInboundUpdateUsedRelay = false;
      _status = 'Standby';
      _connectionReport = 'WebRTC or WebSocket relay idle';
    });
  }

  Future<void> _openSettings() async {
    final updatedSettings = await showGeoSettingsSheet(
      context: context,
      title: 'Geo monitor settings',
      initialSettings: _settings,
      turnAvailable: _config.hasTurnServer,
      mode: GeoSettingsSheetMode.monitor,
    );
    if (updatedSettings == null || !mounted) return;

    setState(() => _settings = updatedSettings);
    await GeoSettingsStorage.save(GeoSettingsScope.monitor, updatedSettings);
    await _syncWakeMode();
  }

  Future<void> _syncWakeMode() async {
    if (_settings.keepAwake && _rtc != null) {
      await WakelockPlus.enable();
    } else {
      await WakelockPlus.disable();
    }
  }

  void _handleRtcDataMessage(String rawValue) {
    final envelope = GeoEnvelope.decode(rawValue);
    _applyEnvelope(envelope, arrivedViaRelay: false);
  }

  void _handleFallbackData(Map<String, dynamic> payload) {
    final envelopeRaw = payload['envelope'] as String?;
    if (envelopeRaw == null || envelopeRaw.isEmpty) {
      return;
    }
    final envelope = GeoEnvelope.decode(envelopeRaw);
    _applyEnvelope(envelope, arrivedViaRelay: true);
  }

  void _applyEnvelope(
    GeoEnvelope envelope, {
    required bool arrivedViaRelay,
  }) {
    if (envelope.type != 'position-update') {
      return;
    }

    final point = GeoPoint.fromMap(
      (envelope.payload['point'] as Map).cast<String, dynamic>(),
    );
    if (!mounted) return;

    final previousPoint = _remotePoint;
    if (previousPoint != null &&
        point.timestampMillis < previousPoint.timestampMillis) {
      return;
    }

    final shouldAppendToHistory = _shouldAppendHistoryPoint(
      previousPoint: previousPoint,
      nextPoint: point,
    );
    setState(() {
      _lastInboundUpdateUsedRelay = arrivedViaRelay;
      _hasShownStaleAlert = false;
      _remotePoint = point;
      _lastRemoteUpdateAt = DateTime.now();
      _isRemotePointFresh = true;
      if (shouldAppendToHistory) {
        _remoteHistory.add(point);
        if (_remoteHistory.length > 120) {
          _remoteHistory.removeRange(0, _remoteHistory.length - 120);
        }
      } else if (_remoteHistory.isEmpty) {
        _remoteHistory.add(point);
      } else {
        _remoteHistory[_remoteHistory.length - 1] = point;
      }
      _updateConnectionReport();
    });
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

  Duration get _remotePointStaleAfter =>
      Duration(seconds: math.max(_settings.updateIntervalSeconds * 3, 15));

  void _startFreshnessWatch() {
    _freshnessTimer?.cancel();
    _freshnessTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _refreshRemotePointFreshness();
    });
  }

  void _refreshRemotePointFreshness() {
    final lastRemoteUpdateAt = _lastRemoteUpdateAt;
    final nextFreshValue = lastRemoteUpdateAt != null &&
        DateTime.now().difference(lastRemoteUpdateAt) <= _remotePointStaleAfter;
    if (!mounted || nextFreshValue == _isRemotePointFresh) {
      return;
    }
    setState(() => _isRemotePointFresh = nextFreshValue);
    if (!nextFreshValue && !_hasShownStaleAlert) {
      _hasShownStaleAlert = true;
      unawaited(
        DeviceAlerts.show(
          id: DeviceAlertIds.geoFeedInterrupted,
          title: 'Location updates interrupted',
          body:
              'The paired position device has not delivered a fresh location update recently.',
        ),
      );
    }
  }

  void _clearPathHistory() {
    if (!mounted) return;
    setState(() {
      _remoteHistory
        ..clear()
        ..addAll(_remotePoint == null ? const <GeoPoint>[] : [_remotePoint!]);
    });
  }

  void _sendGeoMonitorReady([SignalingClient? signalingOverride]) {
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
          'action': SignalingControlAction.geoMonitorReady,
          if (_usesQrPairing && _ownPairingPayloadForSync != null)
            'pairingPayload': _ownPairingPayloadForSync,
        },
      ),
    );
    final rtc = _rtc;
    if (rtc != null && rtc.isDataChannelOpen) {
      unawaited(
        rtc.sendDataMessage(
          const GeoEnvelope(type: 'monitor-ready', payload: {}).encode(),
        ),
      );
    }
  }

  void _updateConnectionReport() {
    if (_isDataChannelOpen) {
      final rtcLabel = _rtcDiagnostics.startsWith('WebRTC active')
          ? _rtcDiagnostics.replaceFirst('WebRTC active', 'WebRTC DataChannel')
          : 'WebRTC DataChannel active';
      _connectionReport = '$rtcLabel · encrypted WebSocket broker standby';
      return;
    }

    if (_signaling?.isConnected == true && _rtc != null) {
      _connectionReport = _lastInboundUpdateUsedRelay
          ? 'WebSocket relay active · WebRTC recovery in progress'
          : 'WebSocket broker active · waiting for WebRTC data channel';
      return;
    }

    if (_signaling?.isConnected == true) {
      _connectionReport = 'WebSocket session ready · waiting for WebRTC route';
      return;
    }

    _connectionReport = 'WebRTC or WebSocket relay idle';
  }

  void _dismissQrModalIfVisible() {
    if (!_isQrModalVisible) return;
    final dialogContext = _qrDialogContext;
    if (dialogContext != null && Navigator.of(dialogContext).canPop()) {
      Navigator.of(dialogContext).pop();
    }
  }

  void _maybeAutoConnect() {
    if (_hasTriggeredInitialAutoConnect ||
        !widget.autoConnectOnLoad ||
        _signaling != null ||
        _rtc != null) {
      return;
    }

    final initialPairingLink = widget.initialPairingLink?.trim();
    if (initialPairingLink == null || initialPairingLink.isEmpty) {
      return;
    }

    _hasTriggeredInitialAutoConnect = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_connect());
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

  @override
  void dispose() {
    _freshnessTimer?.cancel();
    _roomController.dispose();
    _pairingLinkController.dispose();
    _signaling?.disconnect();
    _rtc?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _rtc != null;
    final isMobilePlatform = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final previewAspectRatio = isMobilePlatform ? 9 / 16 : 16 / 9;

    return AppShell(
      title: 'Geo Monitor',
      subtitle:
          'Watch a paired position feed over WebRTC data channel with encrypted relay fallback.\nDouble tap to enable or disable map drag.',
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
                primaryPoint: _remotePoint,
                history: _remoteHistory,
                primaryPointIsFresh: _isRemotePointFresh,
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
                'Route status: $_connectionReport. Geo monitor uses the data channel first and falls back to encrypted signaling relay when required.',
            highlights: const [],
            statusTone: _statusTone(),
          ),
        SurfacePanel(
          child: Text(
            _remotePoint == null
                ? 'Waiting for the first remote location update.'
                : 'Remote: ${_remotePoint!.latitude.toStringAsFixed(5)}, ${_remotePoint!.longitude.toStringAsFixed(5)} · ${_remotePoint!.timestamp.toLocal()}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AzureTheme.ink.withValues(alpha: 0.76),
                ),
          ),
        ),
      ],
      actions: [
        ElevatedButton(
          onPressed:
              !isConnected && _hasValidPairingSelection ? _connect : null,
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.wifi_tethering_rounded),
              SizedBox(width: 8),
              Text('Connect'),
            ],
          ),
        ),
        OutlinedButton(
          onPressed: isConnected ? _disconnect : null,
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.link_off_rounded),
              SizedBox(width: 8),
              Text('Disconnect'),
            ],
          ),
        ),
      ],
    );
  }
}
