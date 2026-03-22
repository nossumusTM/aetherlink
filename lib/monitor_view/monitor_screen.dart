import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../crypto/pairing_cipher.dart';
import '../config/app_config.dart';
import '../config/stream_settings.dart';
import '../signaling/control_actions.dart';
import '../signaling/signaling_client.dart';
import '../signaling/signaling_message.dart';
import '../ui/azure_theme.dart';
import '../utils/app_logger.dart';
import '../utils/device_alerts.dart';
import '../utils/device_identity_storage.dart';
import '../utils/paired_devices_storage.dart';
import '../utils/pairing_secret.dart';
import '../utils/recording_timestamp_overlay.dart';
import '../utils/recording_storage.dart';
import '../utils/room_security.dart';
import '../utils/settings_storage.dart';
import '../webrtc/rtc_manager.dart';
import '../widgets/app_shell_ui.dart';
import '../widgets/pairing_panel.dart';

const ColorFilter _remoteNightModePreviewFilter = ColorFilter.matrix([
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
]);

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({
    super.key,
    this.initialPairingLink,
    this.autoConnectOnLoad = false,
  });

  final String? initialPairingLink;
  final bool autoConnectOnLoad;

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  final _roomController = TextEditingController();
  final _pairingLinkController = TextEditingController();

  late final AppConfig _config;
  SignalingClient? _signaling;
  RtcManager? _rtc;
  StreamSettings _settings = StreamSettings.monitorDefaults;
  PairingMethod _pairingMethod = PairingMethod.qrCode;
  String _status = 'Standby';
  String _connectionReport = 'P2P first · idle';
  String? _recordingPath;
  DateTime? _recordingStartedAt;
  StreamSettings? _cameraSyncedSettings;
  bool _remoteActivityDetected = false;
  double _monitorPreviewZoom = 1.0;
  bool _didAutoOpenFullscreen = false;
  Timer? _monitorPresenceTimer;
  String? _qrPairingRoomId;
  String? _localDeviceId;
  String? _qrPairingSecret;
  bool _hasTriggeredInitialAutoConnect = false;
  bool _isQrModalVisible = false;
  BuildContext? _qrDialogContext;
  bool _hasShownCameraInterruptAlert = false;
  bool _hasJoinedSignalingRoom = false;

  bool get _hasActiveSecureLink => _status == 'Secure link active';

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
      expectedFamily: PairingFeatureFamily.liveCamera,
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
    final value = _roomController.text.trim();
    return value;
  }

  String get _transmissionRoomId => secureRoomToken(_resolvedRoomId);

  String get _resolvedSignalingUrl =>
      _pairingPayloadData?.signalingUrl ?? _config.signalingUrl;

  String get _generatedQrPairingPayload => buildPairingPayload(
        roomId: _transmissionRoomId,
        signalingUrl: _resolvedSignalingUrl,
        role: 'monitor',
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

  StreamSettings _responsiveSettings(
    BuildContext context, [
    StreamSettings? baseSettings,
  ]) {
    final size = MediaQuery.of(context).size;
    return (baseSettings ?? _settings).resolvedForViewport(
      screenWidth: size.width,
      screenHeight: size.height,
      role: StreamViewportRole.monitor,
    );
  }

  RTCVideoViewObjectFit _previewObjectFit(StreamSettings effectiveSettings) =>
      (Platform.isAndroid || Platform.isIOS)
          ? RTCVideoViewObjectFit.RTCVideoViewObjectFitCover
          : effectiveSettings.rtcVideoFit;

  Widget _buildMonitorPreviewVideo({
    required RTCVideoViewObjectFit objectFit,
    required bool monochrome,
  }) {
    final rtc = _rtc;
    if (rtc == null) {
      return const SizedBox.shrink();
    }

    final video = RTCVideoView(
      rtc.remoteRenderer,
      objectFit: objectFit,
    );

    if (Platform.isAndroid || !monochrome) {
      return video;
    }

    return ColorFiltered(
      colorFilter: _remoteNightModePreviewFilter,
      child: video,
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
    _loadPersistedSettings();
  }

  Future<void> _loadPairingIdentity() async {
    final deviceId = await DeviceIdentityStorage.loadOrCreateDeviceId();
    final pairingRoomId = await DeviceIdentityStorage.roomIdForRole('monitor');
    final pairingSecret =
        await DeviceIdentityStorage.pairingSecretForRole('monitor');
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
        pairingData.role?.trim().toLowerCase() != 'camera' ||
        pairingPayloadCompatibilityError(
              payloadData: pairingData,
              expectedFamily: PairingFeatureFamily.liveCamera,
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
      launchRole: 'monitor',
      peerPayload: payload,
    );
  }

  Future<void> _connect() async {
    if (_signaling != null || _rtc != null) return;

    final effectiveSettings = _responsiveSettings(context);
    final signaling = SignalingClient(
      serverUrl: _resolvedSignalingUrl,
      cipher: await _buildPairingCipher(),
    );
    final rtc = RtcManager(
      role: PeerRole.monitor,
      config: _config,
      settings: effectiveSettings,
    );

    signaling.onConnected = () {
      _hasJoinedSignalingRoom = false;
      setState(() {
        if (!_hasActiveSecureLink) {
          _status = 'Session broker ready';
        }
      });
      signaling.send(
        SignalingMessage(
          type: SignalingMessageType.join,
          payload: {
            'roomId': _transmissionRoomId,
            'role': 'monitor',
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
        _startMonitorPresence(signaling);
      }
      if (message.type == SignalingMessageType.join &&
          message.payload['role'] == 'camera') {
        _dismissQrModalIfVisible();
        await _saveRemotePairingPayload(
          message.payload['pairingPayload']?.toString(),
        );
        _sendMonitorReady(signaling);
      }
      if (message.type == SignalingMessageType.control) {
        final action = message.payload['action'];
        if (action == SignalingControlAction.cameraReady) {
          await _saveRemotePairingPayload(
            message.payload['pairingPayload']?.toString(),
          );
          _sendMonitorReady(signaling);
        }
        if (action == SignalingControlAction.pairingLinkSync) {
          await _saveRemotePairingPayload(
            message.payload['pairingPayload']?.toString(),
          );
        }
        if (action == SignalingControlAction.cameraSettingsUpdated) {
          final settingsPayload =
              (message.payload['settings'] as Map?)?.cast<String, dynamic>();
          if (mounted && settingsPayload != null) {
            setState(() {
              _cameraSyncedSettings = StreamSettings.fromPersistenceMap(
                settingsPayload,
                fallback:
                    _cameraSyncedSettings ?? StreamSettings.cameraDefaults,
              );
            });
          }
        }
        if (action == SignalingControlAction.cameraActivityUpdated && mounted) {
          setState(() {
            _remoteActivityDetected =
                message.payload['activityDetected'] == true;
          });
        }
        if (mounted &&
            (action == SignalingControlAction.start ||
                action == SignalingControlAction.stop)) {
          setState(() => _status = _controlStatusLabel(action?.toString()));
        }
        if (action == SignalingControlAction.stop) {
          unawaited(
            DeviceAlerts.show(
              id: DeviceAlertIds.cameraFeedStopped,
              title: 'Camera stopped streaming',
              body: 'The paired camera device stopped its live stream.',
            ),
          );
        }
      }
      await rtc.handleSignalingMessage(message);
    };

    signaling.onError = (error, [stack]) {
      if (mounted && !_hasActiveSecureLink) {
        setState(() => _status = 'Connection issue');
      }
      AppLogger.error('Monitor signaling error', error, stack);
    };

    signaling.onDisconnected = () {
      _hasJoinedSignalingRoom = false;
      _stopMonitorPresence();
      if (mounted) {
        setState(() {
          if (!_hasActiveSecureLink) {
            _status = 'Session closed';
          }
        });
      }
    };

    rtc.onSignal = signaling.send;
    rtc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _stopMonitorPresence();
        _hasShownCameraInterruptAlert = false;
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _startMonitorPresence(signaling);
        if (!_hasShownCameraInterruptAlert) {
          _hasShownCameraInterruptAlert = true;
          unawaited(
            DeviceAlerts.show(
              id: DeviceAlertIds.cameraFeedInterrupted,
              title: 'Camera connection interrupted',
              body:
                  'The paired camera feed was interrupted. Sputni is attempting to reconnect.',
            ),
          );
        }
      }
      if (mounted) {
        setState(() => _status = _peerStateLabel(state));
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
          _maybeOpenFullscreenAfterConnect();
        }
      }
    };
    rtc.onDiagnosticsChanged = (diagnostics) {
      if (mounted) {
        setState(() => _connectionReport = diagnostics);
      }
    };

    await rtc.initialize();
    await signaling.connect();

    if (!mounted) return;
    setState(() {
      _settings = effectiveSettings;
      _signaling = signaling;
      _rtc = rtc;
      _status = 'Waiting for camera';
      _connectionReport = rtc.connectionSummary;
      _cameraSyncedSettings = null;
      _remoteActivityDetected = false;
      _didAutoOpenFullscreen = false;
    });
  }

  Future<void> _disconnect() async {
    _stopMonitorPresence();
    await _signaling?.disconnect();
    await _rtc?.dispose();

    if (!mounted) return;
    setState(() {
      _signaling = null;
      _rtc = null;
      _status = 'Standby';
      _connectionReport = 'P2P first · idle';
      _cameraSyncedSettings = null;
      _remoteActivityDetected = false;
      _didAutoOpenFullscreen = false;
    });
  }

  Future<void> _openSettings() async {
    final updatedSettings = await showSettingsSheet(
      context: context,
      title: 'Monitor settings',
      initialSettings: _settings,
      turnAvailable: _config.hasTurnServer,
      mode: SettingsSheetMode.monitor,
    );

    if (updatedSettings == null || !mounted) return;

    await _applyMonitorSettings(updatedSettings);
    _maybeOpenFullscreenAfterConnect();
  }

  Future<void> _openQrCodeModal(String payload) {
    _isQrModalVisible = true;
    return showPairingQrCodeModal(
      context: context,
      payload: payload,
      title: 'QR pairing',
      subtitle: 'Share this monitor pairing code without opening the camera.',
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
      expectedFamily: PairingFeatureFamily.liveCamera,
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
      launchRole: 'monitor',
      peerPayload: scannedValue,
    );
    _pairingLinkController.text = scannedValue;
    setState(() {
      _pairingMethod = PairingMethod.qrCode;
    });
  }

  void _dismissQrModalIfVisible() {
    if (!_isQrModalVisible) return;

    final dialogContext = _qrDialogContext;
    if (dialogContext != null && Navigator.of(dialogContext).canPop()) {
      Navigator.of(dialogContext).pop();
    }
  }

  Future<void> _openFullscreenPreview(StreamSettings effectiveSettings) {
    final rtc = _rtc;
    if (rtc == null) return Future.value();
    final remoteViewSettings = _remoteViewSettings(effectiveSettings);

    return showFullscreenPreview(
      context: context,
      renderer: rtc.remoteRenderer,
      objectFit: _previewObjectFit(effectiveSettings),
      lowLightBoost: remoteViewSettings.lowLightBoost,
      monochrome: remoteViewSettings.cameraLightMode == CameraLightMode.night,
      profileLabel: remoteViewSettings.videoProfileLabel,
      preferPortrait: Platform.isAndroid &&
          remoteViewSettings.videoDisplayMode == VideoDisplayMode.portrait,
      contentScale: remoteViewSettings.cameraViewScale,
      topCenterOverlay: const LiveDateTimeBadge(),
    );
  }

  Future<void> _toggleRecording() async {
    final rtc = _rtc;
    if (rtc == null) return;

    try {
      if (rtc.isRecording) {
        final currentRecordingPath = _recordingPath;
        final currentRecordingStartedAt = _recordingStartedAt;
        await rtc.stopRecording();
        final timestampedPath =
            currentRecordingPath == null || currentRecordingStartedAt == null
                ? currentRecordingPath
                : await burnRecordingDateTimeOverlay(
                    currentPath: currentRecordingPath,
                    recordingStartedAt: currentRecordingStartedAt,
                  );
        final finalizedPath = timestampedPath == null
            ? null
            : await finalizeRecordingPath(
                settings: _settings,
                currentPath: timestampedPath,
              );
        if (!mounted) return;
        setState(() {
          _recordingPath =
              finalizedPath ?? timestampedPath ?? currentRecordingPath;
          _recordingStartedAt = null;
          _status = 'Recording saved';
        });
        return;
      }

      final recordingsDirectory =
          await resolveRecordingWorkingDirectory(_settings);

      if (!await recordingsDirectory.exists()) {
        await recordingsDirectory.create(recursive: true);
      }

      final recordingStartedAt = DateTime.now();
      final filePath =
          '${recordingsDirectory.path}${Platform.pathSeparator}monitor_${recordingStartedAt.millisecondsSinceEpoch}.mp4';

      await rtc.startRecording(filePath);

      if (!mounted) return;
      setState(() {
        _recordingPath = rtc.activeRecordingPath ?? filePath;
        _recordingStartedAt = recordingStartedAt;
        _status = 'Recording locally';
      });
    } on StateError catch (error, stackTrace) {
      AppLogger.error('Unable to start monitor recording', error, stackTrace);
      if (!mounted) return;
      setState(() => _status = error.message);
    } catch (error, stackTrace) {
      AppLogger.error('Unable to start monitor recording', error, stackTrace);
      if (!mounted) return;
      setState(() => _status = error.toString());
    }
  }

  void _adjustMonitorZoom(double delta) {
    setState(() {
      _monitorPreviewZoom = (_monitorPreviewZoom + delta).clamp(1.0, 3.0);
    });
  }

  void _startMonitorPresence(SignalingClient signaling) {
    _stopMonitorPresence();
    _sendMonitorReady(signaling);
    _monitorPresenceTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _sendMonitorReady(signaling),
    );
  }

  void _stopMonitorPresence() {
    _monitorPresenceTimer?.cancel();
    _monitorPresenceTimer = null;
  }

  void _sendMonitorReady(SignalingClient signaling) {
    if (!signaling.isConnected || !_hasJoinedSignalingRoom) return;

    signaling.send(
      SignalingMessage(
        type: SignalingMessageType.control,
        payload: {
          'action': SignalingControlAction.monitorReady,
          if (_usesQrPairing && _ownPairingPayloadForSync != null)
            'pairingPayload': _ownPairingPayloadForSync,
        },
      ),
    );
  }

  void _maybeOpenFullscreenAfterConnect() {
    if (!mounted ||
        _didAutoOpenFullscreen ||
        _rtc == null ||
        !_settings.autoFullscreenOnConnect) {
      return;
    }

    _didAutoOpenFullscreen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _rtc == null) return;
      _openFullscreenPreview(_responsiveSettings(context));
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

  String _controlStatusLabel(String? action) {
    switch (action) {
      case SignalingControlAction.start:
        return 'Camera went live';
      case SignalingControlAction.stop:
        return 'Camera stopped streaming';
      default:
        return 'Control update received';
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

  Color _statusColor() {
    if (_status == 'Recording locally') {
      return const Color(0xFFD7263D);
    }
    if (_status == 'Recording saved') {
      return AzureTheme.success;
    }
    switch (_statusTone()) {
      case MetricTone.good:
        return AzureTheme.success;
      case MetricTone.warning:
        return AzureTheme.warning;
      case MetricTone.danger:
        return const Color(0xFFB42318);
      case MetricTone.neutral:
        return AzureTheme.azureDark;
    }
  }

  @override
  void dispose() {
    _stopMonitorPresence();
    _roomController.dispose();
    _pairingLinkController.dispose();
    _signaling?.disconnect();
    _rtc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _rtc != null;
    final canConnect = !isConnected && _hasValidPairingSelection;
    final canDisconnect = isConnected;
    final canRecord = _rtc?.supportsRecording ?? false;
    final effectiveSettings = _responsiveSettings(context);
    final previewFit = _previewObjectFit(effectiveSettings);
    final remoteViewSettings = _remoteViewSettings(effectiveSettings);
    final cameraMicrophoneEnabled =
        _cameraSyncedSettings?.enableMicrophone ?? false;
    final canZoomOut = _monitorPreviewZoom > 1.0;
    final canZoomIn = _monitorPreviewZoom < 3.0;
    final recordingDotColor = (_rtc?.isRecording ?? false)
        ? const Color(0xFFD7263D)
        : (_recordingPath != null ? AzureTheme.success : Colors.white);

    return AppShell(
      title: 'Monitor',
      subtitle: 'Viewer dashboard with controls and connection diagnostics.',
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
                          color: _statusColor(),
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
              aspectRatio: effectiveSettings.videoProfile.previewAspectRatio,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Color(0xFF081A33)),
                  child: _rtc == null
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              'Remote feed will appear here',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white70),
                            ),
                          ),
                        )
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            Semantics(
                              label: 'Remote video preview',
                              image: true,
                              child: ExcludeSemantics(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ClipRect(
                                      child: Transform.scale(
                                        scale: _monitorPreviewZoom *
                                            remoteViewSettings.cameraViewScale,
                                        child: _buildMonitorPreviewVideo(
                                          objectFit: previewFit,
                                          monochrome: remoteViewSettings
                                                  .cameraLightMode ==
                                              CameraLightMode.night,
                                        ),
                                      ),
                                    ),
                                    if (remoteViewSettings.cameraLightMode ==
                                        CameraLightMode.night)
                                      Container(
                                        color: Colors.black.withValues(
                                          alpha: 0.16,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            if (remoteViewSettings.lowLightBoost)
                              Container(
                                color: Colors.lightBlueAccent
                                    .withValues(alpha: 0.08),
                              ),
                            Positioned(
                              top: 12,
                              left: 12,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  PulseRecordingBadge(
                                    fontSize: 10,
                                    showPulse: _rtc?.isRecording ?? false,
                                    dotColor: recordingDotColor,
                                    backgroundColor:
                                        Colors.black.withValues(alpha: 0.42),
                                    borderColor: recordingDotColor.withValues(
                                        alpha: 0.45),
                                    onPressed:
                                        canRecord ? _toggleRecording : null,
                                  ),
                                  if (_remoteActivityDetected)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 8),
                                      child: StatusPill(
                                        label: 'Motion detected',
                                        color: AzureTheme.success,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const Positioned(
                              left: 0,
                              right: 0,
                              bottom: 78,
                              child: IgnorePointer(
                                child: Center(
                                  child: LiveDateTimeBadge(),
                                ),
                              ),
                            ),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 12,
                              child: Center(
                                child: PreviewControlBar(
                                  children: [
                                    IconButton.filledTonal(
                                      tooltip: 'Zoom out',
                                      onPressed: canZoomOut
                                          ? () => _adjustMonitorZoom(-0.2)
                                          : null,
                                      style: previewControlIconButtonStyle(),
                                      icon: const Icon(Icons.zoom_out_rounded),
                                    ),
                                    const SizedBox(width: 4),
                                    IconButton.filledTonal(
                                      tooltip: 'Zoom in',
                                      onPressed: canZoomIn
                                          ? () => _adjustMonitorZoom(0.2)
                                          : null,
                                      style: previewControlIconButtonStyle(),
                                      icon: const Icon(Icons.zoom_in_rounded),
                                    ),
                                    const SizedBox(width: 4),
                                    IconButton.filledTonal(
                                      tooltip: 'Toggle monitor audio',
                                      onPressed: cameraMicrophoneEnabled
                                          ? _toggleMonitorAudioPlayback
                                          : null,
                                      style: previewControlIconButtonStyle(),
                                      icon: Icon(
                                        _settings.enableMonitorAudio
                                            ? Icons.volume_up_rounded
                                            : Icons.volume_off_rounded,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    IconButton.filledTonal(
                                      tooltip: 'Toggle day/night',
                                      onPressed: isConnected
                                          ? _requestCameraLightModeToggle
                                          : null,
                                      style: previewControlIconButtonStyle(),
                                      icon: Icon(
                                        remoteViewSettings.cameraLightMode ==
                                                CameraLightMode.night
                                            ? Icons.dark_mode_rounded
                                            : Icons.light_mode_rounded,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    IconButton.filledTonal(
                                      tooltip: 'Fullscreen preview',
                                      onPressed: () => _openFullscreenPreview(
                                          effectiveSettings),
                                      style: previewControlIconButtonStyle(),
                                      icon:
                                          const Icon(Icons.fullscreen_rounded),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
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
                onChanged: (method) {
                  unawaited(_handlePairingMethodChange(method));
                },
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
                'Route status: $_connectionReport. Monitor sessions stay optimized for direct delivery first and keep relay as fallback only.',
            highlights: const [],
            statusTone: _statusTone(),
          ),
        if (_recordingPath != null)
          SurfacePanel(
            child: Text(
              'Recording saved to $_recordingPath',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AzureTheme.ink.withValues(alpha: 0.72),
                  ),
            ),
          ),
      ],
      actions: [
        ElevatedButton(
          onPressed: canConnect ? _connect : null,
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
          onPressed: canDisconnect ? _disconnect : null,
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

  Future<void> _loadPersistedSettings() async {
    final storedSettings = await SettingsStorage.load(
      PersistedSettingsScope.monitor,
      fallback: StreamSettings.monitorDefaults,
    );
    if (!mounted) return;

    setState(() => _settings = _migrateLegacyMonitorSettings(storedSettings));
    _maybeAutoConnectFromInitialPairingLink();
  }

  void _maybeAutoConnectFromInitialPairingLink() {
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
      if (!mounted || _signaling != null || _rtc != null) {
        return;
      }
      unawaited(_connect());
    });
  }

  Future<void> _applyMonitorSettings(
    StreamSettings updatedSettings, {
    bool persist = true,
  }) async {
    if (!mounted) return;

    final responsiveSettings = _responsiveSettings(context, updatedSettings);
    setState(() => _settings = updatedSettings);
    if (persist) {
      await SettingsStorage.save(
        PersistedSettingsScope.monitor,
        updatedSettings,
      );
    }

    await _rtc?.updateSettings(responsiveSettings);
  }

  Future<void> _toggleMonitorAudioPlayback() async {
    await _applyMonitorSettings(
      _settings.copyWith(enableMonitorAudio: !_settings.enableMonitorAudio),
    );
  }

  void _requestCameraLightModeToggle() {
    final signaling = _signaling;
    if (signaling == null || !signaling.isConnected) {
      return;
    }

    final nextMode =
        (_cameraSyncedSettings?.cameraLightMode ?? CameraLightMode.day) ==
                CameraLightMode.night
            ? CameraLightMode.day
            : CameraLightMode.night;

    signaling.send(
      SignalingMessage(
        type: SignalingMessageType.control,
        payload: {
          'action': SignalingControlAction.toggleCameraLightMode,
          'mode': nextMode.name,
        },
      ),
    );

    setState(() {
      _cameraSyncedSettings = (_cameraSyncedSettings ??
              StreamSettings.cameraDefaults.copyWith(
                videoProfile: _settings.videoProfile,
              ))
          .copyWith(cameraLightMode: nextMode);
    });
  }

  StreamSettings _remoteViewSettings(StreamSettings monitorSettings) {
    return _cameraSyncedSettings ?? monitorSettings;
  }

  StreamSettings _migrateLegacyMonitorSettings(StreamSettings settings) {
    final isLegacyDefault = !settings.powerSaveMode &&
        settings.enableMonitorAudio == false &&
        settings.videoQualityPreset == VideoQualityPreset.high &&
        settings.viewerPriority == ViewerPriorityMode.clarity;
    if (!isLegacyDefault) {
      return settings;
    }

    return settings.copyWith(
      enableMonitorAudio: StreamSettings.monitorDefaults.enableMonitorAudio,
    );
  }
}
