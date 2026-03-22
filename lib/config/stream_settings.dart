import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum ViewerPriorityMode { balanced, smooth, clarity }

enum VideoDisplayMode { landscape, portrait }

enum StreamViewportRole { camera, monitor }

enum VideoQualityPreset { auto, dataSaver, balanced, high }

enum ExposureMode { high, balanced, low }

enum CameraLightMode { day, night }

enum CameraViewMode { standard, panorama }

enum DeviceViewportClass { phone, tablet, desktop }

enum RecordingDirectoryMode { documents, appSupport, temporary, custom }

extension DeviceViewportClassResolver on DeviceViewportClass {
  static DeviceViewportClass fromViewport({
    required double screenWidth,
    required double screenHeight,
  }) {
    final shortestSide =
        screenWidth < screenHeight ? screenWidth : screenHeight;
    final longestSide = screenWidth > screenHeight ? screenWidth : screenHeight;
    final platform = defaultTargetPlatform;
    final isDesktopPlatform = kIsWeb ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux;

    if (isDesktopPlatform) {
      return DeviceViewportClass.desktop;
    }
    if (shortestSide >= 700 || longestSide >= 1100) {
      return DeviceViewportClass.tablet;
    }
    return DeviceViewportClass.phone;
  }
}

class VideoProfile {
  const VideoProfile({
    required this.width,
    required this.height,
    required this.frameRate,
    required this.previewAspectRatio,
    required this.label,
  });

  final int width;
  final int height;
  final int frameRate;
  final double previewAspectRatio;
  final String label;

  VideoProfile copyWith({
    int? width,
    int? height,
    int? frameRate,
    double? previewAspectRatio,
    String? label,
  }) {
    return VideoProfile(
      width: width ?? this.width,
      height: height ?? this.height,
      frameRate: frameRate ?? this.frameRate,
      previewAspectRatio: previewAspectRatio ?? this.previewAspectRatio,
      label: label ?? this.label,
    );
  }

  static const cameraPowerSave = VideoProfile(
    width: 640,
    height: 360,
    frameRate: 15,
    previewAspectRatio: 9 / 16,
    label: 'Power save',
  );

  Map<String, dynamic> toMap() => {
        'width': width,
        'height': height,
        'frameRate': frameRate,
        'previewAspectRatio': previewAspectRatio,
        'label': label,
      };

  static VideoProfile? fromMap(Map<String, dynamic>? map) {
    if (map == null) return null;

    final width = map['width'];
    final height = map['height'];
    final frameRate = map['frameRate'];
    final previewAspectRatio = map['previewAspectRatio'];
    final label = map['label'];

    if (width is! int ||
        height is! int ||
        frameRate is! int ||
        previewAspectRatio is! num ||
        label is! String) {
      return null;
    }

    return VideoProfile(
      width: width,
      height: height,
      frameRate: frameRate,
      previewAspectRatio: previewAspectRatio.toDouble(),
      label: label,
    );
  }

  static VideoProfile powerSaveFor(DeviceViewportClass deviceClass) {
    final isPhone = deviceClass == DeviceViewportClass.phone;
    return VideoProfile(
      width: isPhone ? 640 : 960,
      height: isPhone ? 1136 : 540,
      frameRate: 15,
      previewAspectRatio: isPhone ? 9 / 16 : 16 / 9,
      label: switch (deviceClass) {
        DeviceViewportClass.phone => '640x1136 power save',
        DeviceViewportClass.tablet => '960x540 power save',
        DeviceViewportClass.desktop => '960x540 power save',
      },
    );
  }

