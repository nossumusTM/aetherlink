import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_view/camera_screen.dart';
import 'config/app_config.dart';
import 'geo/geo_monitor_screen.dart';
import 'geo/geo_position_screen.dart';
import 'monitor_view/monitor_screen.dart';
import 'routes/app_routes.dart';
import 'ui/azure_theme.dart';
import 'utils/paired_devices_storage.dart';
import 'utils/pairing_presence_service.dart';
import 'widgets/app_shell_ui.dart';
import 'widgets/pairing_panel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  runApp(const SputniApp());
}

class SputniApp extends StatelessWidget {
  const SputniApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sputni',
      debugShowCheckedModeBanner: false,
      theme: AzureTheme.theme(),
      builder: (context, child) {
        final adaptiveTheme = AzureTheme.adaptiveTheme(
          context,
          Theme.of(context),
        );
        return Theme(
          data: adaptiveTheme,
          child: child ?? const SizedBox.shrink(),
        );
      },
      initialRoute: AppRoutes.home,
      routes: {
        AppRoutes.home: (_) => const _HomeEntryScreen(),
        AppRoutes.dashboard: (_) => const _HomeScreen(),
        AppRoutes.pairedDevices: (_) => const _PairedDevicesScreen(),
        AppRoutes.tracker: (_) => const _GeoScreen(),
        AppRoutes.camera: (_) => const CameraScreen(),
        AppRoutes.monitor: (_) => const MonitorScreen(),
        AppRoutes.geoPosition: (_) => const GeoPositionScreen(),
        AppRoutes.geoMonitor: (_) => const GeoMonitorScreen(),
      },
    );
  }
}

class _HomeEntryScreen extends StatefulWidget {
  const _HomeEntryScreen();

  @override
  State<_HomeEntryScreen> createState() => _HomeEntryScreenState();
}

class _HomeEntryScreenState extends State<_HomeEntryScreen>
    with SingleTickerProviderStateMixin {
  static const _introDuration = Duration(milliseconds: 2550);
  static const _switchDuration = Duration(milliseconds: 420);

  late final AnimationController _controller;
  Timer? _dismissTimer;
  bool _showIntro = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _introDuration)
      ..forward();
    _dismissTimer = Timer(_introDuration, () {
      if (!mounted) return;
      setState(() => _showIntro = false);
    });
  }

  @override
  void dispose() {
    _dismissTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: _switchDuration,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      child: _showIntro
          ? _LogoIntroScreen(
              key: const ValueKey('logo-intro'),
              animation: _controller,
            )
          : const _HomeScreen(key: ValueKey('home-screen')),
    );
  }
}

