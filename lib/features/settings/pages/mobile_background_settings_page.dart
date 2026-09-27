import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/mobile_background_settings.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/mobile_background.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/option_sheet.dart';
import '../../../shared/widgets/ios_settings_rows.dart';
import 'background_overlay_settings_page.dart';

/// Android background execution: the foreground service, its notifications
/// and overlay, and the permissions and runtime state behind them.
class MobileBackgroundSettingsPage extends StatefulWidget {
  const MobileBackgroundSettingsPage({super.key, this.coordinator});

  final MobileBackgroundCoordinator? coordinator;

  @override
  State<MobileBackgroundSettingsPage> createState() =>
      _MobileBackgroundSettingsPageState();
}

class _MobileBackgroundSettingsPageState
    extends State<MobileBackgroundSettingsPage>
    with WidgetsBindingObserver {
  late final coordinator =
      widget.coordinator ?? MobileBackgroundCoordinator.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    coordinator.addListener(_statusChanged);
    unawaited(
      coordinator.initialize().then((_) => coordinator.refreshStatus()),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(coordinator.refreshStatus());
    }
  }

  void _statusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    coordinator.removeListener(_statusChanged);
    super.dispose();
  }

  Future<void> _save(
    MobileBackgroundSettings value, {
    String? permission,
  }) async {
    final l10n = AppLocalizations.of(context)!;
    final settings = context.read<SettingsProvider>();
    await settings.setMobileBackground(value);
    // A slower earlier write must not reapply a switch the user just changed.
    if (!identical(settings.mobileBackground, value)) return;
    await coordinator.configure(settings.mobileBackground, l10n);
    if (permission != null) await coordinator.requestPermission(permission);
    await coordinator.refreshStatus();
  }

  Future<void> _permission(String permission) async {
    await coordinator.requestPermission(permission);
    await coordinator.refreshStatus();
  }

  Future<void> _open(String destination) async {
    await coordinator.openSettings(destination);
    await coordinator.refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final value = context.watch<SettingsProvider>().mobileBackground;
    final status = coordinator.status;
    String grant(bool allowed) =>
        allowed ? l.backgroundPermissionGranted : l.backgroundPermissionDenied;
    String active(String key) =>
        status.flag(key) ? l.backgroundRuntimeActive : l.backgroundRuntimeIdle;
    String visibility(
      BackgroundCompletionVisibility choice,
    ) => switch (choice) {
      BackgroundCompletionVisibility.immediate => l.backgroundFinishImmediately,
      BackgroundCompletionVisibility.oneMinute => l.backgroundFinishOneMinute,
      BackgroundCompletionVisibility.fiveMinutes =>
        l.backgroundFinishFiveMinutes,
      BackgroundCompletionVisibility.untilForeground =>
        l.backgroundFinishUntilForeground,
    };
    final nativeError = status.text('lastError');
    final error =
        coordinator.lastError ??
        (nativeError.isEmpty ? l.backgroundNoError : nativeError);

    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: Tooltip(
          message: l.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ArrowLeft,
            color: cs.onSurface,
            size: 22,
            minSize: 44,
            semanticLabel: l.settingsPageBackButton,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(l.backgroundSettingsTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          SectionCard(
            children: _withDividers([
              _toggle(
                'execution',
                Lucide.Activity,
                l.backgroundAndroidEnabled,
                l.backgroundAndroidEnabledDetail,
                value.androidEnabled,
                (on) => _save(value.copyWith(androidEnabled: on)),
              ),
              _toggle(
                'notifications',
                Lucide.Bell,
                l.backgroundNotifications,
                l.backgroundNotificationsDetail,
                value.notificationsEnabled,
                (on) => _save(
                  value.copyWith(notificationsEnabled: on),
                  permission: on && !status.flag('notificationsAuthorized')
                      ? 'notifications'
                      : null,
                ),
              ),
              _toggle(
                'privacy',
                Lucide.Shield,
                l.backgroundPrivacy,
                l.backgroundPrivacyDetail,
                value.privacyMode,
                (on) => _save(value.copyWith(privacyMode: on)),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          SectionCard(
            children: _withDividers([
              _toggle(
                'overlay',
                Lucide.Layers,
                l.backgroundOverlay,
                l.backgroundOverlayDetail,
                value.overlayEnabled,
                (on) => _save(
                  value.copyWith(overlayEnabled: on),
                  permission: on && !status.flag('overlayAuthorized')
                      ? 'overlay'
                      : null,
                ),
              ),
              _toggle(
                'liveUpdates',
                Lucide.Zap,
                l.backgroundLiveUpdates,
                status.flag('liveUpdatesSupported')
                    ? l.backgroundLiveUpdatesDetail
                    : l.backgroundUnsupported,
                value.liveUpdatesEnabled,
                (on) => _save(value.copyWith(liveUpdatesEnabled: on)),
              ),
              IosNavRow(
                key: const ValueKey('completionVisibility'),
                icon: Lucide.Timer,
                label: l.backgroundFinishVisibility,
                subtitle: visibility(value.completionVisibility),
                onTap: () async {
                  final choice =
                      await showOptionSheet<BackgroundCompletionVisibility>(
                        context,
                        title: l.backgroundFinishVisibility,
                        selected: value.completionVisibility,
                        items: BackgroundCompletionVisibility.values
                            .map(
                              (choice) => OptionSheetItem(
                                value: choice,
                                label: visibility(choice),
                              ),
                            )
                            .toList(),
                      );
                  if (choice != null && context.mounted) {
                    await _save(
                      context
                          .read<SettingsProvider>()
                          .mobileBackground
                          .copyWith(completionVisibility: choice),
                    );
                  }
                },
              ),
            ]),
          ),
          IosSectionFooter(text: l.backgroundFinishVisibilityDetail),
          const SizedBox(height: 16),
          SectionCard(
            children: [
              IosNavRow(
                key: const ValueKey('overlayAppearance'),
                icon: Lucide.SlidersHorizontal,
                label: l.backgroundOverlayAppearance,
                subtitle: l.backgroundOverlayAppearanceDetail,
                subtitleMaxLines: 2,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        BackgroundOverlaySettingsPage(coordinator: coordinator),
                  ),
                ),
              ),
            ],
          ),
          IosSectionHeader(text: l.backgroundPermissionsTitle),
          SectionCard(
            children: _withDividers([
              _action(
                Lucide.Bell,
                l.backgroundNotificationsPermission,
                grant(status.flag('notificationsAuthorized')),
                () => _permission('notifications'),
              ),
              _action(
                Lucide.Settings,
                l.backgroundCompletionChannel,
                grant(status.flag('completionChannelEnabled')),
                () => _open('channels'),
              ),
              _action(
                Lucide.Activity,
                l.backgroundOngoingChannel,
                grant(status.flag('ongoingChannelEnabled')),
                () => _open('ongoingChannel'),
              ),
              _action(
                Lucide.Battery,
                l.backgroundBatteryOptimization,
                grant(status.flag('batteryExempt')),
                () => _open('battery'),
                subtitle: l.backgroundBatteryOptimizationDetail,
              ),
              _action(
                Lucide.Power,
                l.backgroundAutostart,
                l.backgroundPermissionUnknown,
                () => _open('autostart'),
                subtitle:
                    '${status.text('manufacturer')} · ${l.backgroundAutostartDetail}',
              ),
              _action(
                Lucide.Layers,
                l.backgroundOverlay,
                grant(status.flag('overlayAuthorized')),
                () => _open('overlay'),
              ),
              _action(
                Lucide.Zap,
                l.backgroundLiveUpdates,
                grant(status.flag('liveUpdatesAuthorized')),
                () => _open('liveUpdates'),
              ),
              _action(
                Lucide.Settings,
                l.backgroundSystemSettings,
                '',
                () => _open('app'),
              ),
            ]),
          ),
          IosSectionHeader(text: l.backgroundRuntimeTitle),
          SectionCard(
            children: _withDividers([
              _status(
                l.backgroundTasks,
                status.text('activeTasks').isEmpty
                    ? '0'
                    : status.text('activeTasks'),
              ),
              _status(
                l.backgroundAndroidEnabled,
                active('foregroundServiceActive'),
              ),
              _status(l.backgroundOverlayActive, active('overlayVisible')),
              _status(l.backgroundLiveUpdates, active('liveUpdatePromoted')),
              _status(l.backgroundLastError, error),
            ]),
          ),
          IosSectionFooter(text: l.backgroundAndroidLimit),
        ],
      ),
    );
  }

  List<Widget> _withDividers(List<Widget> rows) => [
    for (var i = 0; i < rows.length; i++) ...[
      if (i > 0) const IosRowDivider(),
      rows[i],
    ],
  ];

  Widget _toggle(
    String key,
    IconData icon,
    String title,
    String detail,
    bool value,
    Future<void> Function(bool) change,
  ) => IosSwitchRow(
    key: ValueKey(key),
    icon: icon,
    label: title,
    subtitle: detail,
    value: value,
    onChanged: (value) => unawaited(change(value)),
  );

  Widget _action(
    IconData icon,
    String title,
    String detail,
    Future<void> Function() action, {
    String? subtitle,
  }) => IosNavRow(
    icon: icon,
    label: title,
    detailText: detail.isEmpty ? null : detail,
    subtitle: subtitle,
    subtitleMaxLines: subtitle == null ? 1 : null,
    onTap: () => unawaited(action()),
  );

  Widget _status(String title, String detail) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 15,
                color: cs.onSurface.withValues(alpha: 0.9),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              detail,
              textAlign: TextAlign.end,
              style: TextStyle(
                fontSize: 13,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
