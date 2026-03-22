import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../config/app_config.dart';
import '../config/stream_settings.dart';
import '../signaling/signaling_message.dart';
import '../utils/app_logger.dart';

enum PeerRole { camera, monitor, geoPosition, geoMonitor }

class RtcManager {
  static const MethodChannel _nativeRecordingChannel =
      MethodChannel('sputni/native_recording');
  static const MethodChannel _permissionsChannel =
      MethodChannel('sputni/permissions');

  RtcManager({
    required this.role,
    required this.config,
    required StreamSettings settings,
  }) : _settings = settings;

  final PeerRole role;
  final AppConfig config;

  StreamSettings _settings;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  MediaRecorder? _mediaRecorder;
  _WindowsFrameSequenceRecorder? _windowsFrameRecorder;
  Timer? _turnFallbackTimer;
  Timer? _activityPollTimer;
  Timer? _diagnosticsPollTimer;
  final List<RTCIceCandidate> _pendingRemoteCandidates = [];
  bool _isTurnFallbackActive = false;
  bool _isIceRestartInFlight = false;
  bool _hasRemoteDescription = false;
  bool _seenRelayCandidate = false;
  bool _seenSrflxCandidate = false;
  bool _seenHostCandidate = false;
  bool _activityDetected = false;
  bool _activityProbeInFlight = false;
  int? _lastVideoBytesSent;
  bool _isNativeRecording = false;
  bool _isUsingFrontCamera = false;
  bool _isMicrophoneMuted = false;
  String? _captureWarning;
  List<MediaDeviceInfo> _cameraDevices = const [];
  List<String> _cameraDeviceIds = const [];
  String? _selectedCameraDeviceId;
  double _cameraZoomLevel = 1.0;
  RTCDataChannel? _dataChannel;
  bool _recordingApiAvailable = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);
  String? _activeTransportSummary;

  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();

  void Function(SignalingMessage message)? onSignal;
  void Function(RTCPeerConnectionState state)? onConnectionState;
  void Function(String diagnostics)? onDiagnosticsChanged;
  void Function(bool activityDetected)? onActivityChanged;
  void Function(String message)? onDataMessage;
  void Function(RTCDataChannelState state)? onDataChannelState;

  bool get isTurnFallbackActive => _isTurnFallbackActive;
  bool get isRecording =>
      _mediaRecorder != null ||
      _isNativeRecording ||
      _windowsFrameRecorder != null;
  StreamSettings get settings => _settings;
  String? get captureWarning => _captureWarning;
  String? get activeRecordingPath => _windowsFrameRecorder?.outputPath;
  bool get isUsingFrontCamera => _isUsingFrontCamera;
  bool get isMicrophoneMuted => _isMicrophoneMuted;
  bool get canToggleMicrophone =>
      role == PeerRole.camera &&
      (_localStream?.getAudioTracks().isNotEmpty ?? false);
  double get cameraZoomLevel => _cameraZoomLevel;
  bool get supportsCameraFlip =>
      role == PeerRole.camera &&
      !kIsWeb &&
      _cameraDeviceIds.length > 1 &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  bool get supportsCameraZoom =>
      role == PeerRole.camera &&
      !kIsWeb &&
      (_localStream?.getVideoTracks().isNotEmpty ?? false) &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  bool get supportsRecording {
    if (!_recordingApiAvailable) return false;
    if (role == PeerRole.camera) return true;

    if (defaultTargetPlatform == TargetPlatform.windows) {
      return true;
    }

    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  bool get supportsLocalRecording => supportsRecording;
  String get connectionSummary => _buildConnectionSummary();
  bool get isDataChannelOpen =>
      _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;

  Future<void> initialize() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();

    _peerConnection = await createPeerConnection(
      config.peerConnectionConfiguration(
        includeTurn: false,
        useMultipleStunServers: _settings.useMultipleStunServers,
      ),
      {
        'mandatory': {},
        'optional': [
          {'DtlsSrtpKeyAgreement': true},
        ],
      },
    );

    await _configureRoleTransceivers();

    _peerConnection!.onConnectionState = (RTCPeerConnectionState state) {
      _handlePeerConnectionState(state);
      onConnectionState?.call(state);
    };

    _peerConnection!.onIceConnectionState = _handleIceConnectionState;

    _peerConnection!.onIceCandidate = (RTCIceCandidate candidate) {
      if (candidate.candidate == null) return;
      _trackCandidateType(candidate.candidate!);
      onSignal?.call(
        SignalingMessage(
          type: SignalingMessageType.iceCandidate,
          payload: {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        ),
      );
    };

    _peerConnection!.onAddStream = (MediaStream stream) {
      unawaited(_bindRemoteStream(stream));
    };
    _peerConnection!.onAddTrack = (
      MediaStream stream,
      MediaStreamTrack track,
    ) {
      track.enabled = true;
      unawaited(_bindRemoteStream(stream));
    };
    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.track.kind == 'audio' || event.track.kind == 'video') {
        event.track.enabled = true;
      }
      if (event.streams.isNotEmpty) {
        unawaited(_bindRemoteStream(event.streams.first));
      }
    };
    _peerConnection!.onRemoveTrack = (
      MediaStream stream,
      MediaStreamTrack track,
    ) {
      unawaited(_refreshRemoteStream(stream));
    };
    _peerConnection!.onRemoveStream = (MediaStream stream) {
      if (_remoteStream?.id != stream.id) {
        return;
      }
      _remoteStream = null;
      remoteRenderer.srcObject = null;
    };
    _peerConnection!.onDataChannel = _bindDataChannel;

    if (role == PeerRole.camera) {
      await _startLocalCapture();
    }

    if (role == PeerRole.geoPosition) {
      final channel = await _peerConnection!.createDataChannel(
        'sputni-geo',
        RTCDataChannelInit()
          ..ordered = true
          ..maxRetransmits = 3,
      );
      _bindDataChannel(channel);
    }

    _scheduleTurnFallback();
    _configureActivityDetection();
    _configureConnectionDiagnostics();
    _emitDiagnostics();
  }

  // Future<void> _startLocalCapture() async {
  //   final mediaConstraints = {
  //     'audio': false,
  //     'video': {
  //       'facingMode': 'environment',
  //       if (defaultTargetPlatform == TargetPlatform.iOS)
  //         'mandatory': {
  //           'minWidth': '640',
  //           'minHeight': '480',
  //           'minFrameRate': '24',
  //         }
  //       else
  //         'width': 640,
  //     },
  //   };

  //   _localStream = await navigator.mediaDevices.getUserMedia(mediaConstraints);
  //   localRenderer.srcObject = _localStream;

  //   for (final track in _localStream!.getTracks()) {
  //     await _peerConnection!.addTrack(track, _localStream!);
  //   }
  // }

  Future<void> _startLocalCapture() async {
    final devices = await navigator.mediaDevices.enumerateDevices();

    debugPrint('====== RTC DEVICE LIST ======');
    for (final d in devices) {
      debugPrint('device: kind=${d.kind} label=${d.label} id=${d.deviceId}');
    }
    debugPrint('====== END DEVICE LIST ======');
    _cameraDevices =
        devices.where((device) => device.kind == 'videoinput').toList(
              growable: false,
            );
    _cameraDeviceIds = _cameraDevices
        .map((device) => device.deviceId)
        .where((deviceId) => deviceId.trim().isNotEmpty)
        .toList(growable: false);
    _selectedCameraDeviceId ??= _resolveCameraDeviceIdForFacing(
      wantsFront: _isUsingFrontCamera,
    );

    final mediaConstraints = _buildLocalMediaConstraints(
      includeAudio: _settings.enableMicrophone,
    );

    debugPrint(
        'RTC: requesting getUserMedia with constraints: $mediaConstraints');

    _localStream = await _getUserMediaWithFallback(
      mediaConstraints,
      allowAudioFallback: _settings.enableMicrophone,
    );

    debugPrint('RTC: local stream created: ${_localStream?.id}');
    debugPrint('RTC: video tracks = ${_localStream?.getVideoTracks().length}');
    debugPrint('RTC: audio tracks = ${_localStream?.getAudioTracks().length}');

    if (_settings.enableMicrophone &&
        !(_localStream?.getAudioTracks().isNotEmpty ?? false) &&
        _captureWarning == null) {
      _captureWarning =
          'Microphone is unavailable. Live started without audio.';
    }

    await _prepareLocalAudioTracks(_localStream);
    _syncSelectedCameraFromTrack(_localStream);

    localRenderer.srcObject = _localStream;

    await _refreshAvailableCameraDevices();

    for (final track in _orderedTracksForPublishing(_localStream!)) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    await _applyVideoBitrateSettings();
    await _restoreCameraZoomIfNeeded();
  }

  Future<SignalingMessage> createOffer({bool iceRestart = false}) async {
    final constraints = <String, dynamic>{
      'mandatory': {
        'OfferToReceiveAudio': true,
        'OfferToReceiveVideo': true,
      },
      'optional': <dynamic>[],
      if (iceRestart) 'iceRestart': true,
    };
    final offer = await _peerConnection!.createOffer(
      constraints,
    );
    final preferredOffer = RTCSessionDescription(
      _preferVideoCodec(offer.sdp, 'VP8'),
      offer.type,
    );
    await _peerConnection!.setLocalDescription(preferredOffer);

    return SignalingMessage(
      type: SignalingMessageType.offer,
      payload: {
        'type': preferredOffer.type,
        'sdp': preferredOffer.sdp,
        'turnFallback': _isTurnFallbackActive,
      },
    );
  }

  Future<SignalingMessage> createIceRestartOffer() async {
    await _peerConnection!.restartIce();
    return createOffer(iceRestart: true);
  }

  Future<SignalingMessage> createAnswer() async {
    final answer = await _peerConnection!.createAnswer({
      'mandatory': {
        'OfferToReceiveAudio': true,
        'OfferToReceiveVideo': true,
      },
      'optional': <dynamic>[],
    });
    final preferredAnswer = RTCSessionDescription(
      _preferVideoCodec(answer.sdp, 'VP8'),
      answer.type,
    );
    await _peerConnection!.setLocalDescription(preferredAnswer);

    return SignalingMessage(
      type: SignalingMessageType.answer,
      payload: {
        'type': preferredAnswer.type,
        'sdp': preferredAnswer.sdp,
        'turnFallback': _isTurnFallbackActive,
      },
    );
  }

  String _preferVideoCodec(String? sdp, String codecName) {
    if (sdp == null || sdp.isEmpty) {
      return sdp ?? '';
    }

    final lines = sdp.split('\r\n');
    final videoLineIndex = lines.indexWhere((line) => line.startsWith('m=video '));
    if (videoLineIndex == -1) {
      return sdp;
    }

    final preferredPayloads = <String>{};
    final codecPattern =
        RegExp('^a=rtpmap:(\\d+)\\s+$codecName(?:/|\\r?\$)', caseSensitive: false);
    for (final line in lines) {
      final match = codecPattern.firstMatch(line);
      if (match != null) {
        preferredPayloads.add(match.group(1)!);
      }
    }

    if (preferredPayloads.isEmpty) {
      return sdp;
    }

    for (final line in lines) {
      final match = RegExp(r'^a=fmtp:(\d+)\s+.*apt=(\d+)').firstMatch(line);
      if (match != null && preferredPayloads.contains(match.group(2))) {
        preferredPayloads.add(match.group(1)!);
      }
    }

    final sections = lines[videoLineIndex].split(' ');
    if (sections.length <= 3) {
      return sdp;
    }

    final header = sections.sublist(0, 3);
    final payloads = sections.sublist(3);
    final reorderedPayloads = <String>[
      ...payloads.where(preferredPayloads.contains),
      ...payloads.where((payload) => !preferredPayloads.contains(payload)),
    ];
    lines[videoLineIndex] = [...header, ...reorderedPayloads].join(' ');
    return lines.join('\r\n');
  }

  Future<void> updateSettings(StreamSettings settings) async {
    final previousSettings = _settings;
    final shouldReconfigureCapture = role == PeerRole.camera &&
        _localStream != null &&
        (previousSettings.enableMicrophone != settings.enableMicrophone ||
            previousSettings.videoProfile.width !=
                settings.videoProfile.width ||
            previousSettings.videoProfile.height !=
                settings.videoProfile.height ||
            previousSettings.videoProfile.frameRate !=
                settings.videoProfile.frameRate);

    _settings = settings;

    if (shouldReconfigureCapture) {
      await _restartLocalCapture();
    }

    if (previousSettings.useMultipleStunServers !=
        settings.useMultipleStunServers) {
      await _applyIceServerSettings();
    }

    if (previousSettings.enableMonitorAudio != settings.enableMonitorAudio) {
      _applyRemoteAudioPlaybackSetting();
    }

    _configureActivityDetection();
    _scheduleTurnFallback();
    await _applyVideoBitrateSettings();
    _emitDiagnostics();
  }

  Future<void> handleSignalingMessage(SignalingMessage message) async {
    switch (message.type) {
      case SignalingMessageType.offer:
        if (message.payload['turnFallback'] == true) {
          await _activateTurnFallback(
              reason: 'remote-request', renegotiate: false);
        }
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(
            message.payload['sdp'] as String,
            message.payload['type'] as String,
          ),
        );
        _hasRemoteDescription = true;
        await _flushPendingRemoteCandidates();
        final answer = await createAnswer();
        onSignal?.call(answer);
        break;
      case SignalingMessageType.answer:
        await _peerConnection!.setRemoteDescription(
          RTCSessionDescription(
            message.payload['sdp'] as String,
            message.payload['type'] as String,
          ),
        );
        _hasRemoteDescription = true;
        await _flushPendingRemoteCandidates();
        if (message.payload['turnFallback'] == true) {
          await _activateTurnFallback(
              reason: 'relay-answer', renegotiate: false);
        }
        break;
      case SignalingMessageType.iceCandidate:
        final candidate = RTCIceCandidate(
          message.payload['candidate'] as String?,
          message.payload['sdpMid'] as String?,
          message.payload['sdpMLineIndex'] as int?,
        );
        if (!_hasRemoteDescription) {
          _pendingRemoteCandidates.add(candidate);
          return;
        }
        await _peerConnection!.addCandidate(candidate);
        break;
      case SignalingMessageType.control:
      case SignalingMessageType.data:
      case SignalingMessageType.error:
      case SignalingMessageType.join:
        AppLogger.info(
            'Control/join handled by screen coordinator: ${message.payload}');
        break;
      case SignalingMessageType.secureSignal:
        AppLogger.info(
            'secure-signal messages are unwrapped by SignalingClient');
        break;
    }
  }

  Future<void> sendDataMessage(String message) async {
    final dataChannel = _dataChannel;
    if (dataChannel == null ||
        dataChannel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw StateError('Data channel is not open');
    }

    await dataChannel.send(RTCDataChannelMessage(message));
  }

  Future<void> _flushPendingRemoteCandidates() async {
    if (!_hasRemoteDescription || _pendingRemoteCandidates.isEmpty) {
      return;
    }

    final candidates = List<RTCIceCandidate>.from(_pendingRemoteCandidates);
    _pendingRemoteCandidates.clear();

    for (final candidate in candidates) {
      await _peerConnection!.addCandidate(candidate);
    }
  }

  Future<void> dispose() async {
    _turnFallbackTimer?.cancel();
    _activityPollTimer?.cancel();
    _diagnosticsPollTimer?.cancel();
    _pendingRemoteCandidates.clear();
    _hasRemoteDescription = false;
    await stopRecording();
    await _releaseLocalStream();
    await _dataChannel?.close();
    _dataChannel = null;
    await _peerConnection?.close();
    _peerConnection = null;
    remoteRenderer.srcObject = null;
    _remoteStream = null;
    await localRenderer.dispose();
    await remoteRenderer.dispose();
  }

  Future<void> startRecording(String path) async {
    if (!supportsRecording) {
      throw StateError(role == PeerRole.monitor
          ? 'Monitor recording is unavailable on this platform.'
          : 'Local recording is unavailable on this platform.');
    }
    if (_mediaRecorder != null) return;

    final stream =
        role == PeerRole.camera ? _localStream : remoteRenderer.srcObject;
    if (stream == null) {
      throw StateError(role == PeerRole.monitor
          ? 'Remote stream is not initialized.'
          : 'Local stream is not initialized.');
    }

    if (role == PeerRole.camera &&
        defaultTargetPlatform == TargetPlatform.macOS) {
      await _startNativeMacosRecording(path);
      return;
    }

    if (role == PeerRole.camera &&
        defaultTargetPlatform == TargetPlatform.windows) {
      await _startNativeWindowsRecording(path);
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.windows) {
      await _startWindowsFrameRecording(path, stream);
      return;
    }

    final videoTracks = stream.getVideoTracks();
    final audioTracks = stream.getAudioTracks();
    final audioChannel = switch (role) {
      PeerRole.camera =>
        audioTracks.isNotEmpty ? RecorderAudioChannel.INPUT : null,
      PeerRole.monitor => _settings.enableMonitorAudio && audioTracks.isNotEmpty
          ? RecorderAudioChannel.OUTPUT
          : null,
      PeerRole.geoPosition || PeerRole.geoMonitor => null,
    };

    if (audioChannel == null && videoTracks.isEmpty) {
      throw StateError(role == PeerRole.monitor
          ? 'No remote video or audio track available for recording.'
          : 'No local video or audio track available for recording.');
    }

    final recorder = MediaRecorder();
    try {
      await recorder.start(
        path,
        videoTrack: videoTracks.isEmpty ? null : videoTracks.first,
        audioChannel: audioChannel,
      );
    } on MissingPluginException {
      _recordingApiAvailable = false;
      throw StateError(role == PeerRole.monitor
          ? 'Monitor recording is unavailable on this platform.'
          : 'Local recording is unavailable on this platform.');
    }
    _mediaRecorder = recorder;
  }

  Future<void> stopRecording() async {
    if (_windowsFrameRecorder != null) {
      try {
        await _windowsFrameRecorder!.stop();
      } finally {
        _windowsFrameRecorder = null;
      }
      return;
    }

    if (_isNativeRecording) {
      try {
        await _nativeRecordingChannel.invokeMethod<String>('stopRecording');
      } on MissingPluginException {
        _recordingApiAvailable = false;
      } finally {
        _isNativeRecording = false;
      }
      return;
    }

    await _mediaRecorder?.stop();
    _mediaRecorder = null;
  }

  Future<void> _startWindowsFrameRecording(
    String path,
    MediaStream stream,
  ) async {
    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isEmpty) {
      throw StateError(role == PeerRole.monitor
          ? 'No remote video track available for recording.'
          : 'No local video track available for recording.');
    }

    final recorder = _WindowsFrameSequenceRecorder(
      videoTrack: videoTracks.first,
      requestedPath: path,
    );
    try {
      await recorder.start();
      _windowsFrameRecorder = recorder;
    } catch (_) {
      await recorder.dispose();
      rethrow;
    }
  }

  Future<void> _startNativeMacosRecording(String path) async {
    try {
      await _nativeRecordingChannel.invokeMethod<void>(
        'startRecording',
        {
          'path': path,
          'includeAudio': _settings.enableMicrophone,
        },
      );
      _isNativeRecording = true;
    } on MissingPluginException {
      _recordingApiAvailable = false;
      throw StateError('Local recording is unavailable on this platform.');
    } on PlatformException catch (error) {
      throw StateError(error.message ?? 'Unable to start macOS recording.');
    }
  }

  Future<void> _startNativeWindowsRecording(String path) async {
    try {
      await _nativeRecordingChannel.invokeMethod<void>(
        'startRecording',
        {
          'path': path,
          'includeAudio': _settings.enableMicrophone,
        },
      );
      _isNativeRecording = true;
    } on MissingPluginException {
      _recordingApiAvailable = false;
      throw StateError('Local recording is unavailable on this platform.');
    } on PlatformException catch (error) {
      throw StateError(error.message ?? 'Unable to start Windows recording.');
    }
  }

  void _applyRemoteAudioPlaybackSetting() {
    if (role != PeerRole.monitor || remoteRenderer.srcObject == null) return;

    unawaited(_configureRemoteAudioPlayback());
  }

  void _handlePeerConnectionState(RTCPeerConnectionState state) {
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _turnFallbackTimer?.cancel();
        break;
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        unawaited(_activateTurnFallback(reason: 'connection-failed'));
        break;
      default:
        break;
    }
    unawaited(_refreshActiveTransportDiagnostics());
    _emitDiagnostics();
  }

  void _handleIceConnectionState(RTCIceConnectionState state) {
    switch (state) {
      case RTCIceConnectionState.RTCIceConnectionStateConnected:
      case RTCIceConnectionState.RTCIceConnectionStateCompleted:
        _turnFallbackTimer?.cancel();
        break;
      case RTCIceConnectionState.RTCIceConnectionStateFailed:
      case RTCIceConnectionState.RTCIceConnectionStateDisconnected:
        unawaited(_activateTurnFallback(reason: state.name));
        break;
      default:
        break;
    }
    unawaited(_refreshActiveTransportDiagnostics());
    _emitDiagnostics();
  }

  void _scheduleTurnFallback() {
    _turnFallbackTimer?.cancel();

    if (!_settings.preferDirectP2P ||
        !_settings.enableTurnFallback ||
        _isTurnFallbackActive ||
        !config.hasTurnServer) {
      return;
    }

    _turnFallbackTimer = Timer(
      Duration(seconds: config.turnFallbackDelaySeconds),
      () => unawaited(_activateTurnFallback(reason: 'stun-timeout')),
    );
  }

  void _configureActivityDetection() {
    _activityPollTimer?.cancel();
    _lastVideoBytesSent = null;

    if (role != PeerRole.camera || !_settings.activityDetectionEnabled) {
      if (_activityDetected) {
        _activityDetected = false;
        onActivityChanged?.call(false);
      }
      return;
    }

    _activityPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_pollVideoActivity()),
    );
  }

  void _configureConnectionDiagnostics() {
    _diagnosticsPollTimer?.cancel();
    _activeTransportSummary = null;
    _diagnosticsPollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refreshActiveTransportDiagnostics()),
    );
    unawaited(_refreshActiveTransportDiagnostics());
  }

  Future<void> _refreshActiveTransportDiagnostics() async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) {
      return;
    }

    try {
      final reports = await peerConnection.getStats();
      final nextSummary = _resolveActiveTransportSummary(reports);
      if (nextSummary != _activeTransportSummary) {
        _activeTransportSummary = nextSummary;
        _emitDiagnostics();
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to refresh active transport diagnostics',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _pollVideoActivity() async {
    if (_activityProbeInFlight ||
        role != PeerRole.camera ||
        !_settings.activityDetectionEnabled) {
      return;
    }

    final peerConnection = _peerConnection;
    if (peerConnection == null) return;

    _activityProbeInFlight = true;
    try {
      final senders = await peerConnection.getSenders();
      RTCRtpSender? videoSender;
      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          videoSender = sender;
          break;
        }
      }

      if (videoSender == null) return;

      final reports = await videoSender.getStats();
      for (final report in reports) {
        if (report.type != 'outbound-rtp') continue;

        final mediaType = report.values['mediaType'] ?? report.values['kind'];
        if (mediaType != 'video') continue;

        final bytesSent = int.tryParse('${report.values['bytesSent']}');
        if (bytesSent == null) continue;

        final previousBytes = _lastVideoBytesSent;
        _lastVideoBytesSent = bytesSent;
        if (previousBytes == null) return;

        final deltaBytes = bytesSent - previousBytes;
        final bitrateKbps = (deltaBytes * 8) / 2000;
        final thresholdKbps = _settings.maxVideoBitrateKbps <= 450 ? 90 : 140;
        final nextActivityDetected = bitrateKbps >= thresholdKbps;

        if (nextActivityDetected != _activityDetected) {
          _activityDetected = nextActivityDetected;
          onActivityChanged?.call(_activityDetected);
        }
        return;
      }
    } catch (error, stackTrace) {
      AppLogger.error(
          'Failed to poll activity detection stats', error, stackTrace);
    } finally {
      _activityProbeInFlight = false;
    }
  }

  Future<void> _activateTurnFallback({
    required String reason,
    bool renegotiate = true,
  }) async {
    if (_isTurnFallbackActive ||
        _isIceRestartInFlight ||
        !_settings.enableTurnFallback ||
        !config.hasTurnServer) {
      return;
    }

    _isIceRestartInFlight = true;
    _isTurnFallbackActive = true;
    _turnFallbackTimer?.cancel();

    try {
      await _peerConnection?.setConfiguration(
        config.peerConnectionConfiguration(
          includeTurn: true,
          useMultipleStunServers: _settings.useMultipleStunServers,
        ),
      );
      await _peerConnection?.restartIce();
      if (renegotiate) {
        final offer = await createOffer(iceRestart: true);
        onSignal?.call(offer);
      }
      AppLogger.info('TURN fallback activated: $reason');
    } catch (error, stackTrace) {
      AppLogger.error('Failed to activate TURN fallback', error, stackTrace);
    } finally {
      _isIceRestartInFlight = false;
      _emitDiagnostics();
    }
  }

  Future<void> _applyIceServerSettings() async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) return;

    try {
      await peerConnection.setConfiguration(
        config.peerConnectionConfiguration(
          includeTurn: _isTurnFallbackActive,
          useMultipleStunServers: _settings.useMultipleStunServers,
        ),
      );
      await peerConnection.restartIce();
      final offer = await createOffer(iceRestart: true);
      onSignal?.call(offer);
    } catch (error, stackTrace) {
      AppLogger.error('Failed to apply ICE server settings', error, stackTrace);
    }
  }

  Future<void> _applyVideoBitrateSettings() async {
    if (role != PeerRole.camera) return;

    final peerConnection = _peerConnection;
    if (peerConnection == null) return;

    try {
      final senders = await peerConnection.getSenders();
      RTCRtpSender? videoSender;

      for (final sender in senders) {
        if (sender.track?.kind == 'video') {
          videoSender = sender;
          break;
        }
      }

      if (videoSender == null) return;

      final parameters = videoSender.parameters;
      final encodings =
          parameters.encodings ?? <RTCRtpEncoding>[RTCRtpEncoding()];
      if (encodings.isEmpty) {
        encodings.add(RTCRtpEncoding());
      }

      final maxBitrate = _settings.maxVideoBitrateKbps * 1000;
      for (final encoding in encodings) {
        encoding.maxBitrate = maxBitrate;
        encoding.priority = _encodingPriorityFor(_settings.viewerPriority);
        encoding.maxFramerate = _settings.videoProfile.frameRate > 0
            ? _settings.videoProfile.frameRate
            : (_settings.viewerPriority == ViewerPriorityMode.smooth ? 30 : 24);
        encoding.scaleResolutionDownBy = _settings.powerSaveMode ||
                _settings.viewerPriority == ViewerPriorityMode.smooth
            ? 1.15
            : 1.0;
      }

      parameters.encodings = encodings;
      parameters.degradationPreference =
          _degradationPreferenceFor(_settings.viewerPriority);
      await videoSender.setParameters(parameters);
    } catch (error, stackTrace) {
      AppLogger.error(
          'Failed to apply video bitrate settings', error, stackTrace);
    }
  }

  Future<void> _restartLocalCapture({
    bool forceRenegotiation = false,
    bool releasePreviousFirst = false,
  }) async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) return;

    final previousStream = _localStream;
    if (releasePreviousFirst) {
      localRenderer.srcObject = null;
      _localStream = null;
      await _disposeStream(previousStream);
    }
    final updatedStream = await _getUserMediaWithFallback(
      _buildLocalMediaConstraints(includeAudio: _settings.enableMicrophone),
      allowAudioFallback: _settings.enableMicrophone,
    );

    final senders = await peerConnection.getSenders();
    RTCRtpSender? videoSender;
    RTCRtpSender? audioSender;
    for (final sender in senders) {
      if (sender.track?.kind == 'video') {
        videoSender = sender;
      } else if (sender.track?.kind == 'audio') {
        audioSender = sender;
      }
    }

    final newVideoTrack = updatedStream.getVideoTracks().isNotEmpty
        ? updatedStream.getVideoTracks().first
        : null;
    final newAudioTrack = updatedStream.getAudioTracks().isNotEmpty
        ? updatedStream.getAudioTracks().first
        : null;

    var requiresRenegotiation = forceRenegotiation;

    if (newVideoTrack != null) {
      if (videoSender != null) {
        await videoSender.replaceTrack(newVideoTrack);
      } else {
        await peerConnection.addTrack(newVideoTrack, updatedStream);
        requiresRenegotiation = true;
      }
    }

    if (audioSender != null && newAudioTrack == null) {
      await peerConnection.removeTrack(audioSender);
      requiresRenegotiation = true;
    } else if (audioSender == null && newAudioTrack != null) {
      await peerConnection.addTrack(newAudioTrack, updatedStream);
      requiresRenegotiation = true;
    } else if (audioSender != null && newAudioTrack != null) {
      await audioSender.replaceTrack(newAudioTrack);
    }

    _localStream = updatedStream;
    await _prepareLocalAudioTracks(updatedStream);
    _syncSelectedCameraFromTrack(updatedStream);
    localRenderer.srcObject = updatedStream;
    await _refreshAvailableCameraDevices();
    await _applyVideoBitrateSettings();
    await _restoreCameraZoomIfNeeded();

    if (!releasePreviousFirst) {
      await _disposeStream(previousStream);
    }

    if (requiresRenegotiation) {
      final offer = await createOffer();
      onSignal?.call(offer);
    }
  }

  Map<String, Object> _buildLocalMediaConstraints(
      {required bool includeAudio}) {
    final preferredDeviceId = _preferredCameraDeviceId();
    return {
      'audio': includeAudio
          ? {
              'echoCancellation': true,
              'noiseSuppression': true,
              'autoGainControl': true,
              'channelCount': 1,
            }
          : false,
      'video': {
        if (preferredDeviceId != null) 'deviceId': preferredDeviceId,
        if (preferredDeviceId == null)
          'facingMode': _isUsingFrontCamera ? 'user' : 'environment',
        'width': _settings.videoProfile.width,
        'height': _settings.videoProfile.height,
        'frameRate': _settings.videoProfile.frameRate,
      },
    };
  }

  Future<MediaStream> _getUserMediaWithFallback(
    Map<String, Object> mediaConstraints, {
    required bool allowAudioFallback,
  }) async {
    try {
      _captureWarning = null;
      await _requestMediaPermissionsIfNeeded(includeAudio: allowAudioFallback);
      return await navigator.mediaDevices.getUserMedia(mediaConstraints);
    } catch (error, stackTrace) {
      final canRetryWithoutAudio =
          allowAudioFallback && _isPermissionStyleCaptureError(error);
      if (!canRetryWithoutAudio) rethrow;

      AppLogger.error(
        'Audio capture failed, retrying camera startup without microphone',
        error,
        stackTrace,
      );

      _captureWarning =
          'Microphone access was denied. Live started without audio.';
      final fallbackConstraints = _buildLocalMediaConstraints(
        includeAudio: false,
      );
      debugPrint(
        'RTC: retrying getUserMedia without audio: $fallbackConstraints',
      );
      return navigator.mediaDevices.getUserMedia(fallbackConstraints);
    }
  }

  Future<void> _requestMediaPermissionsIfNeeded({
    required bool includeAudio,
  }) async {
    if (role != PeerRole.camera || kIsWeb) {
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.android) {
      await _requestNativePermission(
        'requestCameraAccess',
        deniedMessage: 'Camera access denied.',
        unsupportedPlatformsAreNoop: false,
      );
      if (includeAudio) {
        await _requestNativePermission(
          'requestMicrophoneAccess',
          deniedMessage: 'Microphone access denied.',
          unsupportedPlatformsAreNoop: false,
        );
      }
      return;
    }

    if (includeAudio && defaultTargetPlatform == TargetPlatform.macOS) {
      await _requestNativePermission(
        'requestMicrophoneAccess',
        deniedMessage: 'Microphone access denied.',
        unsupportedPlatformsAreNoop: true,
      );
    }
  }

  Future<void> _requestNativePermission(
    String method, {
    required String deniedMessage,
    required bool unsupportedPlatformsAreNoop,
  }) async {
    try {
      final granted = await _permissionsChannel.invokeMethod<bool>(method);
      if (granted == false) {
        throw StateError(deniedMessage);
      }
    } on MissingPluginException {
      if (!unsupportedPlatformsAreNoop) {
        rethrow;
      }
      // Keep the existing getUserMedia path as a fallback if the channel is
      // unavailable during development reloads.
    } on PlatformException catch (error) {
      throw StateError(error.message ?? deniedMessage);
    }
  }

  Future<bool> openMicrophoneSettings() async {
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      return false;
    }

    try {
      return await _permissionsChannel.invokeMethod<bool>(
            'openMicrophoneSettings',
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> flipCamera() async {
    if (!supportsCameraFlip) {
      return false;
    }

    final previousFacing = _isUsingFrontCamera;
    final previousDeviceId = _selectedCameraDeviceId;
    final videoTracks = _localStream?.getVideoTracks() ?? const [];

    if (videoTracks.isNotEmpty) {
      try {
        _isUsingFrontCamera = await Helper.switchCamera(videoTracks.first);
        _selectedCameraDeviceId = _resolveCameraDeviceIdForFacing(
          wantsFront: _isUsingFrontCamera,
        );
        await _refreshAvailableCameraDevices();
        await _restoreCameraZoomIfNeeded();
        return true;
      } catch (error, stackTrace) {
        _isUsingFrontCamera = previousFacing;
        _selectedCameraDeviceId = previousDeviceId;
        AppLogger.error(
          'Native camera switch failed, retrying capture restart',
          error,
          stackTrace,
        );
      }
    }

    final targetDeviceId = _resolveCameraDeviceIdForFacing(
      wantsFront: !previousFacing,
      excludingDeviceId: previousDeviceId,
    );

    if (targetDeviceId != null) {
      _isUsingFrontCamera = !previousFacing;
      _selectedCameraDeviceId = targetDeviceId;
      try {
        await _restartLocalCapture(
          forceRenegotiation: true,
          releasePreviousFirst: true,
        );
        return true;
      } catch (error, stackTrace) {
        _isUsingFrontCamera = previousFacing;
        _selectedCameraDeviceId = previousDeviceId;
        AppLogger.error(
          'Camera restart switch failed',
          error,
          stackTrace,
        );
      }
    }

    _isUsingFrontCamera = !previousFacing;
    try {
      await _restartLocalCapture(forceRenegotiation: true);
      return true;
    } catch (error, stackTrace) {
      _isUsingFrontCamera = previousFacing;
      AppLogger.error(
        'Fallback capture restart failed',
        error,
        stackTrace,
      );
      rethrow;
    }
  }

  bool _isPermissionStyleCaptureError(Object error) {
    if (error is PlatformException) {
      final code = error.code.toLowerCase();
      final message = (error.message ?? '').toLowerCase();
      return code.contains('notallowed') ||
          code.contains('permission') ||
          message.contains('notallowed') ||
          message.contains('permission');
    }

    final errorText = error.toString().toLowerCase();
    return errorText.contains('notallowed') ||
        errorText.contains('permission') ||
        errorText.contains('denied');
  }

  Future<void> _releaseLocalStream() async {
    localRenderer.srcObject = null;
    await _disposeStream(_localStream);
    _localStream = null;
  }

  Future<void> _disposeStream(MediaStream? stream) async {
    for (final track in stream?.getTracks() ?? const <MediaStreamTrack>[]) {
      await track.stop();
    }
    await stream?.dispose();
  }

  Future<void> _refreshAvailableCameraDevices() async {
    if (kIsWeb || role != PeerRole.camera) {
      return;
    }

    try {
      final devices = await navigator.mediaDevices.enumerateDevices();
      _cameraDevices =
          devices.where((device) => device.kind == 'videoinput').toList(
                growable: false,
              );
      _cameraDeviceIds = _cameraDevices
          .map((device) => device.deviceId)
          .where((deviceId) => deviceId.trim().isNotEmpty)
          .toList(growable: false);
    } catch (error, stackTrace) {
      AppLogger.error('Unable to refresh available cameras', error, stackTrace);
    }
  }

  Future<double> setCameraZoom(double zoomLevel) async {
    final clampedZoom = zoomLevel.clamp(1.0, 4.0).toDouble();
    final videoTracks = _localStream?.getVideoTracks() ?? const [];
    if (!supportsCameraZoom || videoTracks.isEmpty) {
      _cameraZoomLevel = 1.0;
      return _cameraZoomLevel;
    }

    await Helper.setZoom(videoTracks.first, clampedZoom);
    _cameraZoomLevel = clampedZoom;
    return _cameraZoomLevel;
  }

  Future<void> setMicrophoneMuted(bool muted) async {
    if (!canToggleMicrophone) {
      _isMicrophoneMuted = false;
      return;
    }

    for (final track
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      await Helper.setMicrophoneMute(muted, track);
      track.enabled = !muted;
    }
    _isMicrophoneMuted = muted;
  }

  Future<void> toggleMicrophoneMuted() async {
    await setMicrophoneMuted(!_isMicrophoneMuted);
  }

  Future<void> _restoreCameraZoomIfNeeded() async {
    if (!supportsCameraZoom || _cameraZoomLevel <= 1.0) {
      return;
    }

    try {
      await setCameraZoom(_cameraZoomLevel);
    } catch (error, stackTrace) {
      AppLogger.error('Failed to restore camera zoom', error, stackTrace);
    }
  }

  Future<void> _prepareLocalAudioTracks(MediaStream? stream) async {
    for (final track
        in stream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      try {
        await Helper.setMicrophoneMute(_isMicrophoneMuted, track);
        track.enabled = !_isMicrophoneMuted;
      } catch (error, stackTrace) {
        AppLogger.error(
          'Failed to ensure local microphone track stays enabled',
          error,
          stackTrace,
        );
      }
    }
  }

  List<MediaStreamTrack> _orderedTracksForPublishing(MediaStream stream) {
    return [
      ...stream.getAudioTracks(),
      ...stream.getVideoTracks(),
      ...stream.getTracks().where(
            (track) => track.kind != 'audio' && track.kind != 'video',
          ),
    ];
  }

  String? _preferredCameraDeviceId() {
    if (_cameraDevices.isEmpty) {
      return null;
    }

    if (_selectedCameraDeviceId != null &&
        _cameraDevices
            .any((device) => device.deviceId == _selectedCameraDeviceId)) {
      return _selectedCameraDeviceId;
    }

    if (defaultTargetPlatform != TargetPlatform.android) {
      return null;
    }

    return _resolveCameraDeviceIdForFacing(
      wantsFront: _isUsingFrontCamera,
      excludingDeviceId: _selectedCameraDeviceId,
    );
  }

  String? _resolveCameraDeviceIdForFacing({
    required bool wantsFront,
    String? excludingDeviceId,
  }) {
    if (_cameraDevices.isEmpty) {
      return null;
    }

    const frontKeywords = ['front', 'user', 'selfie'];
    const rearKeywords = ['back', 'rear', 'environment'];

    for (final device in _cameraDevices) {
      if (device.deviceId == excludingDeviceId) continue;
      final label = device.label.toLowerCase();
      if (label.isEmpty) continue;

      final matchesFront = frontKeywords.any(label.contains);
      final matchesRear = rearKeywords.any(label.contains);
      if (wantsFront && matchesFront) {
        return device.deviceId;
      }
      if (!wantsFront && matchesRear) {
        return device.deviceId;
      }
    }

    for (final device in _cameraDevices) {
      if (device.deviceId != excludingDeviceId) {
        return device.deviceId;
      }
    }

    return _cameraDevices.first.deviceId;
  }

  void _syncSelectedCameraFromTrack(MediaStream? stream) {
    final videoTracks = stream?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (videoTracks.isEmpty || _cameraDevices.isEmpty) {
      return;
    }

    final activeLabel = (videoTracks.first.label ?? '').toLowerCase().trim();
    if (activeLabel.isEmpty) {
      return;
    }

    for (final device in _cameraDevices) {
      if (device.label.toLowerCase().trim() == activeLabel) {
        _selectedCameraDeviceId = device.deviceId;
        final label = device.label.toLowerCase();
        if (label.contains('front') ||
            label.contains('user') ||
            label.contains('selfie')) {
          _isUsingFrontCamera = true;
        } else if (label.contains('back') ||
            label.contains('rear') ||
            label.contains('environment')) {
          _isUsingFrontCamera = false;
        }
        return;
      }
    }
  }

  Future<void> _configureRemoteAudioPlayback() async {
    try {
      final remoteStream = _remoteStream ?? remoteRenderer.srcObject;
      for (final track
          in remoteStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
        track.enabled = _settings.enableMonitorAudio;
      }

      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        if (_settings.enableMonitorAudio) {
          await Helper.ensureAudioSession();
          await Helper.setSpeakerphoneOnButPreferBluetooth();
        } else {
          await Helper.setSpeakerphoneOn(false);
        }
      }

      if (defaultTargetPlatform == TargetPlatform.macOS &&
          _settings.enableMonitorAudio) {
        await _routeDesktopAudioOutput();
      }

      await remoteRenderer.setVolume(_settings.enableMonitorAudio ? 1.0 : 0.0);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Failed to apply monitor audio playback setting',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _configureRoleTransceivers() async {
    if (role != PeerRole.monitor) {
      return;
    }

    await _peerConnection!.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    await _peerConnection!.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
  }

  void _bindDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    channel.onDataChannelState = (state) {
      onDataChannelState?.call(state);
    };
    channel.onMessage = (message) {
      if (message.isBinary) {
        return;
      }
      onDataMessage?.call(message.text);
    };
  }

  Future<void> _bindRemoteStream(MediaStream stream) async {
    for (final track in stream.getTracks()) {
      track.enabled = true;
    }

    _remoteStream = stream;
    if (remoteRenderer.srcObject?.id != stream.id) {
      remoteRenderer.srcObject = stream;
    }
    _applyRemoteAudioPlaybackSetting();
  }

  Future<void> _refreshRemoteStream(MediaStream stream) async {
    if (stream.getTracks().isEmpty) {
      if (_remoteStream?.id == stream.id) {
        _remoteStream = null;
        remoteRenderer.srcObject = null;
      }
      return;
    }

    await _bindRemoteStream(stream);
  }

  Future<void> _routeDesktopAudioOutput() async {
    final devices = await navigator.mediaDevices.enumerateDevices();
    for (final device in devices) {
      if (device.kind != 'audiooutput' || device.deviceId.trim().isEmpty) {
        continue;
      }
      await remoteRenderer.audioOutput(device.deviceId);
      return;
    }
  }

  RTCPriorityType _encodingPriorityFor(ViewerPriorityMode mode) {
    switch (mode) {
      case ViewerPriorityMode.balanced:
        return RTCPriorityType.medium;
      case ViewerPriorityMode.smooth:
        return RTCPriorityType.low;
      case ViewerPriorityMode.clarity:
        return RTCPriorityType.high;
    }
  }

  RTCDegradationPreference _degradationPreferenceFor(ViewerPriorityMode mode) {
    switch (mode) {
      case ViewerPriorityMode.balanced:
        return RTCDegradationPreference.BALANCED;
      case ViewerPriorityMode.smooth:
        return RTCDegradationPreference.MAINTAIN_FRAMERATE;
      case ViewerPriorityMode.clarity:
        return RTCDegradationPreference.MAINTAIN_RESOLUTION;
    }
  }

  void _trackCandidateType(String candidate) {
    if (candidate.contains(' typ relay ')) {
      _seenRelayCandidate = true;
    }
    if (candidate.contains(' typ srflx ')) {
      _seenSrflxCandidate = true;
    }
    if (candidate.contains(' typ host ')) {
      _seenHostCandidate = true;
    }
    _emitDiagnostics();
  }

  String _buildConnectionSummary() {
    if (_activeTransportSummary != null) {
      return _activeTransportSummary!;
    }

    final transport =
        _isTurnFallbackActive ? 'TURN fallback armed' : 'P2P first';
    final candidates = [
      if (_seenHostCandidate) 'host',
      if (_seenSrflxCandidate) 'srflx',
      if (_seenRelayCandidate) 'relay',
    ];
    if (candidates.isEmpty) {
      return '$transport · gathering candidates';
    }
    return '$transport · seen ${candidates.join('/')}';
  }

  String? _resolveActiveTransportSummary(List<StatsReport> reports) {
    if (reports.isEmpty) {
      return null;
    }

    final reportsById = <String, StatsReport>{
      for (final report in reports) report.id: report,
    };

    StatsReport? selectedPair;
    for (final report in reports) {
      if (report.type == 'transport') {
        final selectedPairId =
            report.values['selectedCandidatePairId']?.toString();
        if (selectedPairId != null && selectedPairId.isNotEmpty) {
          selectedPair = reportsById[selectedPairId];
          if (selectedPair != null) {
            break;
          }
        }
      }
    }

    selectedPair ??= reports.cast<StatsReport?>().firstWhere(
          (report) =>
              report?.type == 'candidate-pair' &&
              (report?.values['selected'] == true ||
                  report?.values['nominated'] == true ||
                  report?.values['state'] == 'succeeded'),
          orElse: () => null,
        );

    if (selectedPair == null) {
      return null;
    }

    final localCandidateId =
        selectedPair.values['localCandidateId']?.toString() ?? '';
    final remoteCandidateId =
        selectedPair.values['remoteCandidateId']?.toString() ?? '';
    final localCandidate =
        localCandidateId.isEmpty ? null : reportsById[localCandidateId];
    final remoteCandidate =
        remoteCandidateId.isEmpty ? null : reportsById[remoteCandidateId];
    final localType = localCandidate?.values['candidateType']?.toString();
    final remoteType = remoteCandidate?.values['candidateType']?.toString();
    final candidateTypes = <String>{
      if (localType != null && localType.isNotEmpty) localType,
      if (remoteType != null && remoteType.isNotEmpty) remoteType,
    };

    if (candidateTypes.contains('relay')) {
      return 'WebRTC active · TURN relay';
    }
    if (candidateTypes.contains('srflx') || candidateTypes.contains('prflx')) {
      return 'WebRTC active · STUN direct';
    }
    if (candidateTypes.contains('host')) {
      return 'WebRTC active · direct P2P';
    }
    return 'WebRTC active';
  }

  void _emitDiagnostics() {
    onDiagnosticsChanged?.call(_buildConnectionSummary());
  }
}

