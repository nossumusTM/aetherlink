import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:mobile_scanner/mobile_scanner.dart' as ms;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zxing2/qrcode.dart';
import 'package:zxing2/zxing2.dart' as zxing;

import '../ui/azure_theme.dart';

const _pairingScheme = 'sputni';
const _legacyPairingScheme = 'teleck';

enum PairingMethod { roomId, qrCode }

enum PairingFeatureFamily { liveCamera, geo }

class PairingPayloadData {
  const PairingPayloadData({
    required this.roomId,
    this.signalingUrl,
    this.role,
    this.deviceId,
    this.secret,
  });

  final String roomId;
  final String? signalingUrl;
  final String? role;
  final String? deviceId;
  final String? secret;
}

PairingFeatureFamily? pairingFeatureFamilyForRole(String? role) {
  switch (role?.trim().toLowerCase()) {
    case 'camera':
    case 'monitor':
      return PairingFeatureFamily.liveCamera;
    case 'geo-position':
    case 'geo-monitor':
      return PairingFeatureFamily.geo;
    default:
      return null;
  }
}

String? pairingPayloadCompatibilityError({
  required PairingPayloadData? payloadData,
  required PairingFeatureFamily expectedFamily,
}) {
  final role = payloadData?.role?.trim().toLowerCase();
  if (role == null || role.isEmpty) {
    return null;
  }

  final actualFamily = pairingFeatureFamilyForRole(role);
  if (actualFamily == null) {
    return 'This pairing link uses an unsupported role.';
  }
  if (actualFamily == expectedFamily) {
    return null;
  }

  return switch (expectedFamily) {
    PairingFeatureFamily.liveCamera =>
      'This QR code is for Geo pairing. Use Position or Geo Monitor.',
    PairingFeatureFamily.geo =>
      'This QR code is for Camera/Monitor pairing. Use Camera or Monitor.',
  };
}

String buildPairingPayload({
  required String roomId,
  required String signalingUrl,
  required String role,
  String? deviceId,
  String? secret,
}) {
  return Uri(
    scheme: _pairingScheme,
    host: 'pair',
    queryParameters: {
      'room': roomId,
      'signal': signalingUrl,
      'role': role,
      if (deviceId != null && deviceId.trim().isNotEmpty) 'device': deviceId,
      if (secret != null && secret.trim().isNotEmpty) 'secret': secret,
    },
  ).toString();
}

PairingPayloadData? parsePairingPayload(String rawValue) {
  final uri = Uri.tryParse(rawValue);
  if (uri == null) return null;
  final scheme = uri.scheme.toLowerCase();
  if ((scheme != _pairingScheme && scheme != _legacyPairingScheme) ||
      uri.host != 'pair') {
    return null;
  }

  final roomId = uri.queryParameters['room'];
  if (roomId == null || roomId.trim().isEmpty) return null;
  final signalingUrl = uri.queryParameters['signal']?.trim();
  final role = uri.queryParameters['role']?.trim();
  final deviceId = uri.queryParameters['device']?.trim();
  final secret = uri.queryParameters['secret']?.trim();

  return PairingPayloadData(
    roomId: roomId.trim(),
    signalingUrl:
        signalingUrl == null || signalingUrl.isEmpty ? null : signalingUrl,
    role: role == null || role.isEmpty ? null : role,
    deviceId: deviceId == null || deviceId.isEmpty ? null : deviceId,
    secret: secret == null || secret.isEmpty ? null : secret,
  );
}

String? parseRoomIdFromPairingPayload(String rawValue) {
  return parsePairingPayload(rawValue)?.roomId;
}

Future<String?> scanPairingPayloadValue(BuildContext context) async {
  if (_supportsLiveCameraQrScanning) {
    return Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const _PairingQrScannerScreen(),
      ),
    );
  }

  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(
    const SnackBar(
      content: Text(
        'Live QR scanning is unavailable on this platform. Choose an image containing the QR code instead.',
      ),
    ),
  );

  return _scanQrCodeFromImage(context);
}

