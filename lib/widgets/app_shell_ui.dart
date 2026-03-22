import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../config/stream_settings.dart';
import '../ui/azure_theme.dart';

const MethodChannel _storageChannel = MethodChannel('sputni/storage');

class AppShell extends StatelessWidget {
  const AppShell({
    required this.title,
    required this.subtitle,
    required this.hero,
    required this.panels,
    required this.actions,
    this.onBack,
    this.bottomNavigationBar,
    super.key,
  });

  final String title;
  final String subtitle;
  final Widget hero;
  final List<Widget> panels;
  final List<Widget> actions;
  final VoidCallback? onBack;
  final Widget? bottomNavigationBar;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final deviceClass = DeviceViewportClassResolver.fromViewport(
      screenWidth: mediaQuery.size.width,
      screenHeight: mediaQuery.size.height,
    );
    final usePlainHeader = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        deviceClass == DeviceViewportClass.phone;

    final headerContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: onBack ??
                  () {
                    if (Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    }
                  },
              icon: const Icon(Icons.arrow_back_rounded),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: AzureTheme.ink,
                    ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: AzureTheme.ink.withValues(alpha: 0.72),
                height: 1.35,
              ),
        ),
      ],
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AzureTheme.systemUiOverlayStyle,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        bottomNavigationBar: bottomNavigationBar,
        body: EdgeSwipeBack(
          enabled: Navigator.of(context).canPop(),
          onBack: onBack,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AzureTheme.backgroundTop,
                  AzureTheme.backgroundMiddle,
                  AzureTheme.backgroundBottom,
                ],
              ),
            ),
            child: Stack(
              children: [
                const Positioned(
                  top: -80,
                  left: -30,
                  child: _GlowOrb(
                    size: 220,
                    color: Color(0x701279FF),
                  ),
                ),
                const Positioned(
                  top: 180,
                  right: -40,
                  child: _GlowOrb(
                    size: 180,
                    color: Color(0x556BD7FF),
                  ),
                ),
                const Positioned(
                  bottom: -70,
                  left: 60,
                  child: _GlowOrb(
                    size: 240,
                    color: Color(0x40A6D4FF),
                  ),
                ),
                ListView(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    mediaQuery.padding.top + 18,
                    20,
                    mediaQuery.padding.bottom + 28,
                  ),
                  children: [
                    if (usePlainHeader)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(2, 6, 2, 6),
                        child: headerContent,
                      )
                    else
                      GlassPanel(
                        borderRadius: 30,
                        padding: const EdgeInsets.fromLTRB(14, 14, 18, 18),
                        child: headerContent,
                      ),
                    const SizedBox(height: 18),
                    hero,
                    const SizedBox(height: 18),
                    ...panels.expand(
                      (panel) => [panel, const SizedBox(height: 14)],
                    ),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        if (constraints.maxWidth < 640) {
                          return Column(
                            children: actions
                                .map(
                                  (action) => Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: action,
                                  ),
                                )
                                .toList(),
                          );
                        }

                        return Row(
                          children: actions
                              .map((action) => Expanded(child: action))
                              .expand(
                                (widget) => [widget, const SizedBox(width: 12)],
                              )
                              .toList()
                            ..removeLast(),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EdgeSwipeBack extends StatefulWidget {
  const EdgeSwipeBack({
    required this.child,
    required this.enabled,
    this.onBack,
    super.key,
  });

  final Widget child;
  final bool enabled;
  final VoidCallback? onBack;

  @override
  State<EdgeSwipeBack> createState() => _EdgeSwipeBackState();
}

class _EdgeSwipeBackState extends State<EdgeSwipeBack> {
  double _dragDistance = 0;

  void _handleBack() {
    if (!widget.enabled) return;
    if (widget.onBack != null) {
      widget.onBack!.call();
      return;
    }
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (widget.enabled)
          Positioned(
            top: 0,
            bottom: 0,
            left: 0,
            width: 28,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: (_) => _dragDistance = 0,
              onHorizontalDragUpdate: (details) {
                if (details.delta.dx > 0) {
                  _dragDistance += details.delta.dx;
                }
              },
              onHorizontalDragEnd: (details) {
                final swipeVelocity = details.primaryVelocity ?? 0;
                final shouldPop = _dragDistance > 72 || swipeVelocity > 700;
                _dragDistance = 0;
                if (shouldPop) {
                  _handleBack();
                }
              },
              onHorizontalDragCancel: () => _dragDistance = 0,
              child: const SizedBox.expand(),
            ),
          ),
      ],
    );
  }
}

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    required this.child,
    this.padding,
    this.borderRadius = 28,
    this.opacity = 0.68,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double borderRadius;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(borderRadius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withValues(alpha: opacity),
                Colors.white.withValues(alpha: opacity - 0.14),
              ],
            ),
            border: Border.all(color: AzureTheme.glassStroke),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14081A33),
                blurRadius: 28,
                offset: Offset(0, 18),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({
    required this.size,
    required this.color,
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color,
              color.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

class SurfacePanel extends StatelessWidget {
  const SurfacePanel({
    required this.child,
    this.padding = const EdgeInsets.all(18),
    super.key,
  });

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: GlassPanel(
        padding: padding,
        child: child,
      ),
    );
  }
}