class _WindowsFrameSequenceRecorder {
  _WindowsFrameSequenceRecorder({
    required this.videoTrack,
    required this.requestedPath,
  });

  final MediaStreamTrack videoTrack;
  final String requestedPath;

  Timer? _timer;
  Future<void> _pendingCapture = Future<void>.value();
  bool _captureInFlight = false;
  int _frameIndex = 0;
  late final Directory _outputDirectory;

  String get outputPath => requestedPath;

  Future<void> start() async {
    final sanitizedPath = requestedPath.trim();
    if (sanitizedPath.isEmpty) {
      throw StateError('Recording path is invalid.');
    }

    final tempDirectory = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}sputni_recording_${DateTime.now().microsecondsSinceEpoch}',
    );
    _outputDirectory = tempDirectory;
    await _outputDirectory.create(recursive: true);

    await _captureOnce();
    _timer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) {
        _pendingCapture = _captureOnce();
      },
    );
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _pendingCapture;

    if (_frameIndex == 0) {
      throw StateError('No frames were captured for Windows recording.');
    }

    final tempOutputPath =
        '${_outputDirectory.path}${Platform.pathSeparator}recording.mp4';

    try {
      await RtcManager._nativeRecordingChannel.invokeMethod<void>(
        'composeFrameSequence',
        {
          'inputDirectory': _outputDirectory.path,
          'outputPath': tempOutputPath,
          'frameRate': 5,
        },
      );

      final renderedFile = File(tempOutputPath);
      if (!await renderedFile.exists()) {
        throw StateError(
            'Windows recording encoder did not produce an MP4 file.');
      }

      final targetFile = File(requestedPath);
      if (await targetFile.exists()) {
        await targetFile.delete();
      }
      await renderedFile.copy(requestedPath);
    } finally {
      if (await _outputDirectory.exists()) {
        await _outputDirectory.delete(recursive: true);
      }
    }
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    await _pendingCapture;
  }

  Future<void> _captureOnce() async {
    if (_captureInFlight) {
      return;
    }
    _captureInFlight = true;
    try {
      final frameBuffer = await videoTrack.captureFrame();
      final frameBytes = frameBuffer.asUint8List();
      if (frameBytes.isEmpty) {
        return;
      }

      final frameFile = File(
        '${_outputDirectory.path}${Platform.pathSeparator}${_frameIndex.toString().padLeft(6, '0')}.png',
      );
      await frameFile.writeAsBytes(frameBytes, flush: false);
      _frameIndex += 1;
    } catch (error) {
      if (_frameIndex == 0) {
        throw StateError('Unable to capture Windows recording frames: $error');
      }
    } finally {
      _captureInFlight = false;
    }
  }
}