bool get _supportsLiveCameraQrScanning {
  if (kIsWeb) return false;

  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return true;
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return false;
  }
}

Future<String?> _scanQrCodeFromImage(BuildContext context) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    withData: true,
    allowedExtensions: const ['png', 'jpg', 'jpeg', 'bmp', 'gif', 'webp'],
  );

  final file =
      result != null && result.files.isNotEmpty ? result.files.first : null;
  final bytes = file?.bytes;
  if (bytes == null) return null;

  try {
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw const FormatException('Unsupported image format.');
    }

    final rgbaImage = image.convert(numChannels: 4);
    final rgbaBytes = rgbaImage.getBytes(order: img.ChannelOrder.rgba);
    final pixels = Int32List(rgbaImage.width * rgbaImage.height);

    for (var index = 0; index < pixels.length; index++) {
      final offset = index * 4;
      final r = rgbaBytes[offset];
      final g = rgbaBytes[offset + 1];
      final b = rgbaBytes[offset + 2];
      final a = rgbaBytes[offset + 3];
      pixels[index] = (a << 24) | (r << 16) | (g << 8) | b;
    }

    final source =
        zxing.RGBLuminanceSource(rgbaImage.width, rgbaImage.height, pixels);
    final bitmap = zxing.BinaryBitmap(zxing.HybridBinarizer(source));
    final decoded = QRCodeReader().decode(bitmap);
    return decoded.text;
  } catch (_) {
    messenger?.showSnackBar(
      const SnackBar(
        content: Text(
          'No readable QR code was found in the selected image.',
        ),
      ),
    );
    return null;
  }
}

class _PairingQrScannerScreen extends StatefulWidget {
  const _PairingQrScannerScreen();

  @override
  State<_PairingQrScannerScreen> createState() =>
      _PairingQrScannerScreenState();
}

class _PairingQrScannerScreenState extends State<_PairingQrScannerScreen> {
  final ms.MobileScannerController _controller = ms.MobileScannerController(
    detectionSpeed: ms.DetectionSpeed.noDuplicates,
    formats: const [ms.BarcodeFormat.qrCode],
  );
  bool _hasDetectedValue = false;