  static VideoProfile adaptive({
    required double screenWidth,
    required double screenHeight,
    required StreamViewportRole role,
    required VideoQualityPreset preset,
  }) {
    final deviceClass = DeviceViewportClassResolver.fromViewport(
      screenWidth: screenWidth,
      screenHeight: screenHeight,
    );
    final isPhone = deviceClass == DeviceViewportClass.phone;
    final previewAspectRatio = isPhone ? 9 / 16 : 16 / 9;

    if (role == StreamViewportRole.camera) {
      if (preset == VideoQualityPreset.dataSaver) {
        return VideoProfile(
          width: isPhone ? 540 : 960,
          height: isPhone ? 960 : 540,
          frameRate: 18,
          previewAspectRatio: previewAspectRatio,
          label: isPhone ? '540x960 saver' : '960x540 saver',
        );
      }
      if (preset == VideoQualityPreset.balanced) {
        return VideoProfile(
          width: isPhone ? 720 : 1280,
          height: isPhone ? 1280 : 720,
          frameRate: 24,
          previewAspectRatio: previewAspectRatio,
          label: isPhone ? '720x1280 balanced' : '1280x720 balanced',
        );
      }
      if (preset == VideoQualityPreset.high) {
        return VideoProfile(
          width: isPhone ? 1080 : 1920,
          height: isPhone ? 1920 : 1080,
          frameRate: 30,
          previewAspectRatio: previewAspectRatio,
          label: isPhone ? '1080x1920 high' : '1920x1080 high',
        );
      }

      return VideoProfile(
        width: isPhone ? 1080 : 1920,
        height: isPhone ? 1920 : 1080,
        frameRate: isPhone ? 24 : 30,
        previewAspectRatio: previewAspectRatio,
        label: switch (deviceClass) {
          DeviceViewportClass.phone => '1080x1920 phone',
          DeviceViewportClass.tablet => '1920x1080 tablet',
          DeviceViewportClass.desktop => '1920x1080 desktop',
        },
      );
    }

    return VideoProfile(
      width: 0,
      height: 0,
      frameRate: 0,
      previewAspectRatio: previewAspectRatio,
      label: switch (deviceClass) {
        DeviceViewportClass.phone => '1080x1920 phone',
        DeviceViewportClass.tablet => '1920x1080 tablet',
        DeviceViewportClass.desktop => '1920x1080 desktop',
      },
    );
  }

  VideoProfile adjustedForCameraView({
    required VideoDisplayMode displayMode,
    required CameraViewMode cameraViewMode,
  }) {
    final targetAspectRatio = _cameraPreviewAspectRatio(
      displayMode: displayMode,
      cameraViewMode: cameraViewMode,
    );
    final longEdge = math.max(width, height);

    final adjustedWidth = displayMode == VideoDisplayMode.landscape
        ? longEdge
        : (longEdge * targetAspectRatio).round();
    final adjustedHeight = displayMode == VideoDisplayMode.landscape
        ? (longEdge / targetAspectRatio).round()
        : longEdge;

    final modeSuffix =
        cameraViewMode == CameraViewMode.panorama ? ' panorama' : '';

    return copyWith(
      width: adjustedWidth,
      height: adjustedHeight,
      previewAspectRatio: targetAspectRatio,
      label: '${adjustedWidth}x$adjustedHeight$modeSuffix',
    );
  }
}

class StreamSettings {
  static const Object _recordingDirectorySentinel = Object();

  const StreamSettings({
    this.preferDirectP2P = true,
    this.enableTurnFallback = true,
    this.useMultipleStunServers = true,
    this.powerSaveMode = false,
    this.automaticPowerSavingMode = false,
    this.enableMicrophone = true,
    this.maxVideoBitrateKbps = 2800,
    this.lowLightBoost = true,
    this.showConnectionReport = true,
    this.exposureMode = ExposureMode.balanced,
    this.cameraLightMode = CameraLightMode.day,
    this.cameraViewMode = CameraViewMode.standard,
    this.activityDetectionEnabled = false,
    this.enableMonitorAudio = true,
    this.autoFullscreenOnConnect = false,
    this.viewerPriority = ViewerPriorityMode.clarity,
    this.videoDisplayMode,
    this.videoQualityPreset = VideoQualityPreset.high,
    this.recordingDirectoryMode = RecordingDirectoryMode.appSupport,
    this.customRecordingDirectoryPath,
    this.customRecordingDirectoryUri,
    this.videoProfile = const VideoProfile(
      width: 960,
      height: 540,
      frameRate: 24,
      previewAspectRatio: 9 / 16,
      label: '540p mobile',
    ),
  });

  final bool preferDirectP2P;
  final bool enableTurnFallback;
  final bool useMultipleStunServers;
  final bool powerSaveMode;
  final bool automaticPowerSavingMode;
  final bool enableMicrophone;
  final int maxVideoBitrateKbps;
  final bool lowLightBoost;
  final bool showConnectionReport;
  final ExposureMode exposureMode;
  final CameraLightMode cameraLightMode;
  final CameraViewMode cameraViewMode;
  final bool activityDetectionEnabled;
  final bool enableMonitorAudio;
  final bool autoFullscreenOnConnect;
  final ViewerPriorityMode viewerPriority;
  final VideoDisplayMode? videoDisplayMode;
  final VideoQualityPreset videoQualityPreset;
  final RecordingDirectoryMode recordingDirectoryMode;
  final String? customRecordingDirectoryPath;
  final String? customRecordingDirectoryUri;
  final VideoProfile videoProfile;

