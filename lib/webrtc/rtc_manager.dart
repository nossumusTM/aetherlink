import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../config/app_config.dart';
import '../config/stream_settings.dart';
import '../signaling/signaling_message.dart';
import '../utils/app_logger.dart';

enum PeerRole { camera, monitor }

class RtcManager {
  static const MethodChannel _nativeRecordingChannel =
      MethodChannel('teleck/native_recording');
  static const MethodChannel _permissionsChannel =
      MethodChannel('teleck/permissions');

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
  MediaRecorder? _mediaRecorder;
  Timer? _turnFallbackTimer;
  Timer? _activityPollTimer;
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
  String? _captureWarning;
  bool _recordingApiAvailable = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();

  void Function(SignalingMessage message)? onSignal;
  void Function(RTCPeerConnectionState state)? onConnectionState;
  void Function(String diagnostics)? onDiagnosticsChanged;
  void Function(bool activityDetected)? onActivityChanged;

  bool get isTurnFallbackActive => _isTurnFallbackActive;
  bool get isRecording => _mediaRecorder != null || _isNativeRecording;
  StreamSettings get settings => _settings;
  String? get captureWarning => _captureWarning;
  bool get supportsRecording {
    if (!_recordingApiAvailable) return false;
    if (role == PeerRole.camera) return true;

    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  bool get supportsLocalRecording => supportsRecording;
  String get connectionSummary => _buildConnectionSummary();

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

    _peerConnection!.onTrack = (RTCTrackEvent event) {
      if (event.streams.isNotEmpty) {
        remoteRenderer.srcObject = event.streams.first;
        _applyRemoteAudioPlaybackSetting();
      }
    };

    if (role == PeerRole.camera) {
      await _startLocalCapture();
    }

    _scheduleTurnFallback();
    _configureActivityDetection();
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

    localRenderer.srcObject = _localStream;
    if ((_localStream?.getAudioTracks().isNotEmpty ?? false)) {
      localRenderer.muted = true;
    }

    for (final track in _localStream!.getTracks()) {
      await _peerConnection!.addTrack(track, _localStream!);
    }

    await _applyVideoBitrateSettings();
  }

  Future<SignalingMessage> createOffer({bool iceRestart = false}) async {
    final offer = await _peerConnection!.createOffer(
      iceRestart ? {'iceRestart': true} : {},
    );
    await _peerConnection!.setLocalDescription(offer);

    return SignalingMessage(
      type: SignalingMessageType.offer,
      payload: {
        'type': offer.type,
        'sdp': offer.sdp,
        'turnFallback': _isTurnFallbackActive,
      },
    );
  }

  Future<SignalingMessage> createAnswer() async {
    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    return SignalingMessage(
      type: SignalingMessageType.answer,
      payload: {
        'type': answer.type,
        'sdp': answer.sdp,
        'turnFallback': _isTurnFallbackActive,
      },
    );
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
      case SignalingMessageType.join:
        AppLogger.info(
            'Control/join handled by screen coordinator: ${message.payload}');
        break;
    }
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
    _pendingRemoteCandidates.clear();
    _hasRemoteDescription = false;
    await stopRecording();
    await _releaseLocalStream();
    await _peerConnection?.close();
    _peerConnection = null;
    remoteRenderer.srcObject = null;
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

    final videoTracks = stream.getVideoTracks();
    final audioTracks = stream.getAudioTracks();
    final audioChannel = switch (role) {
      PeerRole.camera =>
        audioTracks.isNotEmpty ? RecorderAudioChannel.INPUT : null,
      PeerRole.monitor => _settings.enableMonitorAudio && audioTracks.isNotEmpty
          ? RecorderAudioChannel.OUTPUT
          : null,
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

  void _applyRemoteAudioPlaybackSetting() {
    if (role != PeerRole.monitor || remoteRenderer.srcObject == null) return;

    try {
      remoteRenderer.muted = !_settings.enableMonitorAudio;
    } catch (error, stackTrace) {
      AppLogger.error(
          'Failed to apply monitor audio playback setting', error, stackTrace);
    }
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
        encoding.scaleResolutionDownBy =
            _settings.viewerPriority == ViewerPriorityMode.clarity ? 1.0 : 1.15;
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

  Future<void> _restartLocalCapture() async {
    final peerConnection = _peerConnection;
    if (peerConnection == null) return;

    final previousStream = _localStream;
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

    var requiresRenegotiation = false;

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
    localRenderer.srcObject = updatedStream;
    if ((_localStream?.getAudioTracks().isNotEmpty ?? false)) {
      localRenderer.muted = true;
    }
    await _applyVideoBitrateSettings();

    await _disposeStream(previousStream);

    if (requiresRenegotiation) {
      final offer = await createOffer();
      onSignal?.call(offer);
    }
  }

  Map<String, Object> _buildLocalMediaConstraints(
      {required bool includeAudio}) {
    return {
      'audio': includeAudio,
      'video': {
        'facingMode': 'environment',
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
      if (allowAudioFallback) {
        await _requestMicrophoneAccessIfNeeded();
      }
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

  Future<void> _requestMicrophoneAccessIfNeeded() async {
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      return;
    }

    try {
      final granted = await _permissionsChannel.invokeMethod<bool>(
        'requestMicrophoneAccess',
      );
      if (granted == false) {
        throw StateError('Microphone access denied.');
      }
    } on MissingPluginException {
      // Keep the existing getUserMedia path as a fallback if the channel is
      // unavailable during development reloads.
    } on PlatformException catch (error) {
      throw StateError(
        error.message ?? 'Unable to request microphone access.',
      );
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

  void _emitDiagnostics() {
    onDiagnosticsChanged?.call(_buildConnectionSummary());
  }
}
