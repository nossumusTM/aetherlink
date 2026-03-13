import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../config/app_config.dart';
import '../config/stream_settings.dart';
import '../signaling/control_actions.dart';
import '../signaling/signaling_client.dart';
import '../signaling/signaling_message.dart';
import '../ui/azure_theme.dart';
import '../utils/app_logger.dart';
import '../utils/recording_storage.dart';
import '../utils/room_security.dart';
import '../webrtc/rtc_manager.dart';
import '../widgets/app_shell_ui.dart';
import '../widgets/pairing_panel.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  final _roomController = TextEditingController(text: 'first-channel');
  static const _autoDimDelay = Duration(minutes: 3);

  late final AppConfig _config;
  SignalingClient? _signaling;
  RtcManager? _rtc;
  Timer? _autoDimTimer;
  StreamSettings _settings = StreamSettings.cameraDefaults;
  PairingMethod _pairingMethod = PairingMethod.roomId;
  String _status = 'Standby';
  String _connectionReport = 'P2P first · waiting to start';
  String? _recordingPath;
  bool _isAutoDimmed = false;
  Timer? _offerRetryTimer;
  bool _isSendingOffer = false;
  bool _awaitingAnswer = false;

  String get _resolvedRoomId {
    final value = _roomController.text.trim();
    return value.isEmpty ? 'first-channel' : value;
  }

  String get _transmissionRoomId => secureRoomToken(_resolvedRoomId);

  StreamSettings _responsiveSettings(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return _settings.resolvedForViewport(
      screenWidth: size.width,
      screenHeight: size.height,
      role: StreamViewportRole.camera,
    );
  }

  @override
  void initState() {
    super.initState();
    _config = AppConfig.fromEnvironment();
    _syncAutoDimTimer();
  }

  Future<void> _startStreaming() async {
    if (_signaling != null || _rtc != null) return;

    final effectiveSettings = _responsiveSettings(context);
    final signaling = SignalingClient(serverUrl: _config.signalingUrl);
    final rtc = RtcManager(
      role: PeerRole.camera,
      config: _config,
      settings: effectiveSettings,
    );

    signaling.onConnected = () {
      setState(() => _status = 'Session broker ready');
      signaling.send(
        SignalingMessage(
          type: SignalingMessageType.join,
          payload: {'roomId': _transmissionRoomId, 'role': 'camera'},
        ),
      );
      signaling.send(
        const SignalingMessage(
          type: SignalingMessageType.control,
          payload: {'action': SignalingControlAction.start},
        ),
      );
      signaling.send(
        const SignalingMessage(
          type: SignalingMessageType.control,
          payload: {'action': SignalingControlAction.cameraReady},
        ),
      );
    };

    signaling.onMessage = (message) async {
      if (message.type == SignalingMessageType.join &&
          message.payload['role'] == 'monitor') {
        await _sendOfferIfPossible(
          rtc: rtc,
          signaling: signaling,
          reason: 'monitor-joined',
        );
      }
      if (message.type == SignalingMessageType.control) {
        if (message.payload['action'] == SignalingControlAction.monitorReady) {
          await _sendOfferIfPossible(
            rtc: rtc,
            signaling: signaling,
            reason: 'monitor-ready',
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
      setState(() => _status = 'Connection issue');
      AppLogger.error('Camera signaling error', error, stack);
    };

    signaling.onDisconnected = () {
      _resetNegotiationState();
      if (mounted) {
        setState(() => _status = 'Session closed');
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

    setState(() => _settings = updatedSettings);
    _syncAutoDimTimer();
    final rtc = _rtc;
    if (rtc != null) {
      await rtc.updateSettings(_responsiveSettings(context));
      if (!mounted) return;
      setState(() => _settings = rtc.settings);
      _showCaptureWarning(rtc);
    }
  }

  Future<void> _openQrCodeModal(String payload) {
    return showPairingQrCodeModal(
      context: context,
      payload: payload,
      title: 'QR pairing',
      subtitle: 'Scan this code on the monitor to pair instantly.',
    );
  }

  Future<void> _openFullscreenPreview(StreamSettings effectiveSettings) {
    final rtc = _rtc;
    if (rtc == null) return Future.value();

    return showFullscreenPreview(
      context: context,
      renderer: rtc.localRenderer,
      objectFit: effectiveSettings.rtcVideoFit,
      mirror: false,
      lowLightBoost: effectiveSettings.lowLightBoost,
      profileLabel: effectiveSettings.videoDisplayLabel,
    );
  }

  Future<void> _toggleRecording() async {
    final rtc = _rtc;
    if (rtc == null) return;

    try {
      if (rtc.isRecording) {
        await rtc.stopRecording();
        if (!mounted) return;
        setState(() => _status = 'Recording saved');
        return;
      }

      final recordingsDirectory = await resolveRecordingDirectory(_settings);

      if (!await recordingsDirectory.exists()) {
        await recordingsDirectory.create(recursive: true);
      }

      final filePath =
          '${recordingsDirectory.path}${Platform.pathSeparator}camera_${DateTime.now().millisecondsSinceEpoch}.mp4';

      await rtc.startRecording(filePath);

      if (!mounted) return;
      setState(() {
        _recordingPath = filePath;
        _status = 'Recording locally';
      });
    } on StateError catch (error, stackTrace) {
      AppLogger.error('Unable to start recording', error, stackTrace);
      if (!mounted) return;
      setState(() => _status = error.message);
    } catch (error, stackTrace) {
      AppLogger.error('Unable to start recording', error, stackTrace);
      if (!mounted) return;
      setState(() => _status = 'Recording unavailable');
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

  Future<void> _sendOfferIfPossible({
    required RtcManager rtc,
    required SignalingClient signaling,
    required String reason,
  }) async {
    if (_isSendingOffer || _awaitingAnswer || !signaling.isConnected) {
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
    _signaling?.disconnect();
    _rtc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isStreaming = _rtc != null;
    final canStart = !isStreaming;
    final canStop = isStreaming;
    final canRecord = _rtc?.supportsLocalRecording ?? false;
    final effectiveSettings = _responsiveSettings(context);
    final pairingPayload = buildPairingPayload(
      roomId: _transmissionRoomId,
      signalingUrl: _config.signalingUrl,
      role: 'camera',
    );

    return AppShell(
      title: 'Camera',
      subtitle:
          'Live camera controls with P2P connection and adaptive capture.',
      hero: SurfacePanel(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusPill(
                  label: _status,
                  color: _statusColor(),
                ),
                const Spacer(),
                if (_rtc?.isRecording ?? false)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: StatusPill(
                      label: 'REC',
                      color: Color(0xFFD7263D),
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
                          child: Text(
                            'Preview unavailable until streaming starts',
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            RTCVideoView(
                              _rtc!.localRenderer,
                              mirror: false,
                              objectFit: effectiveSettings.rtcVideoFit,
                            ),
                            if (effectiveSettings.lowLightBoost)
                              Container(
                                color: Colors.lightBlueAccent
                                    .withValues(alpha: 0.08),
                              ),
                            Positioned(
                              left: 12,
                              bottom: 12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.35),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.12),
                                  ),
                                ),
                                child: Text(
                                  effectiveSettings.videoProfileLabel,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              right: 12,
                              bottom: 12,
                              child: IconButton.filledTonal(
                                onPressed: () =>
                                    _openFullscreenPreview(effectiveSettings),
                                icon: const Icon(Icons.fullscreen_rounded),
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
                  if (method == PairingMethod.qrCode) {
                    _openQrCodeModal(pairingPayload);
                    return;
                  }
                  setState(() => _pairingMethod = method);
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _roomController,
                decoration: const InputDecoration(labelText: 'Room ID'),
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
        if (isStreaming)
          OutlinedButton(
            onPressed: canRecord ? _toggleRecording : null,
            child: Text(
              canRecord
                  ? ((_rtc?.isRecording ?? false) ? 'Stop rec' : 'Start rec')
                  : 'Recording unavailable',
            ),
          ),
      ],
    );
  }
}