  static const cameraDefaults = StreamSettings();
  static const monitorDefaults = StreamSettings(
    lowLightBoost: false,
    videoProfile: VideoProfile(
      width: 0,
      height: 0,
      frameRate: 0,
      previewAspectRatio: 16 / 10,
      label: 'Tablet monitor',
    ),
  );

  StreamSettings copyWith({
    bool? preferDirectP2P,
    bool? enableTurnFallback,
    bool? useMultipleStunServers,
    bool? powerSaveMode,
    bool? automaticPowerSavingMode,
    bool? enableMicrophone,
    int? maxVideoBitrateKbps,
    bool? lowLightBoost,
    bool? showConnectionReport,
    ExposureMode? exposureMode,
    CameraLightMode? cameraLightMode,
    CameraViewMode? cameraViewMode,
    bool? activityDetectionEnabled,
    bool? enableMonitorAudio,
    bool? autoFullscreenOnConnect,
    ViewerPriorityMode? viewerPriority,
    VideoDisplayMode? videoDisplayMode,
    VideoQualityPreset? videoQualityPreset,
    RecordingDirectoryMode? recordingDirectoryMode,
    Object? customRecordingDirectoryPath = _recordingDirectorySentinel,
    Object? customRecordingDirectoryUri = _recordingDirectorySentinel,
    VideoProfile? videoProfile,
  }) {
    return StreamSettings(
      preferDirectP2P: preferDirectP2P ?? this.preferDirectP2P,
      enableTurnFallback: enableTurnFallback ?? this.enableTurnFallback,
      useMultipleStunServers:
          useMultipleStunServers ?? this.useMultipleStunServers,
      powerSaveMode: powerSaveMode ?? this.powerSaveMode,
      automaticPowerSavingMode:
          automaticPowerSavingMode ?? this.automaticPowerSavingMode,
      enableMicrophone: enableMicrophone ?? this.enableMicrophone,
      maxVideoBitrateKbps: maxVideoBitrateKbps ?? this.maxVideoBitrateKbps,
      lowLightBoost: lowLightBoost ?? this.lowLightBoost,
      showConnectionReport: showConnectionReport ?? this.showConnectionReport,
      exposureMode: exposureMode ?? this.exposureMode,
      cameraLightMode: cameraLightMode ?? this.cameraLightMode,
      cameraViewMode: cameraViewMode ?? this.cameraViewMode,
      activityDetectionEnabled:
          activityDetectionEnabled ?? this.activityDetectionEnabled,
      enableMonitorAudio: enableMonitorAudio ?? this.enableMonitorAudio,
      autoFullscreenOnConnect:
          autoFullscreenOnConnect ?? this.autoFullscreenOnConnect,
      viewerPriority: viewerPriority ?? this.viewerPriority,
      videoDisplayMode: videoDisplayMode ?? this.videoDisplayMode,
      videoQualityPreset: videoQualityPreset ?? this.videoQualityPreset,
      recordingDirectoryMode:
          recordingDirectoryMode ?? this.recordingDirectoryMode,
      customRecordingDirectoryPath: identical(
        customRecordingDirectoryPath,
        _recordingDirectorySentinel,
      )
          ? this.customRecordingDirectoryPath
          : customRecordingDirectoryPath as String?,
      customRecordingDirectoryUri: identical(
        customRecordingDirectoryUri,
        _recordingDirectorySentinel,
      )
          ? this.customRecordingDirectoryUri
          : customRecordingDirectoryUri as String?,
      videoProfile: videoProfile ?? this.videoProfile,
    );
  }

  RTCVideoViewObjectFit get rtcVideoFit =>
      RTCVideoViewObjectFit.RTCVideoViewObjectFitContain;