enum SputniBottomNavDestination { live, paired, tracker }

class SputniBottomNavigationBar extends StatelessWidget {
  const SputniBottomNavigationBar({
    required this.selectedDestination,
    required this.onSelected,
    super.key,
  });

  final SputniBottomNavDestination selectedDestination;
  final ValueChanged<SputniBottomNavDestination> onSelected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AzureTheme.backgroundTop,
                  AzureTheme.backgroundMiddle,
                  AzureTheme.backgroundBottom,
                ],
              ),
            ),
            child: GlassPanel(
              borderRadius: 20,
              opacity: 0.66,
              child: NavigationBarTheme(
                data: NavigationBarThemeData(
                  backgroundColor: Colors.transparent,
                  indicatorColor: Colors.white.withValues(alpha: 0.44),
                  labelTextStyle: WidgetStateProperty.resolveWith(
                    (states) {
                      final color = states.contains(WidgetState.selected)
                          ? AzureTheme.azureDark
                          : AzureTheme.ink.withValues(alpha: 0.72);
                      return Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: color,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                          );
                    },
                  ),
                  iconTheme: WidgetStateProperty.resolveWith((states) {
                    final color = states.contains(WidgetState.selected)
                        ? AzureTheme.azureDark
                        : AzureTheme.ink.withValues(alpha: 0.72);
                    return IconThemeData(color: color, size: 24);
                  }),
                ),
                child: NavigationBar(
                  selectedIndex: selectedDestination.index,
                  height: 62,
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  backgroundColor: Colors.transparent,
                  labelBehavior:
                      NavigationDestinationLabelBehavior.onlyShowSelected,
                  onDestinationSelected: (index) {
                    onSelected(SputniBottomNavDestination.values[index]);
                  },
                  destinations: const [
                    NavigationDestination(
                      icon: _SquareNavIcon(icon: Icons.videocam_outlined),
                      selectedIcon: _SquareNavIcon(
                        icon: Icons.videocam_rounded,
                      ),
                      label: 'Live',
                    ),
                    NavigationDestination(
                      icon: _SquareNavIcon(icon: Icons.qr_code_2_outlined),
                      selectedIcon: _SquareNavIcon(
                        icon: Icons.qr_code_2_rounded,
                      ),
                      label: 'Paired',
                    ),
                    NavigationDestination(
                      icon: _SquareNavIcon(icon: Icons.location_on_outlined),
                      selectedIcon: _SquareNavIcon(
                        icon: Icons.location_on_rounded,
                      ),
                      label: 'Geo',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SquareNavIcon extends StatelessWidget {
  const _SquareNavIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 24,
      child: Center(
        child: Icon(icon, size: 24),
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.label,
    required this.color,
    super.key,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.6)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class PulseRecordingBadge extends StatefulWidget {
  const PulseRecordingBadge({
    this.label = 'REC',
    this.dotColor = const Color(0xFFD7263D),
    this.textColor = Colors.white,
    this.fontSize = 11,
    this.showPulse = true,
    this.backgroundColor,
    this.borderColor,
    this.onPressed,
    super.key,
  });

  final String label;
  final Color dotColor;
  final Color textColor;
  final double fontSize;
  final bool showPulse;
  final Color? backgroundColor;
  final Color? borderColor;
  final VoidCallback? onPressed;

  @override
  State<PulseRecordingBadge> createState() => _PulseRecordingBadgeState();
}

class _PulseRecordingBadgeState extends State<PulseRecordingBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.showPulse) {
      _controller.repeat(reverse: true);
    } else {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant PulseRecordingBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.showPulse == widget.showPulse) {
      return;
    }
    if (widget.showPulse) {
      _controller
        ..value = 0
        ..repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: widget.backgroundColor ?? Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: widget.borderColor ?? Colors.white.withValues(alpha: 0.14),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final pulseValue = widget.showPulse ? _controller.value : 1.0;
              final opacity = lerpDouble(0.45, 1.0, pulseValue) ?? 1.0;
              final scale = lerpDouble(0.88, 1.1, pulseValue) ?? 1.0;
              return Opacity(
                opacity: opacity,
                child: Transform.scale(scale: scale, child: child),
              );
            },
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: widget.dotColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            widget.label,
            style: TextStyle(
              color: widget.textColor,
              fontSize: widget.fontSize,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );

    if (widget.onPressed == null) {
      return badge;
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: widget.onPressed,
        child: badge,
      ),
    );
  }
}

class PreviewControlBar extends StatelessWidget {
  const PreviewControlBar({
    required this.children,
    super.key,
  });

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );
  }
}

ButtonStyle previewControlIconButtonStyle() {
  return IconButton.styleFrom(
    backgroundColor: Colors.white.withValues(alpha: 0.18),
    disabledBackgroundColor: Colors.white.withValues(alpha: 0.07),
    foregroundColor: Colors.white,
    disabledForegroundColor: Colors.white.withValues(alpha: 0.34),
  );
}

