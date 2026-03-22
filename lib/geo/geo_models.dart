import 'dart:convert';

class GeoPoint {
  const GeoPoint({
    required this.latitude,
    required this.longitude,
    required this.timestampMillis,
    this.accuracy,
    this.altitude,
    this.speed,
    this.heading,
  });

  final double latitude;
  final double longitude;
  final int timestampMillis;
  final double? accuracy;
  final double? altitude;
  final double? speed;
  final double? heading;

  DateTime get timestamp =>
      DateTime.fromMillisecondsSinceEpoch(timestampMillis);

  Map<String, dynamic> toMap() => {
        'latitude': latitude,
        'longitude': longitude,
        'timestampMillis': timestampMillis,
        'accuracy': accuracy,
        'altitude': altitude,
        'speed': speed,
        'heading': heading,
      };

  factory GeoPoint.fromMap(Map<String, dynamic> map) {
    return GeoPoint(
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      timestampMillis: (map['timestampMillis'] as num).toInt(),
      accuracy: (map['accuracy'] as num?)?.toDouble(),
      altitude: (map['altitude'] as num?)?.toDouble(),
      speed: (map['speed'] as num?)?.toDouble(),
      heading: (map['heading'] as num?)?.toDouble(),
    );
  }
}

class GeoEnvelope {
  const GeoEnvelope({
    required this.type,
    required this.payload,
  });

  final String type;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toMap() => {
        'type': type,
        'payload': payload,
      };

  String encode() => jsonEncode(toMap());

  factory GeoEnvelope.decode(String rawValue) {
    final decoded = jsonDecode(rawValue) as Map<String, dynamic>;
    return GeoEnvelope(
      type: decoded['type'] as String,
      payload: (decoded['payload'] as Map).cast<String, dynamic>(),
    );
  }
}
