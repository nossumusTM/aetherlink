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

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({super.key});

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen> {
  final _roomController = TextEditingController(text: 'first-channel');

  late final AppConfig _config;
  SignalingClient? _signaling;
  RtcManager? _rtc;
  StreamSettings _settings = StreamSettings.monitorDefaults;
  PairingMethod _pairingMethod = PairingMethod.roomId;
  String _status = 'Standby';
  String _connectionReport = 'P2P first · idle';
  String? _recordingPath;
  bool _didAutoOpenFullscreen = false;
  Timer? _monitorPresenceTimer;

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
      role: StreamViewportRole.monitor,
    );
  }

  @override
  void initState() {
    super.initState();
    _config = AppConfig.fromEnvironment();
  }

  Future<void> _connect() async {
    if (_signaling != null || _rtc != null) return;

    final effectiveSettings = _responsiveSettings(context);
    final signaling = SignalingClient(serverUrl: _config.signalingUrl);
    final rtc = RtcManager(
      role: PeerRole.monitor,
      config: _config,
      settings: effectiveSettings,
    );

    signaling.onConnected = () {
      setState(() => _status = 'Session broker ready');
      signaling.send(
        SignalingMessage(
          type: SignalingMessageType.join,
          payload: {'roomId': _transmissionRoomId, 'role': 'monitor'},
        ),
      );
      _startMonitorPresence(signaling);
    };

    signaling.onMessage = (message) async {
      if (message.type == SignalingMessageType.join &&
          message.payload['role'] == 'camera') {
        _sendMonitorReady(signaling);
      }
      if (message.type == SignalingMessageType.control) {
        final action = message.payload['action'];
        if (action == SignalingControlAction.cameraReady) {
          _sendMonitorReady(signaling);
        }
        if (mounted &&
            (action == SignalingControlAction.start ||
                action == SignalingControlAction.stop)) {
          setState(() => _status = _controlStatusLabel(action?.toString()));
        }
      }
      await rtc.handleSignalingMessage(message);
    };

    signaling.onError = (error, [stack]) {
      setState(() => _status = 'Connection issue');
      AppLogger.error('Monitor signaling error', error, stack);
    };

    signaling.onDisconnected = () {
      _stopMonitorPresence();
      if (mounted) {
        setState(() => _status = 'Session closed');
      }
    };

    rtc.onSignal = signaling.send;
    rtc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _stopMonitorPresence();
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _startMonitorPresence(signaling);
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

    setState(() => _settings = updatedSettings);
    await _rtc?.updateSettings(_responsiveSettings(context));
    _maybeOpenFullscreenAfterConnect();
  }

  Future<void> _openQrCodeModal(String payload) {
    return showPairingQrCodeModal(
      context: context,
      payload: payload,
      title: 'QR pairing',
      subtitle: 'Share this monitor pairing code without opening the camera.',
    );
  }

  Future<void> _openFullscreenPreview(StreamSettings effectiveSettings) {
    final rtc = _rtc;
    if (rtc == null) return Future.value();

    return showFullscreenPreview(
      context: context,
      renderer: rtc.remoteRenderer,
      objectFit: effectiveSettings.rtcVideoFit,
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
          '${recordingsDirectory.path}${Platform.pathSeparator}monitor_${DateTime.now().millisecondsSinceEpoch}.mp4';

      await rtc.startRecording(filePath);

      if (!mounted) return;
      setState(() {
        _recordingPath = filePath;
        _status = 'Recording locally';
      });
    } on StateError catch (error, stackTrace) {
      AppLogger.error('Unable to start monitor recording', error, stackTrace);
      if (!mounted) return;
      setState(() => _status = error.message);
    } catch (error, stackTrace) {
      AppLogger.error('Unable to start monitor recording', error, stackTrace);
      if (!mounted) return;
      setState(() => _status = 'Recording unavailable');
    }
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
    if (!signaling.isConnected) return;

    signaling.send(
      const SignalingMessage(
        type: SignalingMessageType.control,
        payload: {'action': SignalingControlAction.monitorReady},
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
    _signaling?.disconnect();
    _rtc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _rtc != null;
    final canConnect = !isConnected;
    final canDisconnect = isConnected;
    final canRecord = _rtc?.supportsRecording ?? false;
    final effectiveSettings = _responsiveSettings(context);
    final pairingPayload = buildPairingPayload(
      roomId: _transmissionRoomId,
      signalingUrl: _config.signalingUrl,
      role: 'monitor',
    );

    return AppShell(
      title: 'Monitor',
      subtitle: 'Viewer dashboard with controls and connection diagnostics.',
      hero: SurfacePanel(
        padding: const EdgeInsets.all(14),
        child: Column(
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
              aspectRatio: _resolvedMonitorAspectRatio(effectiveSettings),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Color(0xFF081A33)),
                  child: _rtc == null
                      ? const Center(
                          child: Text(
                            'Remote feed will appear here',
                            style: TextStyle(color: Colors.white70),
                          ),
                        )
                      : Stack(
                          fit: StackFit.expand,
                          children: [
                            RTCVideoView(
                              _rtc!.remoteRenderer,
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
        if (isConnected)
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

  double _resolvedMonitorAspectRatio(StreamSettings effectiveSettings) =>
      effectiveSettings.videoProfile.previewAspectRatio;
}