ButtonStyle fullscreenOverlayIconButtonStyle() {
  return IconButton.styleFrom(
    backgroundColor: Colors.black.withValues(alpha: 0.4),
    disabledBackgroundColor: Colors.black.withValues(alpha: 0.22),
    foregroundColor: Colors.white,
    disabledForegroundColor: Colors.white.withValues(alpha: 0.34),
    minimumSize: const Size(38, 38),
    padding: const EdgeInsets.all(8),
  );
}

class LiveDateTimeBadge extends StatefulWidget {
  const LiveDateTimeBadge({
    this.backgroundColor = Colors.transparent,
    this.borderColor = Colors.transparent,
    this.textColor = Colors.white,
    this.fontSize = 11.5,
    super.key,
  });

  final Color backgroundColor;
  final Color borderColor;
  final Color textColor;
  final double fontSize;

  @override
  State<LiveDateTimeBadge> createState() => _LiveDateTimeBadgeState();
}

class _LiveDateTimeBadgeState extends State<LiveDateTimeBadge> {
  late DateTime _now;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasDecoration =
        widget.backgroundColor.a > 0 || widget.borderColor.a > 0;

    final text = Text(
      _formatDateTime(_now),
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: widget.textColor,
            fontSize: widget.fontSize,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
    );

    if (!hasDecoration) {
      return text;
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: widget.borderColor),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: text,
      ),
    );
  }

  String _formatDateTime(DateTime value) {
    String twoDigits(int number) => number.toString().padLeft(2, '0');

    final year = value.year.toString().padLeft(4, '0');
    final month = twoDigits(value.month);
    final day = twoDigits(value.day);
    final hour = twoDigits(value.hour);
    final minute = twoDigits(value.minute);
    final second = twoDigits(value.second);
    return '$year-$month-$day  $hour:$minute:$second';
  }
}

enum MetricTone { neutral, good, warning, danger }

enum SettingsSheetMode { camera, monitor }

class MetricBadge extends StatefulWidget {
  const MetricBadge({
    required this.label,
    required this.icon,
    this.tone = MetricTone.neutral,
    this.monochrome = false,
    this.showLabelByDefault = false,
    this.onPressed,
    super.key,
  });

  final String label;
  final IconData icon;
  final MetricTone tone;
  final bool monochrome;
  final bool showLabelByDefault;
  final VoidCallback? onPressed;

  @override
  State<MetricBadge> createState() => _MetricBadgeState();
}

class _MetricBadgeState extends State<MetricBadge>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  bool _isTappedOpen = false;

  bool get _isExpanded =>
      widget.showLabelByDefault || (_usesHover ? _isHovered : _isTappedOpen);

  bool get _usesHover {
    switch (Theme.of(context).platform) {
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
      case TargetPlatform.linux:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = _metricColors(widget.tone);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: _usesHover ? (_) => setState(() => _isHovered = true) : null,
      onExit: _usesHover ? (_) => setState(() => _isHovered = false) : null,
      child: GestureDetector(
        onTap: widget.onPressed ??
            (_usesHover
                ? null
                : () => setState(() => _isTappedOpen = !_isTappedOpen)),
        child: AnimatedContainer(
          alignment: Alignment.center,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: colors.background,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: colors.border),
          ),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 16, color: colors.foreground),
                if (_isExpanded) ...[
                  const SizedBox(width: 8),
                  Text(
                    widget.label,
                    style: TextStyle(
                      color: colors.foreground,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  _MetricColors _metricColors(MetricTone tone) {
    if (widget.monochrome) {
      return const _MetricColors(
        background: Color(0xBFFFFFFF),
        border: Color(0x99FFFFFF),
        foreground: AzureTheme.azureDark,
      );
    }

    switch (tone) {
      case MetricTone.good:
        return const _MetricColors(
          background: Color(0xBFFFFFFF),
          border: Color(0x99FFFFFF),
          foreground: Color(0xFF157347),
        );
      case MetricTone.warning:
        return const _MetricColors(
          background: Color(0xBFFFFFFF),
          border: Color(0x99FFFFFF),
          foreground: Color(0xFFB56100),
        );
      case MetricTone.danger:
        return const _MetricColors(
          background: Color(0xBFFFFFFF),
          border: Color(0x99FFFFFF),
          foreground: Color(0xFFB42318),
        );
      case MetricTone.neutral:
        return const _MetricColors(
          background: Color(0xBFFFFFFF),
          border: Color(0x99FFFFFF),
          foreground: AzureTheme.azureDark,
        );
    }
  }
}

class ConnectionReportPanel extends StatelessWidget {
  const ConnectionReportPanel({
    required this.title,
    required this.summary,
    required this.highlights,
    required this.statusTone,
    super.key,
  });

  final String title;
  final String summary;
  final List<MetricBadge> highlights;
  final MetricTone statusTone;

  @override
  Widget build(BuildContext context) {
    return SurfacePanel(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.48),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AzureTheme.glassStroke),
                ),
                child: const Icon(
                  Icons.network_check_rounded,
                  color: AzureTheme.ink,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            summary,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AzureTheme.ink.withValues(alpha: 0.78),
                  height: 1.4,
                ),
          ),
          if (highlights.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 10,
              runSpacing: 10,
              children: highlights,
            ),
          ],
        ],
      ),
    );
  }
}