  StreamSettings resolvedForViewport({
    required double screenWidth,
    required double screenHeight,
    required StreamViewportRole role,
  }) {
    final deviceClass = DeviceViewportClassResolver.fromViewport(
      screenWidth: screenWidth,
      screenHeight: screenHeight,
    );
    final resolvedDisplayMode = role == StreamViewportRole.camera
        ? (deviceClass == DeviceViewportClass.phone
            ? VideoDisplayMode.portrait
            : VideoDisplayMode.landscape)
        : (videoDisplayMode ??
            (deviceClass == DeviceViewportClass.phone
                ? VideoDisplayMode.portrait
                : VideoDisplayMode.landscape));
    final resolvedAspectRatio = _cameraPreviewAspectRatio(
      displayMode: resolvedDisplayMode,
      cameraViewMode: cameraViewMode,
    );

    final baseProfile = role == StreamViewportRole.camera && powerSaveMode
        ? VideoProfile.powerSaveFor(deviceClass)
        : VideoProfile.adaptive(
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            role: role,
            preset: videoQualityPreset,
          );
    final resolvedProfile = role == StreamViewportRole.camera
        ? baseProfile.adjustedForCameraView(
            displayMode: resolvedDisplayMode,
            cameraViewMode: cameraViewMode,
          )
        : baseProfile.copyWith(
            previewAspectRatio: resolvedAspectRatio,
          );

    return copyWith(
      enableMicrophone: role == StreamViewportRole.camera && powerSaveMode
          ? false
          : enableMicrophone,
      maxVideoBitrateKbps: role == StreamViewportRole.camera && powerSaveMode
          ? math.min(maxVideoBitrateKbps, 450)
          : maxVideoBitrateKbps,
      lowLightBoost: role == StreamViewportRole.camera && powerSaveMode
          ? false
          : lowLightBoost,
      viewerPriority: role == StreamViewportRole.camera && powerSaveMode
          ? ViewerPriorityMode.balanced
          : viewerPriority,
      cameraViewMode: cameraViewMode,
      videoDisplayMode: resolvedDisplayMode,
      videoQualityPreset: role == StreamViewportRole.camera && powerSaveMode
          ? VideoQualityPreset.dataSaver
          : videoQualityPreset,
      videoProfile: resolvedProfile,
    );
  }

  String get bitrateLabel => '$maxVideoBitrateKbps kbps';
  String get videoProfileLabel => videoProfile.label;
  String get videoDisplayLabel {
    switch (videoDisplayMode) {
      case VideoDisplayMode.landscape:
        return 'Desktop View';
      case VideoDisplayMode.portrait:
        return 'Mobile View';
      case null:
        return 'Device default';
    }
  }

  String get cameraViewLabel {
    switch (cameraViewMode) {
      case CameraViewMode.standard:
        return 'Standard';
      case CameraViewMode.panorama:
        return 'Panorama';
    }
  }

  double get cameraViewScale =>
      cameraViewMode == CameraViewMode.panorama ? 1.08 : 1.0;

  String get qualityPresetLabel {
    switch (videoQualityPreset) {
      case VideoQualityPreset.auto:
        return 'Auto';
      case VideoQualityPreset.dataSaver:
        return 'Data saver';
      case VideoQualityPreset.balanced:
        return 'Balanced';
      case VideoQualityPreset.high:
        return 'High';
    }
  }

  bool get hasCustomRecordingDirectory =>
      customRecordingDirectoryPath?.trim().isNotEmpty ?? false;

  String get recordingLocationLabel {
    switch (recordingDirectoryMode) {
      case RecordingDirectoryMode.documents:
        return 'App storage';
      case RecordingDirectoryMode.appSupport:
        return 'App storage';
      case RecordingDirectoryMode.temporary:
        return 'Temporary';
      case RecordingDirectoryMode.custom:
        return 'Custom folder';
    }
  }

  String get recordingLocationDescription {
    switch (recordingDirectoryMode) {
      case RecordingDirectoryMode.documents:
        return 'Keep recordings inside the app support folder.';
      case RecordingDirectoryMode.appSupport:
        return 'Keep recordings inside the app support folder.';
      case RecordingDirectoryMode.temporary:
        return 'Use temporary storage that the device may clear later.';
      case RecordingDirectoryMode.custom:
        return hasCustomRecordingDirectory
            ? customRecordingDirectoryPath!
            : 'Choose a folder on this device.';
    }
  }

  Map<String, dynamic> toPersistenceMap({bool includeVideoProfile = false}) {
    return {
      'preferDirectP2P': preferDirectP2P,
      'enableTurnFallback': enableTurnFallback,
      'useMultipleStunServers': useMultipleStunServers,
      'powerSaveMode': powerSaveMode,
      'automaticPowerSavingMode': automaticPowerSavingMode,
      'enableMicrophone': enableMicrophone,
      'maxVideoBitrateKbps': maxVideoBitrateKbps,
      'lowLightBoost': lowLightBoost,
      'showConnectionReport': showConnectionReport,
      'exposureMode': exposureMode.name,
      'cameraLightMode': cameraLightMode.name,
      'cameraViewMode': cameraViewMode.name,
      'activityDetectionEnabled': activityDetectionEnabled,
      'enableMonitorAudio': enableMonitorAudio,
      'autoFullscreenOnConnect': autoFullscreenOnConnect,
      'viewerPriority': viewerPriority.name,
      'videoDisplayMode': videoDisplayMode?.name,
      'videoQualityPreset': videoQualityPreset.name,
      'recordingDirectoryMode': recordingDirectoryMode.name,
      'customRecordingDirectoryPath': customRecordingDirectoryPath,
      'customRecordingDirectoryUri': customRecordingDirectoryUri,
      if (includeVideoProfile) 'videoProfile': videoProfile.toMap(),
    };
  }

