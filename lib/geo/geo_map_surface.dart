import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../geo/geo_models.dart';
import '../ui/azure_theme.dart';

class GeoMapSurface extends StatefulWidget {
  const GeoMapSurface({
    required this.primaryPoint,
    required this.history,
    this.secondaryPoint,
    this.secondaryHistory = const [],
    this.streetZoom = 17.2,
    this.primaryPointIsFresh = true,
    this.onClearPath,
    super.key,
  });

  final GeoPoint? primaryPoint;
  final List<GeoPoint> history;
  final GeoPoint? secondaryPoint;
  final List<GeoPoint> secondaryHistory;
  final double streetZoom;
  final bool primaryPointIsFresh;
  final VoidCallback? onClearPath;

  @override
  State<GeoMapSurface> createState() => _GeoMapSurfaceState();
}

class _GeoMapSurfaceState extends State<GeoMapSurface> {
  final MapController _mapController = MapController();
  Timer? _statusTimer;
  bool _isDragEnabled = false;
  String? _interactionMessage;

  GeoPoint? get _focusPoint => widget.primaryPoint ?? widget.secondaryPoint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _centerOnPoint());
  }

  @override
  void didUpdateWidget(covariant GeoMapSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPoint = oldWidget.primaryPoint ?? oldWidget.secondaryPoint;
    final newPoint = _focusPoint;
    final pointChanged = oldPoint?.latitude != newPoint?.latitude ||
        oldPoint?.longitude != newPoint?.longitude;
    if (pointChanged) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _centerOnPoint());
    }
  }

  void _centerOnPoint() {
    if (!mounted || _isDragEnabled) {
      return;
    }

    final point = _focusPoint;
    if (point == null) {
      return;
    }

    _mapController.move(
      LatLng(point.latitude, point.longitude),
      widget.streetZoom,
    );
  }

  void _showInteractionMessage(String message) {
    _statusTimer?.cancel();
    setState(() => _interactionMessage = message);
    _statusTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) {
        return;
      }
      setState(() => _interactionMessage = null);
    });
  }

  void _toggleDragMode() {
    setState(() => _isDragEnabled = !_isDragEnabled);
    if (_isDragEnabled) {
      _showInteractionMessage('Map drag activated');
      return;
    }

    _showInteractionMessage('Map drag deactivated');
    _centerOnPoint();
  }

  void _disableDragMode() {
    if (!_isDragEnabled) {
      return;
    }
    setState(() => _isDragEnabled = false);
    _showInteractionMessage('Map drag deactivated');
    _centerOnPoint();
  }

  void _recenter() {
    if (_isDragEnabled) {
      setState(() => _isDragEnabled = false);
      _showInteractionMessage('Following live location');
    }
    _centerOnPoint();
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final centerPoint = _focusPoint;
    final primaryPointColor = widget.primaryPointIsFresh
        ? AzureTheme.azureDark
        : const Color(0xFFD7263D);
    final center = centerPoint == null
        ? const LatLng(51.509364, -0.128928)
        : LatLng(centerPoint.latitude, centerPoint.longitude);
    final primaryLine = widget.history
        .map((point) => LatLng(point.latitude, point.longitude))
        .toList(growable: false);
    final secondaryLine = widget.secondaryHistory
        .map((point) => LatLng(point.latitude, point.longitude))
        .toList(growable: false);

    return TapRegion(
      onTapOutside: (_) => _disableDragMode(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: _toggleDragMode,
              child: FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: centerPoint == null ? 3.0 : widget.streetZoom,
                  interactionOptions: InteractionOptions(
                    flags: _isDragEnabled
                        ? InteractiveFlag.all &
                            ~InteractiveFlag.rotate &
                            ~InteractiveFlag.doubleTapZoom
                        : InteractiveFlag.none,
                    enableMultiFingerGestureRace: true,
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.example.sputni',
                  ),
                  if (primaryLine.length >= 2)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: primaryLine,
                          strokeWidth: 4,
                          color: AzureTheme.azureDark,
                        ),
                      ],
                    ),
                  if (secondaryLine.length >= 2)
                    PolylineLayer(
                      polylines: [
                        Polyline(
                          points: secondaryLine,
                          strokeWidth: 4,
                          color: AzureTheme.success,
                        ),
                      ],
                    ),
                  MarkerLayer(
                    markers: [
                      if (widget.primaryPoint != null)
                        Marker(
                          point: LatLng(
                            widget.primaryPoint!.latitude,
                            widget.primaryPoint!.longitude,
                          ),
                          width: 54,
                          height: 54,
                          child: _PulsingMapDot(
                            color: primaryPointColor,
                          ),
                        ),
                      if (widget.secondaryPoint != null)
                        Marker(
                          point: LatLng(
                            widget.secondaryPoint!.latitude,
                            widget.secondaryPoint!.longitude,
                          ),
                          width: 54,
                          height: 54,
                          child: const _PulsingMapDot(
                            color: AzureTheme.success,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: _MapActionButton(
                tooltip: 'Clear path',
                icon: Icons.delete_sweep_rounded,
                onPressed: widget.onClearPath,
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: _MapActionButton(
                tooltip: 'Back to location',
                icon: Icons.my_location_rounded,
                onPressed: _focusPoint == null ? null : _recenter,
              ),
            ),
            Positioned(
              right: 14,
              bottom: 14,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: (centerPoint == null
                            ? Colors.black
                            : widget.primaryPointIsFresh
                                ? AzureTheme.azureDark
                                : const Color(0xFFD7263D))
                        .withValues(alpha: 0.42),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    centerPoint == null
                        ? 'Waiting for location'
                        : widget.primaryPointIsFresh
                            ? 'Live map'
                            : 'Location stalled',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            if (_interactionMessage != null)
              Positioned(
                left: 14,
                right: 14,
                bottom: 14,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.58),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        _interactionMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MapActionButton extends StatelessWidget {
  const _MapActionButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton.filledTonal(
        onPressed: onPressed,
        icon: Icon(icon),
        style: IconButton.styleFrom(
          foregroundColor: AzureTheme.ink,
          backgroundColor: Colors.white.withValues(alpha: 0.76),
          disabledBackgroundColor: Colors.white.withValues(alpha: 0.4),
          disabledForegroundColor: AzureTheme.ink.withValues(alpha: 0.36),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AzureTheme.glassStroke),
          ),
        ),
      ),
    );
  }
}

class _PulsingMapDot extends StatefulWidget {
  const _PulsingMapDot({
    required this.color,
  });

  final Color color;

  @override
  State<_PulsingMapDot> createState() => _PulsingMapDotState();
}

class _PulsingMapDotState extends State<_PulsingMapDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final pulse = Curves.easeOut.transform(_controller.value);
        final ringScale = 0.6 + (pulse * 1.6);
        final ringOpacity = 0.34 * (1 - pulse);

        return Center(
          child: SizedBox(
            width: 54,
            height: 54,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Transform.scale(
                  scale: ringScale,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: widget.color.withValues(alpha: ringOpacity),
                    ),
                  ),
                ),
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color,
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.92),
                      width: 2.6,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: widget.color.withValues(alpha: 0.34),
                        blurRadius: 14,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
