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

const ColorFilter _nightModePreviewFilter = ColorFilter.matrix([
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

class CameraScreen extends StatefulWidget {
  const CameraScreen({
    super.key,
    this.initialPairingLink,
    this.autoStartOnLoad = false,
  });

  final String? initialPairingLink;
  final bool autoStartOnLoad;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  final _roomController = TextEditingController();
  final _pairingLinkController = TextEditingController();
  static const _autoDimDelay = Duration(minutes: 3);

  late final AppConfig _config;
  SignalingClient? _signaling;
  RtcManager? _rtc;
  Timer? _autoDimTimer;
  StreamSettings _settings = StreamSettings.cameraDefaults;
  PairingMethod _pairingMethod = PairingMethod.qrCode;
  String _status = 'Standby';
  String _connectionReport = 'P2P first · waiting to start';
  String? _recordingPath;
  DateTime? _recordingStartedAt;
  bool _activityDetected = false;
  bool _isAutoDimmed = false;
  Timer? _offerRetryTimer;
  bool _isSendingOffer = false;
  bool _awaitingAnswer = false;
  String? _qrPairingRoomId;
  String? _localDeviceId;
  String? _qrPairingSecret;
  bool _hasTriggeredInitialAutoStart = false;
  bool _isQrModalVisible = false;
  BuildContext? _qrDialogContext;
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
        role: 'camera',
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
      role: StreamViewportRole.camera,
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
    _syncAutoDimTimer();
    unawaited(_loadPairingIdentity());
    _loadPersistedSettings();
  }

  Future<void> _loadPairingIdentity() async {
    final deviceId = await DeviceIdentityStorage.loadOrCreateDeviceId();
    final pairingRoomId = await DeviceIdentityStorage.roomIdForRole('camera');
    final pairingSecret =
        await DeviceIdentityStorage.pairingSecretForRole('camera');
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
        pairingData.role?.trim().toLowerCase() != 'monitor' ||
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
      launchRole: 'camera',
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

  void _sendCameraReady([SignalingClient? signalingOverride]) {
    final signaling = signalingOverride ?? _signaling;
    if (signaling == null ||
        !signaling.isConnected ||
        !_hasJoinedSignalingRoom) {
      return;
    }

    signaling.send(
      const SignalingMessage(
        type: SignalingMessageType.control,
        payload: {'action': SignalingControlAction.cameraReady},
      ),
    );
  }

  Future<void> _startStreaming() async {
    if (_signaling != null || _rtc != null) return;

    final effectiveSettings = _responsiveSettings(context);
    final signaling = SignalingClient(
      serverUrl: _resolvedSignalingUrl,
      cipher: await _buildPairingCipher(),
    );
    final rtc = RtcManager(
      role: PeerRole.camera,
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
            'role': 'camera',
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
        signaling.send(
          const SignalingMessage(
            type: SignalingMessageType.control,
            payload: {'action': SignalingControlAction.start},
          ),
        );
        _sendCameraReady(signaling);
        _sendOwnPairingPayload(signaling);
        _sendCameraSettingsSync(signaling);
        _sendActivityDetectionUpdate(_activityDetected, signaling);
      }
      if (message.type == SignalingMessageType.join &&
          message.payload['role'] == 'monitor') {
        _dismissQrModalIfVisible();
        await _saveRemotePairingPayload(
          message.payload['pairingPayload']?.toString(),
        );
        _sendOwnPairingPayload(signaling);
        _sendCameraSettingsSync(signaling);
        _sendActivityDetectionUpdate(_activityDetected, signaling);
        await _sendOfferIfPossible(
          rtc: rtc,
          signaling: signaling,
          reason: 'monitor-joined',
        );
      }
      if (message.type == SignalingMessageType.control) {
        final action = message.payload['action'];
        if (action == SignalingControlAction.monitorReady) {
          await _saveRemotePairingPayload(
            message.payload['pairingPayload']?.toString(),
          );
          _sendOwnPairingPayload(signaling);
          _sendCameraSettingsSync(signaling);
          _sendActivityDetectionUpdate(_activityDetected, signaling);
          await _sendOfferIfPossible(
            rtc: rtc,
            signaling: signaling,
            reason: 'monitor-ready',
          );
        }
        if (action == SignalingControlAction.pairingLinkSync) {
          await _saveRemotePairingPayload(
            message.payload['pairingPayload']?.toString(),
          );
        }
        if (action == SignalingControlAction.toggleCameraLightMode) {
          final requestedMode = _parseCameraLightMode(
            message.payload['mode']?.toString(),
          );
          await _applyCameraSettings(
            _settings.copyWith(
              cameraLightMode: requestedMode ??
                  (_settings.cameraLightMode == CameraLightMode.day
                      ? CameraLightMode.night
                      : CameraLightMode.day),
            ),
          );
        }
        AppLogger.info('Camera received control: ${message.payload}');
      }
      if (message.type == SignalingMessageType.answer) {
        _offerRetryTimer?.cancel();
        _offerRetryTimer = null;
        _awaitingAnswer = false;
      }
      await rtc.handleSignalingMessage(message);
    };

    signaling.onError = (error, [stack]) {
      if (mounted && !_hasActiveSecureLink) {
        setState(() => _status = 'Connection issue');
      }
      AppLogger.error('Camera signaling error', error, stack);
    };

    signaling.onDisconnected = () {
      _hasJoinedSignalingRoom = false;
      _resetNegotiationState();
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
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _offerRetryTimer?.cancel();
        _offerRetryTimer = null;
        _awaitingAnswer = false;
      }
      if (mounted) {
        setState(() => _status = _peerStateLabel(state));
      }
    };
    rtc.onDiagnosticsChanged = (diagnostics) {
      if (mounted) {
        setState(() => _connectionReport = diagnostics);
      }
    };
    rtc.onActivityChanged = (activityDetected) {
      if (mounted) {
        setState(() => _activityDetected = activityDetected);
      }
      _sendActivityDetectionUpdate(activityDetected, signaling);
    };

    try {
      await rtc.initialize();
      if (!mounted) return;
      setState(() {
        _settings = rtc.settings;
        _rtc = rtc;
        _status = 'Camera preview ready';
        _connectionReport = rtc.connectionSummary;
      });
      _showCaptureWarning(rtc);

      await signaling.connect();

      if (!mounted) return;
      setState(() {
        _signaling = signaling;
        _status = 'Waiting for viewer';
        _connectionReport = rtc.connectionSummary;
      });
    } catch (error, stackTrace) {
      AppLogger.error('Unable to start camera streaming', error, stackTrace);
      await signaling.disconnect();
      await rtc.dispose();
      _resetNegotiationState();
      if (!mounted) return;
      setState(() {
        _signaling = null;
        _rtc = null;
        _status = _cameraStartErrorLabel(error);
        _connectionReport = 'P2P first · idle';
      });
    }
  }

  Future<void> _stopStreaming() async {
    _signaling?.send(
      const SignalingMessage(
        type: SignalingMessageType.control,
        payload: {'action': SignalingControlAction.stop},
      ),
    );

    await _signaling?.disconnect();
    await _rtc?.dispose();
    _resetNegotiationState();

    if (!mounted) return;
    setState(() {
      _signaling = null;
      _rtc = null;
      _status = 'Standby';
      _connectionReport = 'P2P first · idle';
      _activityDetected = false;
    });
  }

  Future<void> _openSettings() async {
    final updatedSettings = await showSettingsSheet(
      context: context,
      title: 'Camera settings',
      initialSettings: _settings,
      turnAvailable: _config.hasTurnServer,
      mode: SettingsSheetMode.camera,
    );

    if (updatedSettings == null || !mounted) return;

    await _applyCameraSettings(updatedSettings);
  }

  Future<void> _openQrCodeModal(String payload) {
    _isQrModalVisible = true;
    return showPairingQrCodeModal(
      context: context,
      payload: payload,
      title: 'QR pairing',
      subtitle: 'Scan this code on the monitor to pair instantly.',
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
      launchRole: 'camera',
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

    return showFullscreenPreview(
      context: context,
      renderer: rtc.localRenderer,
      objectFit: _previewObjectFit(effectiveSettings),
      mirror: rtc.isUsingFrontCamera,
      lowLightBoost: effectiveSettings.lowLightBoost,
      monochrome: effectiveSettings.cameraLightMode == CameraLightMode.night,
      profileLabel: effectiveSettings.videoProfileLabel,
      preferPortrait: Platform.isAndroid &&
          effectiveSettings.videoDisplayMode == VideoDisplayMode.portrait,
      contentScale: effectiveSettings.cameraViewScale,
      topCenterOverlay: const LiveDateTimeBadge(),
    );
  }

  Future<void> _flipCamera() async {
    final rtc = _rtc;
    if (rtc == null || !rtc.supportsCameraFlip) return;

    try {
      final switched = await rtc.flipCamera();
      if (!mounted || !switched) return;

      setState(() {});
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 2),
            content: Text(
              rtc.isUsingFrontCamera
                  ? 'Front camera active.'
                  : 'Rear camera active.',
            ),
          ),
        );
    } catch (error, stackTrace) {
      AppLogger.error('Unable to flip camera', error, stackTrace);
    }
  }

  Future<void> _toggleCameraLightMode() async {
    final nextMode = _settings.cameraLightMode == CameraLightMode.night
        ? CameraLightMode.day
        : CameraLightMode.night;
    await _applyCameraSettings(
      _settings.copyWith(cameraLightMode: nextMode),
    );
  }

  Future<void> _adjustCameraZoom(double delta) async {
    final rtc = _rtc;
    if (rtc == null || !rtc.supportsCameraZoom) return;

    try {
      await rtc.setCameraZoom(rtc.cameraZoomLevel + delta);
      if (mounted) {
        setState(() {});
      }
    } catch (error, stackTrace) {
      AppLogger.error('Unable to update camera zoom', error, stackTrace);
    }
  }

  Future<void> _toggleCameraMicrophone() async {
    final rtc = _rtc;
    if (rtc == null || !rtc.canToggleMicrophone) return;

    try {
      await rtc.toggleMicrophoneMuted();
      if (mounted) {
        setState(() {});
      }
    } catch (error, stackTrace) {
      AppLogger.error(
          'Unable to update camera microphone state', error, stackTrace);
    }
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
          '${recordingsDirectory.path}${Platform.pathSeparator}camera_${recordingStartedAt.millisecondsSinceEpoch}.mp4';

      await rtc.startRecording(filePath);

      if (!mounted) return;
      setState(() {
        _recordingPath = rtc.activeRecordingPath ?? filePath;
        _recordingStartedAt = recordingStartedAt;
        _status = 'Recording locally';
      });
    } on StateError catch (error, stackTrace) {
      AppLogger.error('Unable to start recording', error, stackTrace);
      if (!mounted) return;
      setState(() => _status = error.message);
    } catch (error, stackTrace) {
      AppLogger.error('Unable to start recording', error, stackTrace);
      if (!mounted) return;
      setState(() => _status = error.toString());
    }
  }

  void _registerActivity() {
    if (!_settings.automaticPowerSavingMode) return;

    _autoDimTimer?.cancel();
    if (_isAutoDimmed) {
      setState(() => _isAutoDimmed = false);
    }

    _autoDimTimer = Timer(_autoDimDelay, () {
      if (!mounted || !_settings.automaticPowerSavingMode) return;
      setState(() => _isAutoDimmed = true);
    });
  }

  void _syncAutoDimTimer() {
    if (!_settings.automaticPowerSavingMode) {
      _autoDimTimer?.cancel();
      if (_isAutoDimmed) {
        setState(() => _isAutoDimmed = false);
      }
      return;
    }

    _registerActivity();
  }

  Future<void> _loadPersistedSettings() async {
    final storedSettings = await SettingsStorage.load(
      PersistedSettingsScope.camera,
      fallback: StreamSettings.cameraDefaults,
    );
    if (!mounted) return;

    setState(() => _settings = _migrateLegacyCameraSettings(storedSettings));
    _syncAutoDimTimer();
    _maybeAutoStartFromInitialPairingLink();
  }

  void _maybeAutoStartFromInitialPairingLink() {
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
      if (!mounted || _signaling != null || _rtc != null) {
        return;
      }
      unawaited(_startStreaming());
    });
  }

  Future<void> _applyCameraSettings(
    StreamSettings updatedSettings, {
    bool persist = true,
  }) async {
    if (!mounted) return;

    final responsiveSettings = _responsiveSettings(context, updatedSettings);
    setState(() => _settings = updatedSettings);
    _syncAutoDimTimer();
    if (persist) {
      await SettingsStorage.save(
        PersistedSettingsScope.camera,
        updatedSettings,
      );
    }

    final rtc = _rtc;
    if (rtc != null) {
      await rtc.updateSettings(responsiveSettings);
      if (!mounted) return;
      setState(() => _settings = rtc.settings);
      _showCaptureWarning(rtc);
    }

    _sendCameraSettingsSync();
  }

  void _sendCameraSettingsSync([SignalingClient? signalingOverride]) {
    final signaling = signalingOverride ?? _signaling;
    if (!mounted ||
        signaling == null ||
        !signaling.isConnected ||
        !_hasJoinedSignalingRoom) {
      return;
    }

    signaling.send(
      SignalingMessage(
        type: SignalingMessageType.control,
        payload: {
          'action': SignalingControlAction.cameraSettingsUpdated,
          'settings': _responsiveSettings(context).toRemoteSyncMap(),
        },
      ),
    );
  }

  void _sendActivityDetectionUpdate(
    bool activityDetected, [
    SignalingClient? signalingOverride,
  ]) {
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
          'action': SignalingControlAction.cameraActivityUpdated,
          'activityDetected': activityDetected,
        },
      ),
    );
  }

  CameraLightMode? _parseCameraLightMode(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }

    for (final mode in CameraLightMode.values) {
      if (mode.name == value) {
        return mode;
      }
    }
    return null;
  }

  Future<void> _sendOfferIfPossible({
    required RtcManager rtc,
    required SignalingClient signaling,
    required String reason,
  }) async {
    if (_isSendingOffer ||
        _awaitingAnswer ||
        !signaling.isConnected ||
        !_hasJoinedSignalingRoom) {
      return;
    }

    _isSendingOffer = true;
    try {
      final offer = await rtc.createOffer();
      if (!signaling.isConnected) return;
      signaling.send(offer);
      _awaitingAnswer = true;
      _scheduleOfferRetry(rtc: rtc, signaling: signaling);
      AppLogger.info('Camera sent offer after $reason');
    } catch (error, stackTrace) {
      AppLogger.error('Failed to create camera offer', error, stackTrace);
    } finally {
      _isSendingOffer = false;
    }
  }

  void _resetNegotiationState() {
    _offerRetryTimer?.cancel();
    _offerRetryTimer = null;
    _isSendingOffer = false;
    _awaitingAnswer = false;
  }

  void _scheduleOfferRetry({
    required RtcManager rtc,
    required SignalingClient signaling,
  }) {
    _offerRetryTimer?.cancel();
    _offerRetryTimer = Timer(const Duration(seconds: 3), () {
      _awaitingAnswer = false;
      unawaited(
        _sendOfferIfPossible(
          rtc: rtc,
          signaling: signaling,
          reason: 'answer-timeout',
        ),
      );
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

  String _cameraStartErrorLabel(Object error) {
    final message = error.toString();
    if (message.contains('NotAllowedError') ||
        message.toLowerCase().contains('permission')) {
      return 'Camera access denied';
    }
    return 'Unable to start live view';
  }

  void _showCaptureWarning(RtcManager rtc) {
    final warning = rtc.captureWarning;
    if (!mounted || warning == null || warning.isEmpty) return;

    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(warning),
          action: Platform.isMacOS
              ? SnackBarAction(
                  label: 'Open settings',
                  onPressed: () {
                    rtc.openMicrophoneSettings();
                  },
                )
              : null,
        ),
      );
  }

  bool _isAndroidMobileView(StreamSettings effectiveSettings) =>
      Platform.isAndroid &&
      effectiveSettings.videoDisplayMode == VideoDisplayMode.portrait;

  RTCVideoViewObjectFit _previewObjectFit(StreamSettings effectiveSettings) =>
      (Platform.isAndroid || Platform.isIOS)
          ? RTCVideoViewObjectFit.RTCVideoViewObjectFitCover
          : effectiveSettings.rtcVideoFit;

  Widget _buildCameraPreviewVideo({
    required RTCVideoViewObjectFit objectFit,
    required bool monochrome,
  }) {
    final rtc = _rtc;
    if (rtc == null) {
      return const SizedBox.shrink();
    }

    final video = RTCVideoView(
      rtc.localRenderer,
      mirror: rtc.isUsingFrontCamera,
      objectFit: objectFit,
    );

    if (Platform.isAndroid || !monochrome) {
      return video;
    }

    return ColorFiltered(
      colorFilter: _nightModePreviewFilter,
      child: video,
    );
  }

  MetricTone _statusTone() {
    if (_rtc == null) return MetricTone.neutral;
    if (_status == 'Secure link active') {
      return MetricTone.good;
    }
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
    _autoDimTimer?.cancel();
    _resetNegotiationState();
    _roomController.dispose();
    _pairingLinkController.dispose();
    _signaling?.send(
      const SignalingMessage(
        type: SignalingMessageType.control,
        payload: {'action': SignalingControlAction.stop},
      ),
    );
    _signaling?.disconnect();
    _rtc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isStreaming = _rtc != null;
    final canStart = !isStreaming && _hasValidPairingSelection;
    final canStop = isStreaming;
    final effectiveSettings = _responsiveSettings(context);
    final previewFit = _previewObjectFit(effectiveSettings);
    final isAndroidMobileView = _isAndroidMobileView(effectiveSettings);
    final canRecord = _rtc?.supportsLocalRecording ?? false;
    final cameraZoomLevel = _rtc?.cameraZoomLevel ?? 1.0;
    final canZoomOut =
        (_rtc?.supportsCameraZoom ?? false) && cameraZoomLevel > 1.0;
    final canZoomIn =
        (_rtc?.supportsCameraZoom ?? false) && cameraZoomLevel < 4.0;
    final canToggleMicrophone = _rtc?.canToggleMicrophone ?? false;
    final recordingDotColor = (_rtc?.isRecording ?? false)
        ? const Color(0xFFD7263D)
        : (_recordingPath != null ? AzureTheme.success : Colors.white);

    return AppShell(
      title: 'Camera',
      subtitle:
          'Live camera controls with P2P connection and adaptive capture.',
      hero: SurfacePanel(
        padding: isAndroidMobileView
            ? const EdgeInsets.fromLTRB(10, 10, 10, 12)
            : const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
                  decoration: const BoxDecoration(color: Color(0xFF0A1830)),
                  child: _rtc == null
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              'Preview unavailable until streaming starts',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white70),
                            ),
                          ),
                        )
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            Semantics(
                              label: 'Local camera preview',
                              image: true,
                              child: ExcludeSemantics(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Transform.scale(
                                      scale: effectiveSettings.cameraViewScale,
                                      child: _buildCameraPreviewVideo(
                                        objectFit: previewFit,
                                        monochrome:
                                            effectiveSettings.cameraLightMode ==
                                                CameraLightMode.night,
                                      ),
                                    ),
                                    if (effectiveSettings.cameraLightMode ==
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
                            if (_rtc!.supportsCameraFlip)
                              Positioned(
                                top: 12,
                                right: 12,
                                child: IconButton.filledTonal(
                                  onPressed: _flipCamera,
                                  tooltip: 'Switch camera',
                                  style: previewControlIconButtonStyle(),
                                  icon: const Icon(Icons.cameraswitch_rounded),
                                ),
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
                                  if (_activityDetected)
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
                            if (effectiveSettings.lowLightBoost)
                              Container(
                                color: Colors.lightBlueAccent
                                    .withValues(alpha: 0.08),
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
                                          ? () => _adjustCameraZoom(-0.25)
                                          : null,
                                      style: previewControlIconButtonStyle(),
                                      icon: const Icon(Icons.zoom_out_rounded),
                                    ),
                                    const SizedBox(width: 4),
                                    IconButton.filledTonal(
                                      tooltip: 'Zoom in',
                                      onPressed: canZoomIn
                                          ? () => _adjustCameraZoom(0.25)
                                          : null,
                                      style: previewControlIconButtonStyle(),
                                      icon: const Icon(Icons.zoom_in_rounded),
                                    ),
                                    if (canToggleMicrophone) ...[
                                      const SizedBox(width: 4),
                                      IconButton.filledTonal(
                                        tooltip: 'Toggle camera audio',
                                        onPressed: _toggleCameraMicrophone,
                                        style: previewControlIconButtonStyle(),
                                        icon: Icon(
                                          _rtc?.isMicrophoneMuted ?? false
                                              ? Icons.mic_off_rounded
                                              : Icons.mic_rounded,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(width: 4),
                                    IconButton.filledTonal(
                                      tooltip: 'Toggle day/night',
                                      onPressed: isStreaming
                                          ? _toggleCameraLightMode
                                          : null,
                                      style: previewControlIconButtonStyle(),
                                      icon: Icon(
                                        effectiveSettings.cameraLightMode ==
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
                'Route status: $_connectionReport. Secure device pairing is active and relay remains a last-resort path.',
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
          onPressed: canStart ? _startStreaming : null,
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.play_circle_fill_rounded),
              SizedBox(width: 8),
              Text('Start live'),
            ],
          ),
        ),
        OutlinedButton(
          onPressed: canStop ? _stopStreaming : null,
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

  StreamSettings _migrateLegacyCameraSettings(StreamSettings settings) {
    final matchesOldDefaults = !settings.powerSaveMode &&
        settings.maxVideoBitrateKbps <= 1200 &&
        settings.videoQualityPreset == VideoQualityPreset.auto &&
        settings.viewerPriority == ViewerPriorityMode.balanced &&
        settings.enableMicrophone == false;
    final matchesUpdatedDefaultsWithoutMic = !settings.powerSaveMode &&
        settings.maxVideoBitrateKbps ==
            StreamSettings.cameraDefaults.maxVideoBitrateKbps &&
        settings.videoQualityPreset ==
            StreamSettings.cameraDefaults.videoQualityPreset &&
        settings.viewerPriority ==
            StreamSettings.cameraDefaults.viewerPriority &&
        settings.enableMicrophone == false;
    if (!matchesOldDefaults && !matchesUpdatedDefaultsWithoutMic) {
      return settings;
    }

    return settings.copyWith(
      enableMicrophone: StreamSettings.cameraDefaults.enableMicrophone,
      maxVideoBitrateKbps: StreamSettings.cameraDefaults.maxVideoBitrateKbps,
      viewerPriority: StreamSettings.cameraDefaults.viewerPriority,
      videoQualityPreset: StreamSettings.cameraDefaults.videoQualityPreset,
    );
  }
}
