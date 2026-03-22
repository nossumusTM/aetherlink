import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/azure_theme.dart';
import '../widgets/app_shell_ui.dart';
import 'geo_settings.dart';

enum GeoSettingsSheetMode { position, monitor }

Future<GeoSettings?> showGeoSettingsSheet({
  required BuildContext context,
  required String title,
  required GeoSettings initialSettings,
  required bool turnAvailable,
  required GeoSettingsSheetMode mode,
}) {
  return showModalBottomSheet<GeoSettings>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _GeoSettingsSheet(
      title: title,
      initialSettings: initialSettings,
      turnAvailable: turnAvailable,
      mode: mode,
    ),
  );
}

class _GeoSettingsSheet extends StatefulWidget {
  const _GeoSettingsSheet({
    required this.title,
    required this.initialSettings,
    required this.turnAvailable,
    required this.mode,
  });

  final String title;
  final GeoSettings initialSettings;
  final bool turnAvailable;
  final GeoSettingsSheetMode mode;

  @override
  State<_GeoSettingsSheet> createState() => _GeoSettingsSheetState();
}

class _GeoSettingsSheetState extends State<_GeoSettingsSheet> {
  late GeoSettings _settings = widget.initialSettings;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final bottomSafeInset = math.max(
      mediaQuery.viewPadding.bottom,
      mediaQuery.systemGestureInsets.bottom,
    );
    final isPositionMode = widget.mode == GeoSettingsSheetMode.position;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        20,
        16,
        20 + bottomSafeInset + mediaQuery.viewInsets.bottom,
      ),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 760,
            maxHeight:
                mediaQuery.size.height - mediaQuery.padding.top - 44,
          ),
          child: GlassPanel(
            borderRadius: 28,
            opacity: 0.78,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
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
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 16),
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
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _SectionTitle('Live Connection'),
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('Prefer direct P2P'),
                                  subtitle: const Text(
                                    'Use the WebRTC data channel first and relay over the signaling server only when needed.',
                                  ),
                                  value: _settings.preferDirectP2P,
                                  onChanged: (value) => setState(
                                    () => _settings = _settings.copyWith(
                                      preferDirectP2P: value,
                                    ),
                                  ),
                                ),
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('TURN fallback'),
                                  subtitle: Text(
                                    widget.turnAvailable
                                        ? 'Keep relay available if direct transport fails.'
                                        : 'TURN server not configured in environment.',
                                  ),
                                  value: _settings.enableTurnFallback &&
                                      widget.turnAvailable,
                                  onChanged: widget.turnAvailable
                                      ? (value) => setState(
                                            () => _settings =
                                                _settings.copyWith(
                                              enableTurnFallback: value,
                                            ),
                                          )
                                      : null,
                                ),
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title:
                                      const Text('Use multiple STUN servers'),
                                  subtitle: const Text(
                                    'Cycle between the primary STUN route or the full STUN pool.',
                                  ),
                                  value: _settings.useMultipleStunServers,
                                  onChanged: (value) => setState(
                                    () => _settings = _settings.copyWith(
                                      useMultipleStunServers: value,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          SurfacePanel(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const _SectionTitle('Tracking'),
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('Wake up mode'),
                                  subtitle: const Text(
                                    'Keep the device awake while Geo is active.',
                                  ),
                                  value: _settings.keepAwake,
                                  onChanged: (value) => setState(
                                    () => _settings = _settings.copyWith(
                                      keepAwake: value,
                                    ),
                                  ),
                                ),
                                if (isPositionMode)
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title:
                                        const Text('Background tracking'),
                                    subtitle: const Text(
                                      'Continue receiving position updates while the app is in the background.',
                                    ),
                                    value: _settings.backgroundTracking,
                                    onChanged: (value) => setState(
                                      () => _settings = _settings.copyWith(
                                        backgroundTracking: value,
                                      ),
                                    ),
                                  ),
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('High accuracy'),
                                  subtitle: const Text(
                                    'Use best available navigation accuracy for updates.',
                                  ),
                                  value: _settings.highAccuracy,
                                  onChanged: (value) => setState(
                                    () => _settings = _settings.copyWith(
                                      highAccuracy: value,
                                    ),
                                  ),
                                ),
                                SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title:
                                      const Text('Auto center on update'),
                                  subtitle: const Text(
                                    'Keep the latest position centered on the map.',
                                  ),
                                  value: _settings.autoCenterOnUpdate,
                                  onChanged: (value) => setState(
                                    () => _settings = _settings.copyWith(
                                      autoCenterOnUpdate: value,
                                    ),
                                  ),
                                ),
                                if (isPositionMode)
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('Share heading'),
                                    subtitle: const Text(
                                      'Include heading values with updates when available.',
                                    ),
                                    value: _settings.shareHeading,
                                    onChanged: (value) => setState(
                                      () => _settings = _settings.copyWith(
                                        shareHeading: value,
                                      ),
                                    ),
                                  ),
                                if (isPositionMode)
                                  SwitchListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: const Text('Share speed'),
                                    subtitle: const Text(
                                      'Include current movement speed with updates when available.',
                                    ),
                                    value: _settings.shareSpeed,
                                    onChanged: (value) => setState(
                                      () => _settings = _settings.copyWith(
                                        shareSpeed: value,
                                      ),
                                    ),
                                  ),
                                const SizedBox(height: 8),
                                Text(
                                  'Distance filter: ${_settings.distanceFilterMeters} m',
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                Slider(
                                  min: 5,
                                  max: 100,
                                  divisions: 19,
                                  value: _settings.distanceFilterMeters.toDouble(),
                                  label: '${_settings.distanceFilterMeters} m',
                                  onChanged: (value) => setState(
                                    () => _settings = _settings.copyWith(
                                      distanceFilterMeters: value.round(),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Update interval: ${_settings.updateIntervalSeconds} s',
                                  style: Theme.of(context).textTheme.titleMedium,
                                ),
                                Slider(
                                  min: 1,
                                  max: 30,
                                  divisions: 29,
                                  value: _settings.updateIntervalSeconds.toDouble(),
                                  label: '${_settings.updateIntervalSeconds} s',
                                  onChanged: (value) => setState(
                                    () => _settings = _settings.copyWith(
                                      updateIntervalSeconds: value.round(),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          SurfacePanel(
                            child: SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: const Text('Connection report'),
                              subtitle: const Text(
                                'Show transport state and fallback details on the dashboard.',
                              ),
                              value: _settings.showConnectionReport,
                              onChanged: (value) => setState(
                                () => _settings = _settings.copyWith(
                                  showConnectionReport: value,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 12, 0, 24),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () =>
                                Navigator.of(context).pop(_settings),
                            child: const Text('Apply'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
            color: AzureTheme.azureDark,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
          ),
    );
  }
}