class _LogoIntroScreen extends StatelessWidget {
  const _LogoIntroScreen({
    super.key,
    required this.animation,
  });

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) {
    final panelScale = Tween<double>(
      begin: 0.84,
      end: 1.0,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutBack));
    final panelOpacity = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
    );
    final textOpacity = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.28, 0.82, curve: Curves.easeOut),
    );
    final textSlide = Tween<Offset>(
      begin: const Offset(0, 0.18),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
    final loadingProgress = CurvedAnimation(
      parent: animation,
      curve: const Interval(0.12, 0.96, curve: Curves.easeInOutCubic),
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AzureTheme.systemUiOverlayStyle,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Container(
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
                top: -90,
                left: -30,
                child: _HomeGlow(size: 240, color: Color(0x661279FF)),
              ),
              const Positioned(
                top: 170,
                right: -55,
                child: _HomeGlow(size: 210, color: Color(0x556BD7FF)),
              ),
              const Positioned(
                bottom: -110,
                left: 70,
                child: _HomeGlow(size: 270, color: Color(0x40B4DDFF)),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FadeTransition(
                        opacity: panelOpacity,
                        child: ScaleTransition(
                          scale: panelScale,
                          child: Container(
                            width: 156,
                            height: 156,
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(38),
                              color: Colors.white.withAlpha(20),
                              border: Border.all(
                                color: Colors.white.withAlpha(36),
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x24081A33),
                                  blurRadius: 40,
                                  offset: Offset(0, 24),
                                ),
                              ],
                            ),
                            child: Image.asset(
                              'assets/branding/sputni_intro_logo.png',
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      FadeTransition(
                        opacity: textOpacity,
                        child: SlideTransition(
                          position: textSlide,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                            decoration: BoxDecoration(
                              color: Colors.white.withAlpha(236),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: Colors.white.withAlpha(242),
                              ),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x22081A33),
                                  blurRadius: 28,
                                  offset: Offset(0, 14),
                                ),
                              ],
                            ),
                            child: Column(
                              children: [
                                Text(
                                  'Sputni',
                                  style: Theme.of(context)
                                      .textTheme
                                      .displaySmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w900,
                                        color: const Color(0xFF0A1C36),
                                        letterSpacing: -1.4,
                                      ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Camera and monitor, paired instantly.',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(
                                        color: const Color(0xFF31506F),
                                      ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 18),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: AnimatedBuilder(
                                    animation: loadingProgress,
                                    builder: (context, _) {
                                      final progress = loadingProgress.value;
                                      final percent = (progress * 100)
                                          .clamp(0, 100)
                                          .round();
                                      return Column(
                                        children: [
                                          LinearProgressIndicator(
                                            value: progress,
                                            minHeight: 8,
                                            backgroundColor:
                                                const Color(0xFFE4ECF5),
                                            valueColor:
                                                const AlwaysStoppedAnimation(
                                              Color(0xFF1D9BFF),
                                            ),
                                          ),
                                          const SizedBox(height: 10),
                                          Text(
                                            '$percent% loaded',
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelLarge
                                                ?.copyWith(
                                                  color:
                                                      const Color(0xFF47627C),
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                        ],
                                      );
                                    },
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeScreen extends StatefulWidget {
  const _HomeScreen({super.key});

  @override
  State<_HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<_HomeScreen> {
  Future<void> _openStandaloneRoute(String routeName) async {
    await Navigator.of(context).pushNamed(routeName);
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final reservedNavSpace =
        (mediaQuery.padding.bottom + 92).clamp(92.0, 124.0);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AzureTheme.systemUiOverlayStyle,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        bottomNavigationBar: SputniBottomNavigationBar(
          selectedDestination: SputniBottomNavDestination.live,
          onSelected: (destination) {
            switch (destination) {
              case SputniBottomNavDestination.live:
                return;
              case SputniBottomNavDestination.paired:
                unawaited(_openStandaloneRoute(AppRoutes.pairedDevices));
                return;
              case SputniBottomNavDestination.tracker:
                unawaited(_openStandaloneRoute(AppRoutes.tracker));
                return;
            }
          },
        ),
        body: Container(
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
                top: -70,
                left: -10,
                child: _HomeGlow(size: 220, color: Color(0x661279FF)),
              ),
              const Positioned(
                top: 140,
                right: -40,
                child: _HomeGlow(size: 190, color: Color(0x556BD7FF)),
              ),
              const Positioned(
                bottom: -90,
                left: 80,
                child: _HomeGlow(size: 250, color: Color(0x40B4DDFF)),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  mediaQuery.padding.top + 20,
                  20,
                  reservedNavSpace,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Sputni Live',
                      style: Theme.of(context)
                          .textTheme
                          .displaySmall
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Pair devices and control your environment.',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 24),
                    const Expanded(child: _MainDashboardTab()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MainDashboardTab extends StatelessWidget {
  const _MainDashboardTab();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 720;
        final isMobilePlatform = !kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.iOS ||
                defaultTargetPlatform == TargetPlatform.android);
        final compactGap = isMobilePlatform ? 12.0 : 16.0;
        final cards = [
          _RoleCard(
            title: 'Camera',
            subtitle:
                'Send live video with P2P-first ICE and relay fallback only when needed.',
            actionLabel: 'Open camera',
            assetPath: 'assets/media/cameraview.png',
            onTap: () => Navigator.pushNamed(context, AppRoutes.camera),
          ),
          _RoleCard(
            title: 'Monitor',
            subtitle:
                'Watch the stream with viewer-focused controls and connection reporting.',
            actionLabel: 'Open monitor',
            assetPath: 'assets/media/monitorview.png',
            onTap: () => Navigator.pushNamed(
              context,
              AppRoutes.monitor,
            ),
          ),
        ];

        if (isCompact) {
          return Column(
            children: [
              Expanded(child: cards[0]),
              SizedBox(height: compactGap),
              Expanded(child: cards[1]),
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: cards[0]),
            const SizedBox(width: 16),
            Expanded(child: cards[1]),
          ],
        );
      },
    );
  }
}

class _StandaloneSectionScreen extends StatelessWidget {
  const _StandaloneSectionScreen({
    required this.title,
    required this.subtitle,
    required this.child,
    this.bottomNavigationBar,
    this.showBackButton = true,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final Widget? bottomNavigationBar;
  final bool showBackButton;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AzureTheme.systemUiOverlayStyle,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBody: true,
        bottomNavigationBar: bottomNavigationBar,
        body: EdgeSwipeBack(
          enabled: Navigator.of(context).canPop(),
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
              fit: StackFit.expand,
              children: [
                const Positioned(
                  top: -80,
                  left: -30,
                  child: _HomeGlow(size: 220, color: Color(0x661279FF)),
                ),
                const Positioned(
                  top: 150,
                  right: -40,
                  child: _HomeGlow(size: 190, color: Color(0x556BD7FF)),
                ),
                const Positioned(
                  bottom: -90,
                  left: 80,
                  child: _HomeGlow(size: 250, color: Color(0x40B4DDFF)),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    mediaQuery.padding.top + 18,
                    20,
                    bottomNavigationBar == null
                        ? mediaQuery.padding.bottom + 20
                        : (mediaQuery.padding.bottom + 92).clamp(92.0, 124.0),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (showBackButton)
                        IconButton(
                          onPressed: () => Navigator.of(context).maybePop(),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                      if (showBackButton) const SizedBox(height: 6),
                      Text(
                        title,
                        style: Theme.of(context)
                            .textTheme
                            .displaySmall
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 18),
                      Expanded(child: child),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PairedDevicesScreen extends StatelessWidget {
  const _PairedDevicesScreen();

  @override
  Widget build(BuildContext context) {
    return _StandaloneSectionScreen(
      title: 'Devices',
      subtitle: 'Reconnect to remembered QR pairings.',
      showBackButton: false,
      bottomNavigationBar: SputniBottomNavigationBar(
        selectedDestination: SputniBottomNavDestination.paired,
        onSelected: (destination) async {
          switch (destination) {
            case SputniBottomNavDestination.live:
              await Navigator.of(
                context,
              ).pushReplacementNamed(AppRoutes.dashboard);
              break;
            case SputniBottomNavDestination.paired:
              break;
            case SputniBottomNavDestination.tracker:
              await Navigator.of(
                context,
              ).pushReplacementNamed(AppRoutes.tracker);
              break;
          }
        },
      ),
      child: const _PairedDevicesTab(),
    );
  }
}

class _GeoScreen extends StatelessWidget {
  const _GeoScreen();

  @override
  Widget build(BuildContext context) {
    return _StandaloneSectionScreen(
      title: 'Sputni Geo',
      subtitle: 'Workspace for upcoming GPS tracking sessions.',
      showBackButton: false,
      bottomNavigationBar: SputniBottomNavigationBar(
        selectedDestination: SputniBottomNavDestination.tracker,
        onSelected: (destination) async {
          switch (destination) {
            case SputniBottomNavDestination.live:
              await Navigator.of(
                context,
              ).pushReplacementNamed(AppRoutes.dashboard);
              break;
            case SputniBottomNavDestination.paired:
              await Navigator.of(
                context,
              ).pushReplacementNamed(AppRoutes.pairedDevices);
              break;
            case SputniBottomNavDestination.tracker:
              break;
          }
        },
      ),
      child: const _GeoDashboardTab(),
    );
  }
}

class _PairedDevicesTab extends StatefulWidget {
  const _PairedDevicesTab();

  @override
  State<_PairedDevicesTab> createState() => _PairedDevicesTabState();
}

class _PairedDevicesTabState extends State<_PairedDevicesTab> {
  static const _presenceRefreshInterval = Duration(seconds: 8);

  List<SavedPairingLink> _savedLinks = const [];
  final Map<String, PairingPresenceStatus?> _presenceByPayload = {};
  late final AppConfig _config;
  _SavedPairingCategory _activeCategory = _SavedPairingCategory.live;
  bool _isLoading = true;
  Timer? _presenceRefreshTimer;

  @override
  void initState() {
    super.initState();
    _config = AppConfig.fromEnvironment();
    _loadSavedLinks();
    _presenceRefreshTimer = Timer.periodic(
      _presenceRefreshInterval,
      (_) => _refreshPresence(),
    );
  }

  @override
  void dispose() {
    _presenceRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadSavedLinks() async {
    final savedLinks = await PairedDevicesStorage.loadAll();
    if (!mounted) return;

    setState(() {
      _savedLinks = savedLinks;
      _isLoading = false;
    });

    await _refreshPresence(savedLinks);
  }

  Future<void> _openSavedLink(SavedPairingLink link) async {
    await PairedDevicesStorage.savePayload(
      link.payload,
      launchRole: link.launchRole,
      peerPayload: link.peerPayload,
    );
    if (!mounted) return;

    final destination = _destinationForSavedLink(link);
    if (destination == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This saved QR pairing link has an unsupported role.'),
        ),
      );
      return;
    }

    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => destination));
    await _loadSavedLinks();
  }

  Future<void> _removeSavedLink(SavedPairingLink link) async {
    await PairedDevicesStorage.removePayload(
      link.payload,
      launchRole: link.launchRole,
      peerPayload: link.peerPayload,
    );
    await _loadSavedLinks();
  }

  Future<void> _refreshPresence([List<SavedPairingLink>? savedLinks]) async {
    final links = savedLinks ?? _savedLinks;
    if (links.isEmpty) {
      if (!mounted) return;
      setState(() => _presenceByPayload.clear());
      return;
    }

    final entries = await Future.wait(
      links.map((link) async {
        final pairingData = parsePairingPayload(link.payload);
        if (pairingData == null) {
          return MapEntry<String, PairingPresenceStatus?>(link.payload, null);
        }

        final signalingUrl = pairingData.signalingUrl?.trim().isNotEmpty == true
            ? pairingData.signalingUrl!
            : _config.signalingUrl;
        final presence = await PairingPresenceService.fetchPresence(
          signalingUrl: signalingUrl,
          roomId: pairingData.roomId,
          deviceId: link.launchRole == null ? pairingData.deviceId : null,
        );
        return MapEntry<String, PairingPresenceStatus?>(link.payload, presence);
      }),
    );
    if (!mounted) return;

    setState(() {
      _presenceByPayload
        ..clear()
        ..addEntries(entries);
    });
  }

  ButtonStyle _devicesToolbarButtonStyle(
    BuildContext context, {
    required bool selected,
  }) {
    final activeBackground =
        Theme.of(context).colorScheme.primary.withValues(alpha: 0.10);
    return TextButton.styleFrom(
      minimumSize: const Size(88, 40),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      backgroundColor: selected ? activeBackground : Colors.transparent,
      foregroundColor: AzureTheme.ink,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
    );
  }

  Widget _buildCategoryButton(
    BuildContext context, {
    required _SavedPairingCategory category,
    required String label,
  }) {
    final isSelected = _activeCategory == category;
    return TextButton(
      onPressed: () => setState(() => _activeCategory = category),
      style: _devicesToolbarButtonStyle(context, selected: isSelected),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }

  Widget? _destinationForSavedLink(SavedPairingLink link) {
    final payload = link.payload;
    final launchRole = link.launchRole?.toLowerCase();
    if (launchRole != null && launchRole.isNotEmpty) {
      return switch (launchRole) {
        'camera' => CameraScreen(
            initialPairingLink: payload,
            autoStartOnLoad: true,
          ),
        'monitor' => MonitorScreen(
            initialPairingLink: payload,
            autoConnectOnLoad: true,
          ),
        'geo-position' => GeoPositionScreen(
            initialPairingLink: payload,
            autoStartOnLoad: true,
          ),
        'geo-monitor' => GeoMonitorScreen(
            initialPairingLink: payload,
            autoConnectOnLoad: true,
          ),
        _ => null,
      };
    }

    final pairingData = parsePairingPayload(payload);
    final targetRole = pairingData?.role?.toLowerCase();

    return switch (targetRole) {
      'camera' => MonitorScreen(
          initialPairingLink: payload,
          autoConnectOnLoad: true,
        ),
      'monitor' => CameraScreen(
          initialPairingLink: payload,
          autoStartOnLoad: true,
        ),
      'geo-position' => GeoMonitorScreen(
          initialPairingLink: payload,
          autoConnectOnLoad: true,
        ),
      'geo-monitor' => GeoPositionScreen(
          initialPairingLink: payload,
          autoStartOnLoad: true,
        ),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final filteredLinks = _savedLinks.where((link) {
      final payloadData = parsePairingPayload(link.payload);
      final family = pairingFeatureFamilyForRole(payloadData?.role);
      return switch (_activeCategory) {
        _SavedPairingCategory.live =>
          family == null || family == PairingFeatureFamily.liveCamera,
        _SavedPairingCategory.geo => family == PairingFeatureFamily.geo,
      };
    }).toList(growable: false);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_savedLinks.isEmpty) {
      return SurfacePanel(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.qr_code_2_rounded,
              size: 38,
              color: AzureTheme.azureDark.withValues(alpha: 0.82),
            ),
            const SizedBox(height: 14),
            Text(
              'No paired devices yet',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              'Scan a QR pairing code from camera or monitor mode and the link will be remembered here for one-tap reconnects.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AzureTheme.ink.withValues(alpha: 0.72),
                    height: 1.4,
                  ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            _buildCategoryButton(
              context,
              category: _SavedPairingCategory.live,
              label: 'Live',
            ),
            _buildCategoryButton(
              context,
              category: _SavedPairingCategory.geo,
              label: 'Geo',
            ),
            TextButton.icon(
              onPressed: _loadSavedLinks,
              style: _devicesToolbarButtonStyle(context, selected: false),
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (filteredLinks.isEmpty)
          Expanded(
            child: SurfacePanel(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _activeCategory == _SavedPairingCategory.live
                        ? Icons.videocam_rounded
                        : Icons.location_history_rounded,
                    size: 38,
                    color: AzureTheme.azureDark.withValues(alpha: 0.82),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _activeCategory == _SavedPairingCategory.live
                        ? 'No live pairings yet'
                        : 'No Geo pairings yet',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _activeCategory == _SavedPairingCategory.live
                        ? 'Saved camera and monitor QR pairings will appear here.'
                        : 'Saved Position and Geo Monitor QR pairings will appear here.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AzureTheme.ink.withValues(alpha: 0.72),
                          height: 1.4,
                        ),
                  ),
                ],
              ),
            ),
          ),
        if (filteredLinks.isNotEmpty)
          Expanded(
            child: ListView.separated(
              itemCount: filteredLinks.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final link = filteredLinks[index];
                final sessionPairingData = parsePairingPayload(link.payload);
                final peerPairingData =
                    parsePairingPayload(link.peerPayload ?? link.payload);
                final targetRole = peerPairingData?.role?.toLowerCase();
                final roleTitle = switch (targetRole) {
                  'camera' => 'Camera device',
                  'monitor' => 'Monitor device',
                  'geo-position' => 'Geo position device',
                  'geo-monitor' => 'Geo monitor device',
                  _ => 'Saved pairing',
                };
                final targetAction = switch (link.launchRole?.toLowerCase()) {
                  'camera' => 'Open camera',
                  'monitor' => 'Open monitor',
                  'geo-position' => 'Open position',
                  'geo-monitor' => 'Open monitor',
                  _ when targetRole == 'camera' => 'Open monitor',
                  _ when targetRole == 'monitor' => 'Open camera',
                  _ when targetRole == 'geo-position' => 'Open monitor',
                  _ when targetRole == 'geo-monitor' => 'Open position',
                  _ => 'Open',
                };
                final roomId = sessionPairingData?.roomId ?? 'Unknown room';
                final presence = _presenceByPayload[link.payload];
                final isOnline = presence?.online == true;
                final statusLabel = switch (presence) {
                  null => 'Checking',
                  _ when isOnline => 'Online',
                  _ => 'Offline',
                };
                final statusColor = switch (presence) {
                  null => AzureTheme.warning,
                  _ when isOnline => AzureTheme.success,
                  _ => Theme.of(context).colorScheme.error,
                };
                final signalingHost = sessionPairingData?.signalingUrl == null
                    ? 'Default signaling server'
                    : (Uri.tryParse(sessionPairingData!.signalingUrl!)
                                ?.host
                                .isNotEmpty ??
                            false)
                        ? Uri.parse(sessionPairingData.signalingUrl!).host
                        : sessionPairingData.signalingUrl!;

                return SurfacePanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.55),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: AzureTheme.glassStroke),
                            ),
                            child: Icon(
                              targetRole == 'camera'
                                  ? Icons.videocam_rounded
                                  : Icons.monitor_rounded,
                              color: AzureTheme.azureDark,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  roleTitle,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w800),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Room: $roomId',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(
                                        color: AzureTheme.ink
                                            .withValues(alpha: 0.7),
                                      ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          StatusPill(
                            label: statusLabel,
                            color: statusColor,
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(
                        signalingHost,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: AzureTheme.ink.withValues(alpha: 0.78),
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Last used ${_formatLastUsed(link.lastUsedAt)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AzureTheme.ink.withValues(alpha: 0.62),
                            ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () => _openSavedLink(link),
                              child: Text(targetAction),
                            ),
                          ),
                          const SizedBox(width: 10),
                          IconButton.filledTonal(
                            tooltip: 'Forget device',
                            onPressed: () => _removeSavedLink(link),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  String _formatLastUsed(DateTime value) {
    final now = DateTime.now();
    final difference = now.difference(value);

    if (difference.inMinutes < 1) {
      return 'just now';
    }
    if (difference.inHours < 1) {
      return '${difference.inMinutes} min ago';
    }
    if (difference.inDays < 1) {
      return '${difference.inHours} h ago';
    }
    if (difference.inDays < 7) {
      return '${difference.inDays} d ago';
    }

    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${value.year}-${twoDigits(value.month)}-${twoDigits(value.day)}';
  }
}

enum _SavedPairingCategory { live, geo }

class _GeoDashboardTab extends StatelessWidget {
  const _GeoDashboardTab();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 720;
        final isMobilePlatform = !kIsWeb &&
            (defaultTargetPlatform == TargetPlatform.iOS ||
                defaultTargetPlatform == TargetPlatform.android);
        final compactGap = isMobilePlatform ? 12.0 : 16.0;
        final cards = [
          _RoleCard(
            title: 'Position',
            subtitle:
                'Prepare location sharing sessions and publish future GPS updates from this device.',
            actionLabel: 'Open position',
            assetPath: 'assets/media/positionview.jpg',
            onTap: () => Navigator.pushNamed(context, AppRoutes.geoPosition),
          ),
          _RoleCard(
            title: 'Monitor',
            subtitle:
                'Follow shared geo sessions and upcoming viewer-side location activity in one place.',
            actionLabel: 'Open monitor',
            assetPath: 'assets/media/positionmonitorview.jpg',
            onTap: () => Navigator.pushNamed(context, AppRoutes.geoMonitor),
          ),
        ];

        if (isCompact) {
          return Column(
            children: [
              Expanded(child: cards[0]),
              SizedBox(height: compactGap),
              Expanded(child: cards[1]),
            ],
          );
        }

        return Row(
          children: [
            Expanded(child: cards[0]),
            SizedBox(width: compactGap),
            Expanded(child: cards[1]),
          ],
        );
      },
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.assetPath,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String actionLabel;
  final String assetPath;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isMobilePlatform = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isShortCard = constraints.maxHeight < 300;
        final contentPadding = isMobilePlatform
            ? (isShortCard ? 16.0 : 20.0)
            : (isShortCard ? 18.0 : 24.0);
        final titleSpacing = isShortCard ? 6.0 : 8.0;
        final buttonSpacing = isMobilePlatform
            ? (isShortCard ? 12.0 : 16.0)
            : (isShortCard ? 14.0 : 20.0);
        final titleStyle = isShortCard
            ? Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                )
            : Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                );
        final subtitleStyle = (isShortCard
                ? Theme.of(context).textTheme.bodyMedium
                : Theme.of(context).textTheme.bodyLarge)
            ?.copyWith(
          fontSize: isMobilePlatform ? (isShortCard ? 12.5 : 13.0) : null,
          height: isMobilePlatform ? 1.3 : null,
          color: Colors.white.withValues(alpha: 0.88),
        );

        return Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    border: Border.all(
                      color: AzureTheme.glassStroke,
                      width: 1.1,
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Image.asset(
                    assetPath,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) {
                      return Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF0B5DCC), Color(0xFF071A36)],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.18),
                        Colors.black.withValues(alpha: 0.28),
                        Colors.black.withValues(alpha: 0.7),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: EdgeInsets.all(contentPadding),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Spacer(),
                      Text(
                        title,
                        style: titleStyle,
                      ),
                      SizedBox(height: titleSpacing),
                      Text(
                        subtitle,
                        maxLines: isShortCard ? 2 : 3,
                        overflow: TextOverflow.ellipsis,
                        style: subtitleStyle,
                      ),
                      SizedBox(height: buttonSpacing),
                      ElevatedButton(
                        onPressed: onTap,
                        style: ElevatedButton.styleFrom(
                          minimumSize: Size.fromHeight(
                            isMobilePlatform
                                ? (isShortCard ? 44 : 50)
                                : (isShortCard ? 48 : 56),
                          ),
                          padding: EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: isMobilePlatform
                                ? (isShortCard ? 10 : 12)
                                : (isShortCard ? 12 : 16),
                          ),
                          backgroundColor: Colors.white.withValues(alpha: 0.18),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.white.withValues(
                            alpha: 0.1,
                          ),
                          disabledForegroundColor: Colors.white54,
                          shadowColor: Colors.transparent,
                          elevation: 0,
                          side: BorderSide.none,
                        ),
                        child: Text(actionLabel),
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

class _HomeGlow extends StatelessWidget {
  const _HomeGlow({
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
            colors: [color, color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}
