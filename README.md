# Sputni

Sputni is a Flutter application for pairing two devices and running one of two real-time modes:

- `Sputni Live`: camera-to-monitor live video/audio streaming over WebRTC with WebSocket signaling.
- `Sputni Geo`: live location sharing over a WebRTC data channel with WebSocket relay fallback.

The app supports QR-based pairing, remembered paired devices, and reconnect flows where each side can reopen the same session from the home screen.

## Main Modes

- `Camera`: captures camera video and optional microphone audio, then streams to a paired monitor.
- `Monitor`: receives the live camera feed and can record or view fullscreen.
- `Position`: shares the device's location with a paired geo monitor.
- `Geo Monitor`: receives and renders the remote position on the map.

## Main Components

- `lib/main.dart`
  App shell, home screen, paired devices list, routing into each mode.
- `lib/camera_view/`
  Camera-side UI and live-stream orchestration.
- `lib/monitor_view/`
  Viewer-side UI and live-stream controls.
- `lib/geo/`
  Position sharing, geo monitor, location models, background relay hooks, and geo settings.
- `lib/webrtc/rtc_manager.dart`
  Peer connection lifecycle, offer/answer exchange, ICE, data channels, media binding, and codec preferences.
- `lib/signaling/`
  WebSocket signaling client, typed signaling messages, and control action constants.
- `lib/widgets/`
  Shared pairing UI, app shell widgets, QR helpers, and reusable panels.
- `lib/utils/`
  Pairing storage, device identity, permissions, logging, recording helpers, and alert helpers.
- `android/app/src/main/kotlin/...`
  Android-specific foreground services, notifications, and native platform bridges.

## Pairing Model

The app supports two ways to connect:

- `QR pairing`
  A device exposes its pairing payload as a QR code. The other device scans it and the pairing is saved on both sides.
- `Paired Devices`
  Once two devices have paired, each side can reopen the session with `Open camera`, `Open monitor`, `Open position`, or `Open monitor` from the saved devices list.

Pairings store:

- the canonical session payload used to reopen the same room
- the local launch role for the current device
- the peer payload used to render the correct remote device in the paired devices list

## Transport Model

### Camera / Monitor

- WebSocket is used for signaling.
- WebRTC carries the live media stream.
- TURN can be enabled for restrictive NAT environments.

### Position / Geo Monitor

- WebSocket is used for signaling and relay fallback.
- WebRTC data channel is the preferred path for live position updates.
- If the direct path is unavailable, the app can fall back to encrypted WebSocket relay.
- On Android, background location can be handed off to a native foreground relay service when enabled.

## Requirements

- Flutter 3.x
- Dart 3.x
- Android SDK for Android builds
- Xcode for iOS/macOS builds
- A reachable WebSocket signaling server
- Optional TURN server for harder network environments

## Setup

Install dependencies:

```bash
flutter pub get
```

Run the app with runtime config:

```bash
flutter run \
  --dart-define=SIGNALING_URL=wss://your-signal.example/ws \
  --dart-define=ENABLE_TURN=true \
  --dart-define=STUN_URL=stun:stun.l.google.com:19302 \
  --dart-define=TURN_URLS=turn:your-turn.example:3478?transport=udp,turn:your-turn.example:3478?transport=tcp \
  --dart-define=TURN_USERNAME=<turn-username> \
  --dart-define=TURN_CREDENTIAL=<turn-credential>
```

## Configuration Notes

The app reads most connection settings from `dart-define` values through `lib/config/app_config.dart`.

Important values:

- `SIGNALING_URL`
  WebSocket endpoint used by the app for session signaling.
- `ENABLE_TURN`
  Enables TURN candidates in the peer connection configuration.
- `STUN_URL`
  Primary STUN server.
- `TURN_URLS`
  Comma-separated TURN URLs.
- `TURN_USERNAME`
  TURN auth username.
- `TURN_CREDENTIAL`
  TURN auth credential.

## Platform Notes

### Android

Camera mode and geo mode need platform permissions such as:

- `INTERNET`
- `CAMERA`
- `RECORD_AUDIO`
- `ACCESS_FINE_LOCATION`
- `ACCESS_COARSE_LOCATION`
- `ACCESS_BACKGROUND_LOCATION` for background geo tracking
- notification permission on newer Android versions

Android also contains native components for:

- geo background relay service
- device notifications and alerts
- platform permission bridges

### iOS / macOS

You need the relevant privacy descriptions in `Info.plist`, especially for:

- camera
- microphone
- location

Use secure network endpoints where possible.

## How To Use

### Sputni Live

1. Open `Camera` on device A.
2. Open `Monitor` on device B.
3. Pair them with QR or use an existing paired device entry.
4. Start the camera session.
5. The monitor joins the same room and receives the video/audio stream.

### Sputni Geo

1. Open `Position` on device A.
2. Open `Geo Monitor` on device B.
3. Pair them with QR or use an existing paired device entry.
4. Start position sharing on the sender.
5. The geo monitor joins the same room and receives live location updates.

## Development Notes

- `server.js` is ignored in git and treated as a local signaling server entrypoint in this workspace.
- The app expects a signaling server that supports:
  - `join`
  - `offer`
  - `answer`
  - `ice-candidate`
  - `control`
  - `data`
  - `session-joined` control ack
- Camera/monitor and geo/monitor room usage is separated by pairing family and role.

## Useful Commands

Fetch packages:

```bash
flutter pub get
```

Analyze:

```bash
flutter analyze
```

Run tests:

```bash
flutter test
```

Compile Android Kotlin sources:

```bash
./gradlew :app:compileDebugKotlin
```

## Project Structure

```text
lib/
  camera_view/      camera sender flow
  monitor_view/     live monitor flow
  geo/              geo sender and monitor flow
  signaling/        WebSocket protocol layer
  webrtc/           peer connection manager
  widgets/          shared UI and pairing widgets
  utils/            storage, permissions, alerts, helpers
  config/           runtime app configuration
android/
  app/src/main/kotlin/...   Android-native services and bridges
assets/
  media/            bundled artwork and backgrounds
```

## Current Scope

This repository currently focuses on:

- device-to-device live streaming
- device-to-device live location sharing
- QR pairing and paired-device reconnect
- Android background geo relay support
- local device notifications around session interruption

It does not yet include a full production backend for remote push notification delivery.
