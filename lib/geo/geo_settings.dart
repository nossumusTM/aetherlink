class GeoSettings {
  const GeoSettings({
    this.preferDirectP2P = true,
    this.enableTurnFallback = true,
    this.useMultipleStunServers = true,
    this.keepAwake = false,
    this.backgroundTracking = true,
    this.showConnectionReport = true,
    this.highAccuracy = false,
    this.distanceFilterMeters = 25,
    this.updateIntervalSeconds = 12,
    this.autoCenterOnUpdate = true,
    this.shareHeading = false,
    this.shareSpeed = false,
  });

  final bool preferDirectP2P;
  final bool enableTurnFallback;
  final bool useMultipleStunServers;
  final bool keepAwake;
  final bool backgroundTracking;
  final bool showConnectionReport;
  final bool highAccuracy;
  final int distanceFilterMeters;
  final int updateIntervalSeconds;
  final bool autoCenterOnUpdate;
  final bool shareHeading;
  final bool shareSpeed;

  static const positionDefaults = GeoSettings();
  static const monitorDefaults = GeoSettings(
    backgroundTracking: false,
    highAccuracy: false,
  );

  GeoSettings copyWith({
    bool? preferDirectP2P,
    bool? enableTurnFallback,
    bool? useMultipleStunServers,
    bool? keepAwake,
    bool? backgroundTracking,
    bool? showConnectionReport,
    bool? highAccuracy,
    int? distanceFilterMeters,
    int? updateIntervalSeconds,
    bool? autoCenterOnUpdate,
    bool? shareHeading,
    bool? shareSpeed,
  }) {
    return GeoSettings(
      preferDirectP2P: preferDirectP2P ?? this.preferDirectP2P,
      enableTurnFallback: enableTurnFallback ?? this.enableTurnFallback,
      useMultipleStunServers:
          useMultipleStunServers ?? this.useMultipleStunServers,
      keepAwake: keepAwake ?? this.keepAwake,
      backgroundTracking: backgroundTracking ?? this.backgroundTracking,
      showConnectionReport: showConnectionReport ?? this.showConnectionReport,
      highAccuracy: highAccuracy ?? this.highAccuracy,
      distanceFilterMeters: distanceFilterMeters ?? this.distanceFilterMeters,
      updateIntervalSeconds:
          updateIntervalSeconds ?? this.updateIntervalSeconds,
      autoCenterOnUpdate: autoCenterOnUpdate ?? this.autoCenterOnUpdate,
      shareHeading: shareHeading ?? this.shareHeading,
      shareSpeed: shareSpeed ?? this.shareSpeed,
    );
  }

  Map<String, dynamic> toMap() => {
        'preferDirectP2P': preferDirectP2P,
        'enableTurnFallback': enableTurnFallback,
        'useMultipleStunServers': useMultipleStunServers,
        'keepAwake': keepAwake,
        'backgroundTracking': backgroundTracking,
        'showConnectionReport': showConnectionReport,
        'highAccuracy': highAccuracy,
        'distanceFilterMeters': distanceFilterMeters,
        'updateIntervalSeconds': updateIntervalSeconds,
        'autoCenterOnUpdate': autoCenterOnUpdate,
        'shareHeading': shareHeading,
        'shareSpeed': shareSpeed,
      };

  static GeoSettings fromMap(
    Map<String, dynamic> map, {
    required GeoSettings fallback,
  }) {
    return fallback.copyWith(
      preferDirectP2P:
          map['preferDirectP2P'] as bool? ?? fallback.preferDirectP2P,
      enableTurnFallback:
          map['enableTurnFallback'] as bool? ?? fallback.enableTurnFallback,
      useMultipleStunServers: map['useMultipleStunServers'] as bool? ??
          fallback.useMultipleStunServers,
      keepAwake: map['keepAwake'] as bool? ?? fallback.keepAwake,
      backgroundTracking:
          map['backgroundTracking'] as bool? ?? fallback.backgroundTracking,
      showConnectionReport:
          map['showConnectionReport'] as bool? ?? fallback.showConnectionReport,
      highAccuracy: map['highAccuracy'] as bool? ?? fallback.highAccuracy,
      distanceFilterMeters:
          map['distanceFilterMeters'] as int? ?? fallback.distanceFilterMeters,
      updateIntervalSeconds:
          map['updateIntervalSeconds'] as int? ?? fallback.updateIntervalSeconds,
      autoCenterOnUpdate:
          map['autoCenterOnUpdate'] as bool? ?? fallback.autoCenterOnUpdate,
      shareHeading: map['shareHeading'] as bool? ?? fallback.shareHeading,
      shareSpeed: map['shareSpeed'] as bool? ?? fallback.shareSpeed,
    );
  }
}