  void _handleDetection(ms.BarcodeCapture capture) {
    if (_hasDetectedValue) return;

    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue?.trim();
      if (rawValue == null || rawValue.isEmpty) {
        continue;
      }

      _hasDetectedValue = true;
      Navigator.of(context).pop(rawValue);
      return;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          ms.MobileScanner(
            controller: _controller,
            fit: BoxFit.cover,
            onDetect: _handleDetection,
            errorBuilder: (context, error, child) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Text(
                    'Unable to open the camera scanner. Check camera permission and try again.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Colors.white70,
                        ),
                  ),
                ),
              );
            },
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.56),
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.72),
                ],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton.filledTonal(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Scan QR-Code Link',
                          style:
                              Theme.of(context).textTheme.titleLarge?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Container(
                    width: 260,
                    height: 260,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.92),
                        width: 3,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.3),
                          blurRadius: 28,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Point your camera at the pairing QR code on the other device.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Colors.white70,
                          height: 1.4,
                        ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PairingMethodTabs extends StatelessWidget {
  const PairingMethodTabs({
    required this.activeMethod,
    required this.onChanged,
    super.key,
  });

  final PairingMethod activeMethod;
  final ValueChanged<PairingMethod> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AzureTheme.glassStroke),
      ),
      child: Row(
        children: PairingMethod.values.map((method) {
          final isSelected = activeMethod == method;
          final label = method == PairingMethod.roomId ? 'Room ID' : 'QR-Code';
          return Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: isSelected
                    ? Colors.white.withValues(alpha: 0.5)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: TextButton(
                onPressed: () => onChanged(method),
                style: TextButton.styleFrom(
                  foregroundColor: AzureTheme.ink,
                ),
                child: Text(label),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class PairingQrCodeCard extends StatefulWidget {
  const PairingQrCodeCard({
    required this.payload,
    required this.title,
    required this.subtitle,
    this.showHeader = true,
    super.key,
  });

  final String payload;
  final String title;
  final String subtitle;
  final bool showHeader;

  @override
  State<PairingQrCodeCard> createState() => _PairingQrCodeCardState();
}

class _PairingQrCodeCardState extends State<PairingQrCodeCard> {
  Timer? _copyResetTimer;
  bool _copied = false;

  Future<void> _copyPayload() async {
    await Clipboard.setData(ClipboardData(text: widget.payload));
    _copyResetTimer?.cancel();
    if (!mounted) return;
    setState(() => _copied = true);
    _copyResetTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _copyResetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMobilePlatform = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android);
    final qrSize = isMobilePlatform ? 180.0 : 220.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.showHeader) ...[
          Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            widget.subtitle,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(
                  color: AzureTheme.ink.withValues(alpha: 0.65),
                ),
          ),
          const SizedBox(height: 16),
        ],
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: isMobilePlatform ? 288 : 320),
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.all(isMobilePlatform ? 16 : 20),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.56),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: AzureTheme.glassStroke),
              ),
              child: Column(
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: Center(
                      child: Semantics(
                        label: 'Pairing QR code',
                        image: true,
                        child: ExcludeSemantics(
                          child: QrImageView(
                            data: widget.payload,
                            version: QrVersions.auto,
                            backgroundColor: Colors.white,
                            size: qrSize,
                            eyeStyle: const QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color: AzureTheme.ink,
                            ),
                            dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square,
                              color: AzureTheme.ink,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: animation, child: child),
                    ),
                    child: OutlinedButton.icon(
                      key: ValueKey(_copied),
                      onPressed: _copyPayload,
                      style: OutlinedButton.styleFrom(
                        textStyle:
                            Theme.of(context).textTheme.bodySmall?.copyWith(
                                  fontSize: isMobilePlatform ? 12 : 13,
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                      icon: Icon(
                        _copied ? Icons.check_rounded : Icons.link_rounded,
                      ),
                      label: Text(
                        _copied
                            ? 'Pairing link copied'
                            : 'Copy the pairing link',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

Future<void> showPairingQrCodeModal({
  required BuildContext context,
  required String payload,
  required String title,
  required String subtitle,
  ValueChanged<BuildContext>? onDialogReady,
}) {
  final screenSize = MediaQuery.of(context).size;
  final isMobilePlatform = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);
  final horizontalMargin =
      screenSize.width >= 1024 ? 48.0 : (isMobilePlatform ? 32.0 : 20.0);
  final verticalMargin =
      screenSize.width >= 1024 ? 48.0 : (isMobilePlatform ? 18.0 : 20.0);

  Widget buildModalContent(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AzureTheme.ink,
                    ),
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AzureTheme.ink.withValues(alpha: 0.65),
              ),
        ),
        const SizedBox(height: 16),
        PairingQrCodeCard(
          payload: payload,
          title: title,
          subtitle: subtitle,
          showHeader: false,
        ),
      ],
    );
  }

  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.36),
    builder: (context) {
      onDialogReady?.call(context);
      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.symmetric(
          horizontal: horizontalMargin,
          vertical: verticalMargin,
        ),
        child: Container(
          width: double.infinity,
          padding: EdgeInsets.all(isMobilePlatform ? 18 : 20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: AzureTheme.glassStroke),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14081A33),
                blurRadius: 28,
                offset: Offset(0, 18),
              ),
            ],
          ),
          child: isMobilePlatform
              ? buildModalContent(context)
              : SingleChildScrollView(
                  child: buildModalContent(context),
                ),
        ),
      );
    },
  );
}