class SettingsShortcutPanel extends StatelessWidget {
  const SettingsShortcutPanel({
    required this.shortcuts,
    super.key,
  });

  final List<Widget> shortcuts;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final deviceClass = DeviceViewportClassResolver.fromViewport(
      screenWidth: size.width,
      screenHeight: size.height,
    );

    return SurfacePanel(
      padding: const EdgeInsets.all(14),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (deviceClass == DeviceViewportClass.phone) {
            return Column(
              children: shortcuts
                  .map(
                    (shortcut) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SizedBox(width: double.infinity, child: shortcut),
                    ),
                  )
                  .toList(),
            );
          }

          return Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: shortcuts,
          );
        },
      ),
    );
  }
}

class _MetricColors {
  const _MetricColors({
    required this.background,
    required this.border,
    required this.foreground,
  });

  final Color background;
  final Color border;
  final Color foreground;
}

Future<void> showFullscreenPreview({
  required BuildContext context,
  required RTCVideoRenderer renderer,
  required RTCVideoViewObjectFit objectFit,
  required String profileLabel,
  bool mirror = false,
  bool lowLightBoost = false,
  bool monochrome = false,
  bool preferPortrait = false,
  double contentScale = 1.0,
  Widget? topCenterOverlay,
}) {
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      pageBuilder: (context, animation, secondaryAnimation) {
        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              _FullscreenVideoSurface(
                renderer: renderer,
                objectFit: objectFit,
                mirror: mirror,
                monochrome: monochrome,
                preferPortrait: preferPortrait,
                contentScale: contentScale,
              ),
              if (monochrome)
                Container(
                  color: Colors.black.withValues(alpha: 0.16),
                ),
              if (lowLightBoost)
                Container(
                  color: Colors.lightBlueAccent.withValues(alpha: 0.08),
                ),
              SafeArea(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      top: 16,
                      right: 16,
                      child: IconButton.filledTonal(
                        onPressed: () => Navigator.of(context).pop(),
                        style: fullscreenOverlayIconButtonStyle(),
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                    ),
                    if (topCenterOverlay != null)
                      Positioned(
                        top: 16,
                        left: 0,
                        right: 0,
                        child: Center(child: topCenterOverlay),
                      ),
                    Positioned(
                      right: 16,
                      bottom: 16,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.14),
                          ),
                        ),
                        child: Text(
                          profileLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
      transitionsBuilder: (context, animation, secondaryAnimation, child) {
        return FadeTransition(opacity: animation, child: child);
      },
    ),
  );
}

class _FullscreenVideoSurface extends StatelessWidget {
  const _FullscreenVideoSurface({
    required this.renderer,
    required this.objectFit,
    required this.mirror,
    required this.monochrome,
    required this.preferPortrait,
    required this.contentScale,
  });

  final RTCVideoRenderer renderer;
  final RTCVideoViewObjectFit objectFit;
  final bool mirror;
  final bool monochrome;
  final bool preferPortrait;
  final double contentScale;

  @override
  Widget build(BuildContext context) {
    final isAndroid =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    final videoView = RTCVideoView(
      renderer,
      mirror: mirror,
      objectFit: objectFit,
    );
    final filteredVideo = monochrome && !isAndroid
        ? ColorFiltered(
            colorFilter: _nightModeColorFilter,
            child: videoView,
          )
        : videoView;
    final videoContent = contentScale == 1.0
        ? filteredVideo
        : Transform.scale(
            scale: contentScale,
            child: filteredVideo,
          );

    return ValueListenableBuilder<RTCVideoValue>(
      valueListenable: renderer,
      builder: (context, value, _) {
        final shouldRotateToPortrait = preferPortrait &&
            value.width > 0 &&
            value.height > 0 &&
            value.width >= value.height;

        if (!shouldRotateToPortrait) {
          return videoContent;
        }

        final size = MediaQuery.sizeOf(context);
        return ClipRect(
          child: Center(
            child: RotatedBox(
              quarterTurns: 1,
              child: SizedBox(
                width: size.height,
                height: size.width,
                child: videoContent,
              ),
            ),
          ),
        );
      },
    );
  }
}