  Map<String, dynamic> toRemoteSyncMap() => toPersistenceMap(
        includeVideoProfile: true,
      )
        ..remove('customRecordingDirectoryPath')
        ..remove('customRecordingDirectoryUri')
        ..remove('recordingDirectoryMode');

  static StreamSettings fromPersistenceMap(
    Map<String, dynamic> map, {
    required StreamSettings fallback,
  }) {
    return fallback.copyWith(
      preferDirectP2P:
          map['preferDirectP2P'] as bool? ?? fallback.preferDirectP2P,
      enableTurnFallback:
          map['enableTurnFallback'] as bool? ?? fallback.enableTurnFallback,
      useMultipleStunServers: map['useMultipleStunServers'] as bool? ??
          fallback.useMultipleStunServers,
      powerSaveMode: map['powerSaveMode'] as bool? ?? fallback.powerSaveMode,
      automaticPowerSavingMode: map['automaticPowerSavingMode'] as bool? ??
          fallback.automaticPowerSavingMode,
      enableMicrophone:
          map['enableMicrophone'] as bool? ?? fallback.enableMicrophone,
      maxVideoBitrateKbps:
          map['maxVideoBitrateKbps'] as int? ?? fallback.maxVideoBitrateKbps,
      lowLightBoost: map['lowLightBoost'] as bool? ?? fallback.lowLightBoost,
      showConnectionReport:
          map['showConnectionReport'] as bool? ?? fallback.showConnectionReport,
      exposureMode: _parseEnum(
            ExposureMode.values,
            map['exposureMode'] as String?,
          ) ??
          fallback.exposureMode,
      cameraLightMode: _parseEnum(
            CameraLightMode.values,
            map['cameraLightMode'] as String?,
          ) ??
          fallback.cameraLightMode,
      cameraViewMode: _parseEnum(
            CameraViewMode.values,
            map['cameraViewMode'] as String?,
          ) ??
          fallback.cameraViewMode,
      activityDetectionEnabled: map['activityDetectionEnabled'] as bool? ??
          fallback.activityDetectionEnabled,
      enableMonitorAudio:
          map['enableMonitorAudio'] as bool? ?? fallback.enableMonitorAudio,
      autoFullscreenOnConnect: map['autoFullscreenOnConnect'] as bool? ??
          fallback.autoFullscreenOnConnect,
      viewerPriority: _parseEnum(
            ViewerPriorityMode.values,
            map['viewerPriority'] as String?,
          ) ??
          fallback.viewerPriority,
      videoDisplayMode: _parseEnum(
        VideoDisplayMode.values,
        map['videoDisplayMode'] as String?,
      ),
      videoQualityPreset: _parseEnum(
            VideoQualityPreset.values,
            map['videoQualityPreset'] as String?,
          ) ??
          fallback.videoQualityPreset,
      recordingDirectoryMode: () {
        final parsedMode = _parseEnum(
          RecordingDirectoryMode.values,
          map['recordingDirectoryMode'] as String?,
        );
        if (parsedMode == RecordingDirectoryMode.documents) {
          return RecordingDirectoryMode.appSupport;
        }
        return parsedMode ?? fallback.recordingDirectoryMode;
      }(),
      customRecordingDirectoryPath:
          map['customRecordingDirectoryPath'] as String?,
      customRecordingDirectoryUri:
          map['customRecordingDirectoryUri'] as String?,
      videoProfile: VideoProfile.fromMap(
              (map['videoProfile'] as Map?)?.cast<String, dynamic>()) ??
          fallback.videoProfile,
    );
  }

  static T? _parseEnum<T extends Enum>(List<T> values, String? name) {
    if (name == null || name.isEmpty) {
      return null;
    }

    for (final value in values) {
      if (value.name == name) {
        return value;
      }
    }
    return null;
  }
}

double _cameraPreviewAspectRatio({
  required VideoDisplayMode displayMode,
  required CameraViewMode cameraViewMode,
}) {
  switch ((displayMode, cameraViewMode)) {
    case (VideoDisplayMode.landscape, CameraViewMode.standard):
      return 16 / 9;
    case (VideoDisplayMode.portrait, CameraViewMode.standard):
      return 9 / 16;
    case (VideoDisplayMode.landscape, CameraViewMode.panorama):
      return 21 / 9;
    case (VideoDisplayMode.portrait, CameraViewMode.panorama):
      return 9 / 21;
  }
}