Future<StreamSettings?> showSettingsSheet({
  required BuildContext context,
  required String title,
  required StreamSettings initialSettings,
  required bool turnAvailable,
  SettingsSheetMode mode = SettingsSheetMode.camera,
}) {
  return showModalBottomSheet<StreamSettings>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _SettingsSheet(
      title: title,
      initialSettings: initialSettings,
      turnAvailable: turnAvailable,
      mode: mode,
    ),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.title,
    required this.initialSettings,
    required this.turnAvailable,
    required this.mode,
  });

  final String title;
  final StreamSettings initialSettings;
  final bool turnAvailable;
  final SettingsSheetMode mode;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late StreamSettings _settings = widget.initialSettings;

  bool get _supportsDirectoryPicker => !kIsWeb;

  void _setPowerSaveMode(bool enabled) {
    setState(() {
      _settings = _settings.copyWith(
        powerSaveMode: enabled,
        enableMicrophone: enabled ? false : _settings.enableMicrophone,
        maxVideoBitrateKbps: enabled && _settings.maxVideoBitrateKbps > 450
            ? 450
            : _settings.maxVideoBitrateKbps,
        lowLightBoost: enabled ? false : _settings.lowLightBoost,
        viewerPriority:
            enabled ? ViewerPriorityMode.balanced : _settings.viewerPriority,
        videoQualityPreset: enabled
            ? VideoQualityPreset.dataSaver
            : _settings.videoQualityPreset,
        videoProfile:
            enabled ? VideoProfile.cameraPowerSave : _settings.videoProfile,
      );
    });
  }

  Future<void> _pickRecordingDirectory() async {
    try {
      final selection = await _resolveRecordingDirectorySelection();

      if (!mounted || selection == null || selection.path.trim().isEmpty) {
        return;
      }

      setState(() {
        _settings = _settings.copyWith(
          recordingDirectoryMode: RecordingDirectoryMode.custom,
          customRecordingDirectoryPath: selection.path.trim(),
          customRecordingDirectoryUri: selection.uri,
        );
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unable to open the folder picker on this device.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final isCameraMode = widget.mode == SettingsSheetMode.camera;
    final isMobilePlatform = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android);
    final deviceClass = DeviceViewportClassResolver.fromViewport(
      screenWidth: mediaQuery.size.width,
      screenHeight: mediaQuery.size.height,
    );
    final selectedDisplayMode = _settings.videoDisplayMode ??
        (deviceClass == DeviceViewportClass.phone
            ? VideoDisplayMode.portrait
            : VideoDisplayMode.landscape);
    const horizontalPadding = 20.0;
    const verticalPadding = 24.0;
    final bottomSafeInset = math.max(
      mediaQuery.viewPadding.bottom,
      mediaQuery.systemGestureInsets.bottom,
    );
    final outerPadding = EdgeInsets.fromLTRB(
      16,
      20,
      16,
      20 + bottomSafeInset + mediaQuery.viewInsets.bottom,
    );
    final maxSheetHeight =
        mediaQuery.size.height - mediaQuery.padding.top - bottomSafeInset - 44;
    final baseTheme = Theme.of(context);
    final baseTextTheme = baseTheme.textTheme;
    final settingsTextTheme = isMobilePlatform
        ? baseTextTheme.copyWith(
            headlineSmall: baseTextTheme.headlineSmall?.copyWith(fontSize: 25),
            titleLarge: baseTextTheme.titleLarge?.copyWith(fontSize: 18),
            titleMedium: baseTextTheme.titleMedium?.copyWith(fontSize: 15),
            titleSmall: baseTextTheme.titleSmall?.copyWith(fontSize: 13),
            bodyMedium: baseTextTheme.bodyMedium?.copyWith(fontSize: 13),
            bodySmall: baseTextTheme.bodySmall?.copyWith(fontSize: 11.5),
            labelLarge: baseTextTheme.labelLarge?.copyWith(fontSize: 12),
          )
        : baseTextTheme;
    final settingsButtonTextStyle = baseTheme.textTheme.bodyMedium?.copyWith(
      fontSize: isMobilePlatform ? 12 : 13,
      height: 1.15,
      fontWeight: FontWeight.w700,
      color: AzureTheme.ink,
    );
    final settingsChipLabelStyle = baseTheme.chipTheme.labelStyle?.copyWith(
      fontSize: isMobilePlatform ? 11.5 : 12.5,
      height: 1.1,
      fontWeight: FontWeight.w700,
      color: AzureTheme.ink,
    );
    final settingsTheme = baseTheme.copyWith(
      textTheme: settingsTextTheme,
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: baseTheme.elevatedButtonTheme.style?.copyWith(
          textStyle: WidgetStatePropertyAll(settingsButtonTextStyle),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: baseTheme.outlinedButtonTheme.style?.copyWith(
          textStyle: WidgetStatePropertyAll(settingsButtonTextStyle),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          ),
        ),
      ),
      chipTheme: baseTheme.chipTheme.copyWith(
        labelStyle: settingsChipLabelStyle,
      ),
    );

    return Padding(
      padding: outerPadding,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 760,
            maxHeight: maxSheetHeight.clamp(320.0, mediaQuery.size.height),
          ),
          child: Theme(
            data: settingsTheme,
            child: GlassPanel(
              borderRadius: 28,
              opacity: 0.78,
              child: Padding(
                padding: const EdgeInsets.only(
                  left: horizontalPadding,
                  right: horizontalPadding,
                  top: verticalPadding,
                ),
                child: Column(
                  children: [
                    Center(
                      child: Container(
                        width: 56,
                        height: 6,
                        decoration: BoxDecoration(
                          color: AzureTheme.azure.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(22),
                        child: ListTileTheme(
                          data: ListTileThemeData(
                            titleTextStyle: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  color: AzureTheme.ink,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.1,
                                ),
                            subtitleTextStyle: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: AzureTheme.ink.withValues(alpha: 0.68),
                                  height: 1.4,
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.title,
                                  style: Theme.of(context)
                                      .textTheme
                                      .headlineSmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w800,
                                        color: AzureTheme.ink,
                                      ),
                                ),
                                const SizedBox(height: 16),
                                SurfacePanel(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const _SectionTitle('Live Connection'),
                                      if (isCameraMode)
                                        SwitchListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title: const Text('Power save mode'),
                                          subtitle: const Text(
                                              'Lower capture load, cap bitrate, disable mic, and turn off low-light processing to reduce battery use.'),
                                          value: _settings.powerSaveMode,
                                          onChanged: _setPowerSaveMode,
                                        ),
                                      if (isCameraMode)
                                        SwitchListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title: const Text(
                                              'Automatic power saving mode'),
                                          subtitle: const Text(
                                              'Dim the camera screen after 3 minutes without interaction.'),
                                          value: _settings
                                              .automaticPowerSavingMode,
                                          onChanged: (value) => setState(
                                            () => _settings =
                                                _settings.copyWith(
                                                    automaticPowerSavingMode:
                                                        value),
                                          ),
                                        ),
                                      if (isCameraMode)
                                        SwitchListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title: const Text('Enable voice'),
                                          subtitle: Text(_settings.powerSaveMode
                                              ? 'Disabled while Power save mode is active.'
                                              : 'Capture microphone audio together with video.'),
                                          value: _settings.powerSaveMode
                                              ? false
                                              : _settings.enableMicrophone,
                                          onChanged: _settings.powerSaveMode
                                              ? null
                                              : (value) => setState(
                                                    () => _settings =
                                                        _settings.copyWith(
                                                            enableMicrophone:
                                                                value),
                                                  ),
                                        ),
                                      SwitchListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: const Text('Prefer direct P2P'),
                                        subtitle: const Text(
                                            'Use host and STUN candidates before relay.'),
                                        value: _settings.preferDirectP2P,
                                        onChanged: (value) => setState(
                                          () => _settings = _settings.copyWith(
                                              preferDirectP2P: value),
                                        ),
                                      ),
                                      SwitchListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: const Text('TURN fallback'),
                                        subtitle: Text(
                                          widget.turnAvailable
                                              ? 'Only arm relay after direct connection fails.'
                                              : 'TURN server not configured in environment.',
                                        ),
                                        value: _settings.enableTurnFallback &&
                                            widget.turnAvailable,
                                        onChanged: widget.turnAvailable
                                            ? (value) => setState(
                                                  () => _settings =
                                                      _settings.copyWith(
                                                          enableTurnFallback:
                                                              value),
                                                )
                                            : null,
                                      ),
                                      SwitchListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: const Text(
                                            'Use multiple STUN servers'),
                                        subtitle: const Text(
                                            'Cycle between the primary STUN route only or the full STUN server pool.'),
                                        value: _settings.useMultipleStunServers,
                                        onChanged: (value) => setState(
                                          () => _settings = _settings.copyWith(
                                              useMultipleStunServers: value),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),
                                SurfacePanel(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const _SectionTitle('Recording'),
                                      Text(
                                        'Save recordings to',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium,
                                      ),
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          ChoiceChip(
                                            label: const Text('App storage'),
                                            selected: _settings
                                                    .recordingDirectoryMode ==
                                                RecordingDirectoryMode
                                                    .appSupport,
                                            onSelected: (_) => setState(
                                              () => _settings =
                                                  _settings.copyWith(
                                                recordingDirectoryMode:
                                                    RecordingDirectoryMode
                                                        .appSupport,
                                              ),
                                            ),
                                          ),
                                          ChoiceChip(
                                            label: const Text('Temporary'),
                                            selected: _settings
                                                    .recordingDirectoryMode ==
                                                RecordingDirectoryMode
                                                    .temporary,
                                            onSelected: (_) => setState(
                                              () => _settings =
                                                  _settings.copyWith(
                                                recordingDirectoryMode:
                                                    RecordingDirectoryMode
                                                        .temporary,
                                              ),
                                            ),
                                          ),
                                          ChoiceChip(
                                            label: const Text('Choose folder'),
                                            selected: _settings
                                                    .recordingDirectoryMode ==
                                                RecordingDirectoryMode.custom,
                                            onSelected: (_) async {
                                              if (_settings
                                                  .hasCustomRecordingDirectory) {
                                                setState(
                                                  () => _settings =
                                                      _settings.copyWith(
                                                    recordingDirectoryMode:
                                                        RecordingDirectoryMode
                                                            .custom,
                                                  ),
                                                );
                                                return;
                                              }

                                              await _pickRecordingDirectory();
                                            },
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 16),
                                      if (_supportsDirectoryPicker)
                                        OutlinedButton.icon(
                                          onPressed: _pickRecordingDirectory,
                                          icon: const Icon(
                                            Icons.folder_open_rounded,
                                          ),
                                          label: Text(
                                            _settings
                                                    .hasCustomRecordingDirectory
                                                ? 'Change folder'
                                                : 'Choose folder',
                                          ),
                                        ),
                                      if (_supportsDirectoryPicker)
                                        const SizedBox(height: 12),
                                      Text(
                                        _settings.recordingLocationLabel,
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleSmall,
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        _settings.recordingLocationDescription,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: AzureTheme.ink
                                                  .withValues(alpha: 0.65),
                                              height: 1.4,
                                            ),
                                      ),
                                      if (_settings.recordingDirectoryMode ==
                                              RecordingDirectoryMode.custom &&
                                          !kIsWeb &&
                                          defaultTargetPlatform ==
                                              TargetPlatform.android &&
                                          (_settings.customRecordingDirectoryUri
                                                  ?.trim()
                                                  .isNotEmpty ??
                                              false)) ...[
                                        const SizedBox(height: 10),
                                        Text(
                                          'Android saves the recording locally first, then moves it into the selected folder when recording stops.',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: AzureTheme.ink
                                                    .withValues(alpha: 0.6),
                                                height: 1.35,
                                              ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                if (isCameraMode) ...[
                                  const SizedBox(height: 12),
                                  SurfacePanel(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const _SectionTitle('Video Quality'),
                                        Text('Lower video bitrate',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        Text(
                                          _settings.bitrateLabel,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: AzureTheme.ink
                                                    .withValues(alpha: 0.65),
                                              ),
                                        ),
                                        Slider(
                                          min: 450,
                                          max: 4000,
                                          divisions: 71,
                                          value: _settings.maxVideoBitrateKbps
                                              .toDouble(),
                                          label: _settings.bitrateLabel,
                                          onChanged: _settings.powerSaveMode
                                              ? null
                                              : (value) => setState(
                                                    () => _settings =
                                                        _settings.copyWith(
                                                      maxVideoBitrateKbps:
                                                          value.round(),
                                                    ),
                                                  ),
                                        ),
                                        const SizedBox(height: 16),
                                        Text('Capture quality',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        const SizedBox(height: 12),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children:
                                              VideoQualityPreset.values.map((
                                            preset,
                                          ) {
                                            return ChoiceChip(
                                              label: Text(
                                                  _qualityPresetLabel(preset)),
                                              selected: _settings
                                                      .videoQualityPreset ==
                                                  preset,
                                              onSelected: _settings
                                                      .powerSaveMode
                                                  ? null
                                                  : (_) => setState(
                                                        () => _settings =
                                                            _settings.copyWith(
                                                          videoQualityPreset:
                                                              preset,
                                                        ),
                                                      ),
                                            );
                                          }).toList(),
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          'Current profile: ${_settings.videoProfileLabel}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: AzureTheme.ink
                                                    .withValues(alpha: 0.65),
                                              ),
                                        ),
                                        const SizedBox(height: 16),
                                        Text('Low-Light Filter',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        const SizedBox(height: 12),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children:
                                              ExposureMode.values.map((mode) {
                                            return ChoiceChip(
                                              label: Text(
                                                  _exposureModeLabel(mode)),
                                              selected:
                                                  _settings.exposureMode ==
                                                      mode,
                                              onSelected: (_) => setState(
                                                () => _settings =
                                                    _settings.copyWith(
                                                  exposureMode: mode,
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                        const SizedBox(height: 16),
                                        Text('Camera mode',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        const SizedBox(height: 12),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: CameraLightMode.values
                                              .map((mode) {
                                            return ChoiceChip(
                                              label: Text(
                                                  _cameraLightModeLabel(mode)),
                                              selected:
                                                  _settings.cameraLightMode ==
                                                      mode,
                                              onSelected: (_) => setState(
                                                () => _settings =
                                                    _settings.copyWith(
                                                  cameraLightMode: mode,
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                        const SizedBox(height: 16),
                                        Text('Camera view',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        const SizedBox(height: 12),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children:
                                              CameraViewMode.values.map((mode) {
                                            return ChoiceChip(
                                              label: Text(
                                                  _cameraViewModeLabel(mode)),
                                              selected:
                                                  _settings.cameraViewMode ==
                                                      mode,
                                              onSelected: (_) => setState(
                                                () => _settings =
                                                    _settings.copyWith(
                                                  cameraViewMode: mode,
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                        SwitchListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title:
                                              const Text('Activity detection'),
                                          subtitle: const Text(
                                              'Detect scene/object movement using live camera motion heuristics.'),
                                          value: _settings
                                              .activityDetectionEnabled,
                                          onChanged: (value) => setState(
                                            () => _settings =
                                                _settings.copyWith(
                                                    activityDetectionEnabled:
                                                        value),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 12),
                                SurfacePanel(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const _SectionTitle('Viewer Experience'),
                                      Text('Viewer priority',
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium),
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: ViewerPriorityMode.values
                                            .map((mode) {
                                          return ChoiceChip(
                                            label: Text(
                                                _viewerPriorityLabel(mode)),
                                            selected:
                                                _settings.viewerPriority ==
                                                    mode,
                                            onSelected: (_) => setState(
                                              () => _settings =
                                                  _settings.copyWith(
                                                      viewerPriority: mode),
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                      const SizedBox(height: 16),
                                      if (!isCameraMode) ...[
                                        Text('Video display',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        const SizedBox(height: 12),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: VideoDisplayMode.values
                                              .map((mode) {
                                            return ChoiceChip(
                                              label: Text(
                                                mode ==
                                                        VideoDisplayMode
                                                            .landscape
                                                    ? 'Desktop View'
                                                    : 'Mobile View',
                                              ),
                                              selected:
                                                  selectedDisplayMode == mode,
                                              onSelected: (_) => setState(
                                                () => _settings =
                                                    _settings.copyWith(
                                                  videoDisplayMode: mode,
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                      ],
                                      SwitchListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: const Text('Connection report'),
                                        subtitle: const Text(
                                            'Show network status card on the dashboard.'),
                                        value: _settings.showConnectionReport,
                                        onChanged: (value) => setState(
                                          () => _settings = _settings.copyWith(
                                              showConnectionReport: value),
                                        ),
                                      ),
                                      if (!isCameraMode)
                                        SwitchListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title:
                                              const Text('Play camera audio'),
                                          subtitle: const Text(
                                              'Allow monitor mode to play incoming microphone audio from the camera stream.'),
                                          value: _settings.enableMonitorAudio,
                                          onChanged: (value) => setState(
                                            () => _settings =
                                                _settings.copyWith(
                                                    enableMonitorAudio: value),
                                          ),
                                        ),
                                      if (!isCameraMode)
                                        SwitchListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title: const Text(
                                              'Auto fullscreen on connect'),
                                          subtitle: const Text(
                                              'Open the live viewer in fullscreen automatically once the secure link becomes active.'),
                                          value:
                                              _settings.autoFullscreenOnConnect,
                                          onChanged: (value) => setState(
                                            () => _settings =
                                                _settings.copyWith(
                                                    autoFullscreenOnConnect:
                                                        value),
                                          ),
                                        ),
                                      if (!isCameraMode)
                                        SwitchListTile(
                                          contentPadding: EdgeInsets.zero,
                                          title: const Text('Low-light boost'),
                                          subtitle: const Text(
                                              'Apply extra brightness to the incoming monitor preview.'),
                                          value: _settings.lowLightBoost,
                                          onChanged: (value) => setState(
                                            () => _settings = _settings
                                                .copyWith(lowLightBoost: value),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(0, 14, 0, 12),
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: AzureTheme.glassStroke.withValues(
                              alpha: 0.7,
                            ),
                          ),
                        ),
                      ),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: () => Navigator.of(context).pop(_settings),
                          child: const Text('Apply settings'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _viewerPriorityLabel(ViewerPriorityMode mode) {
    switch (mode) {
      case ViewerPriorityMode.balanced:
        return 'Balanced';
      case ViewerPriorityMode.smooth:
        return 'Smooth';
      case ViewerPriorityMode.clarity:
        return 'Clarity';
    }
  }

  String _qualityPresetLabel(VideoQualityPreset preset) {
    switch (preset) {
      case VideoQualityPreset.auto:
        return 'Auto';
      case VideoQualityPreset.dataSaver:
        return 'Saver';
      case VideoQualityPreset.balanced:
        return 'Balanced';
      case VideoQualityPreset.high:
        return 'High';
    }
  }

  String _exposureModeLabel(ExposureMode mode) {
    switch (mode) {
      case ExposureMode.high:
        return 'High exposure';
      case ExposureMode.balanced:
        return 'Balanced exposure';
      case ExposureMode.low:
        return 'Low exposure';
    }
  }

  String _cameraLightModeLabel(CameraLightMode mode) {
    switch (mode) {
      case CameraLightMode.day:
        return 'Day mode';
      case CameraLightMode.night:
        return 'Night mode';
    }
  }

  String _cameraViewModeLabel(CameraViewMode mode) {
    switch (mode) {
      case CameraViewMode.standard:
        return 'Standard';
      case CameraViewMode.panorama:
        return 'Panorama';
    }
  }

  Future<_RecordingDirectorySelection?>
      _resolveRecordingDirectorySelection() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final selection = await _storageChannel.invokeMapMethod<String, dynamic>(
        'pickRecordingDirectory',
      );
      final selectedPath = selection?['path'] as String?;
      final selectedUri = selection?['uri'] as String?;
      if (selectedPath == null || selectedPath.trim().isEmpty) {
        return null;
      }

      return _RecordingDirectorySelection(
        path: selectedPath.trim(),
        uri: selectedUri?.trim(),
      );
    }

    final selectedPath = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Choose recording folder',
    );
    if (selectedPath == null || selectedPath.trim().isEmpty) {
      return null;
    }

    return _RecordingDirectorySelection(
      path: selectedPath.trim(),
    );
  }
}

const ColorFilter _nightModeColorFilter = ColorFilter.matrix([
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0.2126,
  0.7152,
  0.0722,
  0,
  0,
  0,
  0,
  0,
  1,
  0,
]);

class _RecordingDirectorySelection {
  const _RecordingDirectorySelection({
    required this.path,
    this.uri,
  });

  final String path;
  final String? uri;
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: AzureTheme.azureDark,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
      ),
    );
  }
}
