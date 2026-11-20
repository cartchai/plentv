import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plezy/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../database/app_database.dart';
import '../../focus/focus_memory_tracker.dart';
import '../../focus/focusable_text_field.dart';
import '../../focus/input_mode_tracker.dart';
import '../../i18n/strings.g.dart';
import '../main_screen.dart';
import '../../mixins/mounted_set_state_mixin.dart';
import '../../mixins/refreshable.dart';
import '../../profiles/active_profile_binder.dart';
import '../../providers/account_preferences_controller.dart';
import '../../providers/hidden_libraries_provider.dart';
import '../../providers/download_provider.dart';
import '../../providers/libraries_provider.dart';
import '../../services/download_storage_service.dart';
import '../../services/file_picker_service.dart';
import '../../services/fork_backup_service.dart';
import '../../services/saf_storage_service.dart';
import '../../services/settings_export_service.dart';
import '../../providers/theme_provider.dart';
import '../../providers/seerr_account_provider.dart';
import '../../services/account_preferences_accounts.dart';
import '../../services/keyboard_shortcuts_service.dart';
import '../../services/background_work_diagnostics_service.dart';
import '../../services/settings_service.dart' as settings;
import '../../services/iptv/xtream_api.dart';
import '../../services/settings_mutation_service.dart';
import '../../services/supporter/supporter_mode.dart';
import '../../widgets/background_download_warning_banner.dart';
import '../../services/update_service.dart';
import '../../utils/dialogs.dart';
import '../../utils/snackbar_helper.dart';
import '../../utils/platform_detector.dart';
import '../../utils/update_dialog.dart';
import '../../widgets/desktop_app_bar.dart';
import '../../widgets/dialog_action_button.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/library_management_sheet.dart';
import '../../widgets/overlay_sheet.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_builder.dart';
import '../../widgets/settings_section.dart';
import '../../widgets/system_bottom_inset.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart';
import '../../watch_together/services/watch_party_relays.dart';
import 'about_screen.dart';
import 'add_connection_screen.dart';
import 'account_preferences_screen.dart';
import 'appearance_settings_screen.dart';
import 'general_settings_screen.dart';
import 'iptv_settings_screen.dart';
import 'live_tv_settings_screen.dart';
import 'last_crash_row.dart';
import 'storage_health_row.dart';
import 'keyboard_shortcuts_screen.dart';
import 'logs_screen.dart';
import 'playback_settings_screen.dart';
import '../profile/profile_switch_screen.dart';
import 'services_settings_screen.dart';
import 'settings_utils.dart';
import 'supporter_settings_tile.dart';
import 'tracker_service_info.dart';
import '../../widgets/loading_indicator_box.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.downloadDirectoryWritableChecker,
    this.settingsExporter,
    this.settingsImporter,
    this.forkBackupExporter,
    this.forkBackupImporter,
    this.backgroundWorkDiagnosticsService,
  });

  @visibleForTesting
  final Future<bool> Function(Directory directory)? downloadDirectoryWritableChecker;

  @visibleForTesting
  final Future<String?> Function()? settingsExporter;

  @visibleForTesting
  final Future<ImportResult?> Function()? settingsImporter;

  /// 1.2.22 §65: full-backup seams, mirroring [settingsExporter] /
  /// [settingsImporter] — a test provides the export / import itself so
  /// no database or file picker is needed.
  @visibleForTesting
  final Future<String?> Function()? forkBackupExporter;

  @visibleForTesting
  final Future<ForkBackupRestoreReport?> Function()? forkBackupImporter;

  @visibleForTesting
  final BackgroundWorkDiagnosticsService? backgroundWorkDiagnosticsService;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> with FocusableTab, MountedSetStateMixin {
  BackgroundWorkDiagnosticsService get _backgroundWorkDiagnostics =>
      widget.backgroundWorkDiagnosticsService ?? BackgroundWorkDiagnosticsService.instance;
  late final FocusMemoryTracker _focusTracker;

  // Focus tracking keys
  static const _kSupporter = 'supporter';
  static const _kGeneral = 'general';
  static const _kAppearance = 'appearance';
  static const _kPlayback = 'playback';
  static const _kLiveTv = 'live_tv';
  static const _kManageLibraries = 'manage_libraries';
  static const _kServices = 'services';
  static const _kIptv = 'iptv';
  static const _kDownloadLocation = 'download_location';
  static const _kDownloadOnWifiOnly = 'download_on_wifi_only';
  static const _kAutoRemoveWatchedDownloads = 'auto_remove_watched_downloads';
  static const _kBackgroundDownloads = 'background_downloads';
  static const _kVideoPlayerControls = 'video_player_controls';
  static const _kVideoPlayerNavigation = 'video_player_navigation';
  static const _kCompanionRemoteServer = 'companion_remote_server';
  static const _kLastCrash = 'last_crash';
  static const _kAutoHidePerformanceOverlay = 'auto_hide_performance_overlay';
  static const _kViewLogs = 'view_logs';
  static const _kClearImageCache = 'clear_image_cache';
  static const _kResetSettings = 'reset_settings';
  static const _kCheckForUpdates = 'check_for_updates';
  static const _kAutoCheckUpdatesOnStartup = 'auto_check_updates_on_startup';
  static const _kViewReleasesOnGitHub = 'view_releases_on_github';
  static const _kAbout = 'about';
  static const _kWatchTogetherRelay = 'watch_together_relay';
  static const _kSuperSpoof = 'super_spoof';
  static const _kExportSettings = 'export_settings';
  static const _kImportSettings = 'import_settings';
  static const _kExportForkBackup = 'export_fork_backup';
  static const _kImportForkBackup = 'import_fork_backup';
  static const _kAccountPreferences = 'account_preferences';

  KeyboardShortcutsService? _keyboardService;
  late final bool _keyboardShortcutsSupported = KeyboardShortcutsService.isPlatformSupported();

  // Update checking state
  bool _isCheckingForUpdate = false;
  Map<String, dynamic>? _updateInfo;

  @override
  void initState() {
    super.initState();
    _focusTracker = FocusMemoryTracker(debugLabelPrefix: 'settings');
    if (_keyboardShortcutsSupported) {
      KeyboardShortcutsService.getInstance().then((s) {
        setStateIfMounted(() => _keyboardService = s);
      });
    }
  }

  @override
  void dispose() {
    _focusTracker.dispose();
    super.dispose();
  }

  @override
  void focusActiveTabIfReady() {
    if (InputModeTracker.isKeyboardMode(context, listen: false)) {
      _focusTracker.restoreFocus(fallbackKey: _topTileKey);
    }
  }

  /// Focus key of the first tile: Supporter in purchasable builds,
  /// else General. (1.2.22 §66 U6: the creator donation link is cut.)
  static String get _topTileKey => supporterBuildMode == SupporterMode.iap
      ? _kSupporter
      : _kGeneral;

  void _navigateToSidebar() {
    MainScreenFocusScope.focusSidebarOf(context);
  }

  KeyEventResult _handleKeyEvent(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _navigateToSidebar();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  settings.SettingsService get _settingsService => settings.SettingsService.instance;

  @override
  Widget build(BuildContext context) {
    final hasLibraries = context.select<LibrariesProvider, bool>((p) => p.libraries.isNotEmpty);

    if (OverlaySheetController.maybeOf(context) != null) {
      return _buildContent(context, hasLibraries: hasLibraries);
    }

    // Settings is hosted by MainScreen on side-navigation layouts, but it is a
    // separate pushed route on phones. Add a route-local host only for the
    // latter, and build its content from below the host so adaptive sheets do
    // not fall back to modal routes with a competing Android back path.
    return OverlaySheetHost(
      canPop: true,
      child: Builder(builder: (hostContext) => _buildContent(hostContext, hasLibraries: hasLibraries)),
    );
  }

  Widget _buildContent(BuildContext sheetContext, {required bool hasLibraries}) {
    return Scaffold(
      body: Focus(
        onKeyEvent: _handleKeyEvent,
        // Horizontal-only SafeArea: the groups clear a landscape notch or
        // iPhone Duo's portrait sensor column.
        child: SafeArea(
          top: false,
          bottom: false,
          child: CustomScrollView(
            primary: false,
            slivers: [
              ExcludeFocus(child: CustomAppBar(title: Text(t.settings.title), pinned: true)),
              SliverList(
                delegate: SliverChildListDelegate([
                  const SizedBox(height: 8),
                  SettingsGroup(
                    children: [
                      if (supporterBuildMode == SupporterMode.iap)
                        SupporterSettingsTile(focusNode: _focusTracker.get(_kSupporter)),
                      _buildGeneralTile(),
                      _buildAppearanceTile(),
                      _buildPlaybackTile(),
                      _buildLiveTvTile(),
                      if (hasLibraries) _buildManageLibrariesTile(sheetContext),
                      _buildServicesTile(),
                    ],
                  ),

                  _buildConnectionsSection(sheetContext),

                  if (!PlatformDetector.isAppleTV()) _buildDownloadsSection(),

                  if (_keyboardShortcutsSupported || PlatformDetector.shouldActAsRemoteHost(sheetContext))
                    _buildControlsSection(sheetContext),

                  _buildAdvancedSection(),

                  if (UpdateService.isUpdateCheckAvailable) ...[_buildUpdateSection()],

                  // Hidden on Android TV / tvOS (no document picker); desktop in
                  // force-TV mode keeps it — FilePickerService works there.
                  if (!PlatformDetector.isTV() || PlatformDetector.isDesktopOS()) _buildBackupSection(),

                  const SizedBox(height: 24),
                  SettingsGroup(
                    children: [
                      SettingNavigationTile(
                        focusNode: _focusTracker.get(_kAbout),
                        icon: Symbols.info_rounded,
                        title: t.settings.about,
                        subtitle: t.settings.aboutDescription,
                        destinationBuilder: (context) => const AboutScreen(),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ]),
              ),
              const SliverSystemBottomInset(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGeneralTile() {
    return SettingNavigationTile(
      focusNode: _focusTracker.get(_kGeneral),
      icon: Symbols.settings_rounded,
      title: t.settings.general,
      subtitle: t.settings.generalDescription,
      destinationBuilder: (context) => const GeneralSettingsScreen(),
    );
  }

  Widget _buildAppearanceTile() {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, _) => SettingValueBuilder<int>(
        pref: settings.SettingsService.libraryDensity,
        builder: (context, libraryDensity, _) {
          final summary = '${themeModeLabel(themeProvider.themeMode)} · ${t.settings.libraryDensity} $libraryDensity';
          return SettingNavigationTile(
            focusNode: _focusTracker.get(_kAppearance),
            icon: Symbols.palette_rounded,
            title: t.settings.appearance,
            subtitle: summary,
            destinationBuilder: (context) => const AppearanceSettingsScreen(),
          );
        },
      ),
    );
  }

  Widget _buildPlaybackTile() {
    return SettingNavigationTile(
      focusNode: _focusTracker.get(_kPlayback),
      icon: Symbols.play_circle_rounded,
      title: t.settings.videoPlayback,
      subtitle: t.settings.videoPlaybackDescription,
      destinationBuilder: (context) => const PlaybackSettingsScreen(),
    );
  }

  Widget _buildLiveTvTile() {
    return SettingNavigationTile(
      focusNode: _focusTracker.get(_kLiveTv),
      icon: Symbols.live_tv_rounded,
      title: t.liveTv.title,
      subtitle: t.liveTv.settingsDescription,
      destinationBuilder: (context) => const LiveTvSettingsScreen(),
    );
  }

  Widget _buildManageLibrariesTile(BuildContext context) {
    return SettingNavigationTile(
      focusNode: _focusTracker.get(_kManageLibraries),
      icon: Symbols.video_library_rounded,
      title: t.libraries.manageLibraries,
      subtitle: t.settings.manageLibrariesDescription,
      onTap: () => showLibraryManagementSheet(context),
    );
  }

  Widget _buildServicesTile() {
    // The tracker account providers are watched through [TrackerServiceInfo].
    return Consumer<SeerrAccountProvider>(
      builder: (context, seerr, _) {
        final connectedNames = <String>[
          for (final info in TrackerServiceInfo.all)
            if (info.isConnected(context)) info.displayName,
          if (seerr.isConnected) t.services.names.seerr,
        ];
        final subtitle = connectedNames.isEmpty ? t.settings.servicesDescription : connectedNames.join(' · ');
        return SettingNavigationTile(
          focusNode: _focusTracker.get(_kServices),
          icon: Symbols.sync_rounded,
          title: t.settings.services,
          subtitle: subtitle,
          destinationBuilder: (_) => const ServicesSettingsScreen(),
        );
      },
    );
  }

  Widget _buildConnectionsSection(BuildContext context) {
    final active = context.select<ActiveProfileProvider, Profile?>((p) => p.active);
    final subtitle = active == null
        ? t.connections.addConnectionSubtitleNoProfile
        : t.connections.addConnectionSubtitleScoped(displayName: active.displayName);

    return SettingsGroup(
      title: t.connections.sectionTitle,
      children: [
        // Connections are managed per-profile (via the Profiles section
        // and each profile's detail screen). The shortcut here just opens
        // the picker scoped to the active profile so users can add a Plex
        // account, Jellyfin server, or borrow from another profile.
        SettingNavigationTile(
          icon: Symbols.add_link_rounded,
          title: t.connections.addConnection,
          subtitle: subtitle,
          onTap: () {
            final active = context.read<ActiveProfileProvider>().active;
            Navigator.push(context, MaterialPageRoute(builder: (_) => AddConnectionScreen(targetProfile: active)));
          },
        ),
        SettingNavigationTile(
          focusNode: _focusTracker.get(_kIptv),
          icon: Symbols.live_tv_rounded,
          title: t.iptv.title,
          subtitle: t.iptv.settingsDescription,
          destinationBuilder: (context) => const IptvSettingsScreen(),
        ),
        _buildProfilesTile(context),
        if (context.select<AccountPreferencesController, bool>((c) => c.accounts.isNotEmpty))
          _buildAccountPreferencesTile(context),
      ],
    );
  }

  /// Server-stored preferences for the accounts the active profile signed in
  /// with. Hidden when no account is reachable — an empty picker is noise.
  Widget _buildAccountPreferencesTile(BuildContext context) {
    final accounts = context.select<AccountPreferencesController, List<AccountPreferenceAccount>>((c) => c.accounts);
    final subtitle = accounts.length == 1
        ? t.accountPreferences.hubSubtitleSingle(account: accounts.single.target.label)
        : t.accountPreferences.hubSubtitleMultiple(count: accounts.length);
    return SettingNavigationTile(
      focusNode: _focusTracker.get(_kAccountPreferences),
      icon: Symbols.manage_accounts_rounded,
      title: t.accountPreferences.sectionTitle,
      subtitle: subtitle,
      destinationBuilder: (context) =>
          AccountPreferencesScreen(targets: [for (final account in accounts) account.target]),
    );
  }

  Widget _buildProfilesTile(BuildContext context) {
    // ActiveProfileProvider already merges local rows with virtual Plex
    // Home profiles — counting only the local DB rows made every Plex Home
    // household read as a single profile here. `context.select` keeps
    // rebuilds scoped to actual count/name changes (a StreamBuilder here
    // was also re-created on every settings rebuild).
    final count = context.select<ActiveProfileProvider, int>((p) => p.profiles.length);
    final activeName = context.select<ActiveProfileProvider, String?>((p) => p.active?.displayName);
    final subtitle = count <= 1
        ? t.profiles.summarySingle
        : (activeName != null
              ? t.profiles.summaryMultipleWithActive(count: count, activeName: activeName)
              : t.profiles.summaryMultiple(count: count));
    return SettingNavigationTile(
      icon: Symbols.group_rounded,
      title: t.profiles.sectionTitle,
      subtitle: subtitle,
      onTap: () => Navigator.of(
        context,
        rootNavigator: true,
      ).push(MaterialPageRoute(builder: (_) => const ProfileSwitchScreen())),
    );
  }

  Widget _buildDownloadsSection() {
    final storageService = DownloadStorageService.instance;
    final isCustom = storageService.isUsingCustomPath();

    return SettingsGroup(
      title: t.settings.downloads,
      children: [
        if (!Platform.isIOS)
          FutureBuilder<String>(
            future: storageService.getCurrentDownloadPathDisplay(),
            builder: (context, snapshot) {
              final currentPath = snapshot.data ?? '...';
              return FocusableListTile(
                focusNode: _focusTracker.get(_kDownloadLocation),
                leading: const AppIcon(Symbols.folder_rounded, fill: 1),
                title: Text(isCustom ? t.settings.downloadLocationCustom : t.settings.downloadLocationDefault),
                subtitle: Text(currentPath, maxLines: 2, overflow: .ellipsis),
                trailing: const AppIcon(Symbols.chevron_right_rounded, fill: 1),
                onTap: () => _showDownloadLocationDialog(),
              );
            },
          ),
        SettingSwitchTile(
          focusNode: _focusTracker.get(_kDownloadOnWifiOnly),
          pref: settings.SettingsService.downloadOnWifiOnly,
          icon: Symbols.wifi_rounded,
          title: t.settings.downloadOnWifiOnly,
          subtitle: t.settings.downloadOnWifiOnlyDescription,
        ),
        SettingSwitchTile(
          focusNode: _focusTracker.get(_kAutoRemoveWatchedDownloads),
          pref: settings.SettingsService.autoRemoveWatchedDownloads,
          icon: Symbols.delete_sweep_rounded,
          title: t.settings.autoRemoveWatchedDownloads,
          subtitle: t.settings.autoRemoveWatchedDownloadsDescription,
        ),
        if (_backgroundWorkDiagnostics.isSupported) _buildBackgroundDownloadsTile(),
        // TODO: "Remove orphaned downloads" toggle (#1413) goes here, next to
        // autoRemoveWatchedDownloads.
      ],
    );
  }

  /// Standing answer to "why do my downloads stop when I leave the app" — also
  /// what support can ask a user to read out without needing a log upload.
  Widget _buildBackgroundDownloadsTile() {
    final diagnostics = _backgroundWorkDiagnostics;
    return ListenableBuilder(
      listenable: diagnostics,
      builder: (context, _) {
        final status = diagnostics.status;
        final scheme = Theme.of(context).colorScheme;
        final (icon, color, summary) = switch (status) {
          _ when !status.probed => (Symbols.help_rounded, null, t.downloads.backgroundWarning.statusUnknown),
          _ when status.isBlocked => (
            Symbols.battery_alert_rounded,
            scheme.error,
            t.downloads.backgroundWarning.statusBlocked,
          ),
          _ when !status.isHealthy => (
            Symbols.info_rounded,
            scheme.tertiary,
            t.downloads.backgroundWarning.statusDegraded,
          ),
          _ => (Symbols.check_circle_rounded, null, t.downloads.backgroundWarning.statusOk),
        };
        return FocusableListTile(
          focusNode: _focusTracker.get(_kBackgroundDownloads),
          leading: AppIcon(icon, fill: 1, color: color),
          title: Text(t.downloads.backgroundWarning.statusTile),
          subtitle: Text(summary),
          trailing: const AppIcon(Symbols.chevron_right_rounded, fill: 1),
          onTap: () async {
            await diagnostics.refresh();
            if (!context.mounted) return;
            if (diagnostics.status.isHealthy) {
              showAppSnackBar(context, t.downloads.backgroundWarning.statusOk);
              return;
            }
            await showBackgroundDownloadWarningDialog(context, service: diagnostics);
          },
        );
      },
    );
  }

  /// Input devices: keyboard shortcuts on platforms with a physical keyboard,
  /// and the companion-remote host on surfaces that can be controlled from a
  /// phone. Either half may be absent; the caller skips the section when both
  /// are.
  Widget _buildControlsSection(BuildContext context) {
    final children = <Widget>[
      if (_keyboardService != null) ...[
        SettingNavigationTile(
          focusNode: _focusTracker.get(_kVideoPlayerControls),
          icon: Symbols.keyboard_rounded,
          title: t.settings.videoPlayerControls,
          subtitle: t.settings.keyboardShortcutsDescription,
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => KeyboardShortcutsScreen(keyboardService: _keyboardService!)),
            );
          },
        ),
        SettingSwitchTile(
          focusNode: _focusTracker.get(_kVideoPlayerNavigation),
          pref: settings.SettingsService.videoPlayerNavigationEnabled,
          icon: Symbols.gamepad_rounded,
          title: t.settings.videoPlayerNavigation,
          subtitle: t.settings.videoPlayerNavigationDescription,
        ),
      ],
      if (PlatformDetector.shouldActAsRemoteHost(context))
        SettingSwitchTile(
          focusNode: _focusTracker.get(_kCompanionRemoteServer),
          pref: settings.SettingsService.enableCompanionRemoteServer,
          icon: Symbols.phone_android_rounded,
          title: t.settings.companionRemoteServer,
          subtitle: t.settings.companionRemoteServerDescription,
        ),
    ];
    // Keyboard platforms render nothing until the shortcuts service loads; an
    // empty SettingsGroup would paint a bare section title.
    if (children.isEmpty) return const SizedBox.shrink();
    return SettingsGroup(title: t.settings.controls, children: children);
  }

  /// Subtitle for the Super Spoof User-Agent row: the name the mimic
  /// sends, or the Off line when the piece leaves the normal choice
  /// alone.
  String _superSpoofUserAgentSubtitle(String choice) {
    if (choice == XtreamSuperSpoof.userAgentOff) return t.settings.superSpoofUserAgentOff;
    return XtreamSuperSpoof.userAgentForChoice(choice) ?? t.settings.superSpoofUserAgentOff;
  }

  Widget _buildAdvancedSection() {
    return SettingsGroup(
      title: t.settings.advanced,
      children: [
        SettingNavigationTile(
          focusNode: _focusTracker.get(_kWatchTogetherRelay),
          icon: Symbols.dns_rounded,
          title: t.settings.watchTogetherRelay,
          subtitle: t.settings.watchTogetherRelayDescription,
          onTap: () => _showRelayUrlDialog(),
        ),
        SettingSwitchTile(
          focusNode: _focusTracker.get(_kAutoHidePerformanceOverlay),
          pref: settings.SettingsService.autoHidePerformanceOverlay,
          icon: Symbols.speed_rounded,
          title: t.settings.autoHidePerformanceOverlay,
          subtitle: t.settings.autoHidePerformanceOverlayDescription,
        ),
        // 1.6.11 (Super Spoof): one master toggle that turns on ALL the
        // request-spoofing pieces at once, with the per-piece
        // sub-settings underneath it while it is on. The subs tune which
        // pieces are active and how they behave; the master still turns
        // the whole thing on/off at once.
        SettingSwitchTile(
          focusNode: _focusTracker.get(_kSuperSpoof),
          pref: settings.SettingsService.iptvSuperSpoof,
          icon: Symbols.theater_comedy_rounded,
          title: t.settings.superSpoof,
          subtitle: t.settings.superSpoofDescription,
        ),
        ValueListenableBuilder<bool>(
          valueListenable: settings.SettingsService.instance.listenable(
            settings.SettingsService.iptvSuperSpoof,
          ),
          builder: (_, spoofOn, _) {
            if (!spoofOn) return const SizedBox.shrink();
            return Column(
              children: [
                SettingSelectionTile<String>(
                  pref: settings.SettingsService.iptvSuperSpoofUserAgent,
                  icon: Symbols.badge_rounded,
                  title: t.settings.superSpoofUserAgent,
                  subtitleBuilder: _superSpoofUserAgentSubtitle,
                  options: [
                    DialogOption(
                      value: XtreamSuperSpoof.userAgentOff,
                      title: t.settings.superSpoofUserAgentOff,
                    ),
                    DialogOption(
                      value: XtreamUserAgent.choiceVlc,
                      title: t.iptv.xtreamUserAgentVlc,
                    ),
                    DialogOption(
                      value: XtreamUserAgent.choiceSmarters,
                      title: t.iptv.xtreamUserAgentSmarters,
                    ),
                    DialogOption(
                      value: XtreamUserAgent.choiceBrowser,
                      title: t.iptv.xtreamUserAgentBrowser,
                    ),
                  ],
                ),
                SettingSwitchTile(
                  pref: settings.SettingsService.iptvSuperSpoofHeaders,
                  icon: Symbols.article_rounded,
                  title: t.settings.superSpoofHeaders,
                  subtitle: t.settings.superSpoofHeadersDescription,
                ),
                SettingSwitchTile(
                  pref: settings.SettingsService.iptvSuperSpoofStreams,
                  icon: Symbols.play_circle_rounded,
                  title: t.settings.superSpoofStreams,
                  subtitle: t.settings.superSpoofStreamsDescription,
                ),
              ],
            );
          },
        ),
        SettingNavigationTile(
          focusNode: _focusTracker.get(_kViewLogs),
          icon: Symbols.article_rounded,
          title: t.settings.viewLogs,
          subtitle: t.settings.viewLogsDescription,
          destinationBuilder: (context) => const LogsScreen(),
        ),
        LastCrashRow(focusNode: _focusTracker.get(_kLastCrash)),
        // L-20: renders only while free space is below 500 MB.
        const StorageHealthRow(),
        SettingNavigationTile(
          focusNode: _focusTracker.get(_kClearImageCache),
          icon: Symbols.cleaning_services_rounded,
          title: t.settings.clearImageCache,
          subtitle: t.settings.clearImageCacheDescription,
          onTap: () => _showClearImageCacheDialog(),
        ),
        SettingNavigationTile(
          focusNode: _focusTracker.get(_kResetSettings),
          icon: Symbols.restore_rounded,
          title: t.settings.resetSettings,
          subtitle: t.settings.resetSettingsDescription,
          onTap: () => _showResetSettingsDialog(),
        ),
        if (kDebugMode)
          SettingNavigationTile(
            icon: Symbols.timer_rounded,
            title: 'Test ANR',
            subtitle: 'Block the main thread for 10 seconds',
            onTap: () {
              showSnackBar(context, 'Blocking main thread...');
              final end = DateTime.now().add(const Duration(seconds: 10));
              while (DateTime.now().isBefore(end)) {}
            },
          ),
      ],
    );
  }

  Widget _buildBackupSection() {
    return SettingsGroup(
      title: t.settings.backup,
      children: [
        SettingNavigationTile(
          focusNode: _focusTracker.get(_kExportSettings),
          icon: Symbols.upload_rounded,
          title: t.settings.exportSettings,
          subtitle: t.settings.exportSettingsDescription,
          onTap: _handleExportSettings,
        ),
        SettingNavigationTile(
          focusNode: _focusTracker.get(_kImportSettings),
          icon: Symbols.download_rounded,
          title: t.settings.importSettings,
          subtitle: t.settings.importSettingsDescription,
          onTap: _showImportSettingsDialog,
        ),
        // 1.2.22 §65: full backup — everything the fork stores, not just
        // the portable settings above. The export warns first (the file
        // contains the logins); the restore verifies and reports counts.
        SettingNavigationTile(
          focusNode: _focusTracker.get(_kExportForkBackup),
          icon: Symbols.save_rounded,
          title: t.settings.exportForkBackup,
          subtitle: t.settings.exportForkBackupDescription,
          onTap: _showExportForkBackupDialog,
        ),
        SettingNavigationTile(
          focusNode: _focusTracker.get(_kImportForkBackup),
          icon: Symbols.restore_rounded,
          title: t.settings.importForkBackup,
          subtitle: t.settings.importForkBackupDescription,
          onTap: _showImportForkBackupDialog,
        ),
        // TODO: Cloud settings sync/backup (#1795, #1979) goes here once a
        // sync backend exists (iCloud on Apple platforms, or the relay).
      ],
    );
  }

  Widget _buildAutoCheckUpdatesOnStartupTile() => SettingSwitchTile(
    focusNode: _focusTracker.get(_kAutoCheckUpdatesOnStartup),
    pref: settings.SettingsService.autoCheckUpdatesOnStartup,
    icon: Symbols.notifications_active_rounded,
    title: t.settings.autoCheckUpdatesOnStartup,
    subtitle: t.settings.autoCheckUpdatesOnStartupDescription,
  );

  Widget _buildUpdateSection() {
    // 1.2.22 §66 (U5): the native updater is cut (its appcast was never
    // used — useNativeUpdater was hard-coded false), so only the GitHub
    // flow below remains.
    final hasUpdate = _updateInfo != null && _updateInfo!['hasUpdate'] == true;

    return SettingsGroup(
      title: t.settings.updates,
      children: [
        FocusableListTile(
          focusNode: _focusTracker.get(_kCheckForUpdates),
          leading: AppIcon(
            hasUpdate ? Symbols.system_update_rounded : Symbols.check_circle_rounded,
            fill: 1,
            color: hasUpdate ? Colors.orange : null,
          ),
          title: Text(hasUpdate ? t.settings.updateAvailable : t.settings.checkForUpdates),
          subtitle: hasUpdate ? Text(t.update.versionAvailable(version: _updateInfo!['latestVersion'])) : null,
          trailing: _isCheckingForUpdate
              ? const LoadingIndicatorBox(size: 24)
              : const AppIcon(Symbols.chevron_right_rounded, fill: 1),
          onTap: _isCheckingForUpdate
              ? null
              : () {
                  if (hasUpdate) {
                    _showUpdateDialog();
                  } else {
                    _checkForUpdates();
                  }
                },
        ),
        _buildAutoCheckUpdatesOnStartupTile(),
        _buildViewReleasesTile(),
      ],
    );
  }

  /// Link to the fork's GitHub Releases page, in the same Updates group as
  /// the check row — the releases are where every PlenTV APK is published
  /// for free, and where the in-app updater downloads from.
  Widget _buildViewReleasesTile() {
    return SettingNavigationTile(
      focusNode: _focusTracker.get(_kViewReleasesOnGitHub),
      icon: Symbols.open_in_new_rounded,
      title: t.settings.viewReleasesOnGitHub,
      subtitle: UpdateService.releasesUrl,
      trailingIcon: Symbols.open_in_new_rounded,
      onTap: () async {
        final url = Uri.parse(UpdateService.releasesUrl);
        if (await canLaunchUrl(url)) {
          await launchUrl(url, mode: LaunchMode.externalApplication);
        }
      },
    );
  }

  Future<void> _showDownloadLocationDialog() async {
    final storageService = DownloadStorageService.instance;
    final isCustom = storageService.isUsingCustomPath();

    await showScopedDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.settings.downloads),
        content: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .start,
          children: [
            Text(t.settings.downloadLocationDescription),
            const SizedBox(height: 16),
            FutureBuilder<String>(
              future: storageService.getCurrentDownloadPathDisplay(),
              builder: (context, snapshot) {
                return Text(
                  t.settings.currentPath(path: snapshot.data ?? '...'),
                  style: Theme.of(context).textTheme.bodySmall,
                );
              },
            ),
          ],
        ),
        actions: [
          if (isCustom)
            DialogActionButton(
              onPressed: () async {
                // Run the async work first, then pop — popping first leaves
                // setState inside _resetDownloadLocation racing against the
                // already-dismissed dialog (and any re-opened instance).
                await _resetDownloadLocation();
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              label: t.settings.resetToDefault,
            ),
          DialogActionButton(onPressed: () => Navigator.pop(dialogContext), label: t.common.cancel),
          DialogActionButton(
            onPressed: () async {
              final changed = await _selectDownloadLocation();
              if (changed && dialogContext.mounted) Navigator.pop(dialogContext);
            },
            label: t.settings.selectFolder,
            isPrimary: true,
          ),
        ],
      ),
    );
  }

  Future<bool> _selectDownloadLocation() async {
    final changed = await guardSettingsOperation<bool, DownloadStorageException>(
      context,
      operation: 'Download directory selection',
      body: () async {
        String? selectedPath;
        String pathType = 'file';

        if (Platform.isAndroid) {
          final safStorage = SafStorageService.instance;
          if (!safStorage.supportsDirectoryPicker) {
            showErrorSnackBar(context, t.settings.downloadLocationPickerUnavailable);
            return false;
          }
          selectedPath = await safStorage.pickDirectory();
          if (!mounted) return false;
          if (selectedPath != null) pathType = 'saf';
        } else {
          selectedPath = await FilePickerService.instance.getDirectoryPath(dialogTitle: t.settings.selectFolder);
          if (!mounted) return false;
        }
        if (selectedPath == null) return false;

        final writableChecker = widget.downloadDirectoryWritableChecker;
        if (pathType == 'file' && writableChecker != null) {
          final isWritable = await writableChecker(Directory(selectedPath));
          if (!mounted) return false;
          if (!isWritable) {
            showErrorSnackBar(context, t.settings.downloadLocationInvalid);
            return false;
          }
        }

        await context.read<DownloadProvider>().setDownloadLocation(path: selectedPath, pathType: pathType);
        if (!mounted) return false;

        // ignore: no-empty-block - setState triggers rebuild to reflect new download path
        setState(() {});
        showSuccessSnackBar(context, t.settings.downloadLocationChanged);
        return true;
      },
    );
    return changed ?? false;
  }

  Future<void> _resetDownloadLocation() async {
    await context.read<DownloadProvider>().resetDownloadLocation();

    if (mounted) {
      // ignore: no-empty-block - setState triggers rebuild to reflect reset path
      setState(() {});
      showAppSnackBar(context, t.settings.downloadLocationReset);
    }
  }

  Future<void> _showRelayUrlDialog() async {
    await showScopedDialog<void>(
      context: context,
      builder: (_) => _RelayUrlDialog(settingsService: _settingsService),
    );
  }

  Future<void> _showClearImageCacheDialog() async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.settings.clearImageCache,
      message: t.settings.clearImageCacheDescription,
      confirmText: t.common.clear,
    );
    if (!confirmed) return;
    await _settingsService.clearImageCache();
    if (mounted) showSuccessSnackBar(context, t.settings.clearImageCacheSuccess);
  }

  Future<void> _showResetSettingsDialog() async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.settings.resetSettings,
      message: t.settings.resetSettingsDescription,
      confirmText: t.common.reset,
      isDestructive: true,
    );
    if (!mounted || !confirmed) return;
    final previousRootConfiguration = SettingsMutationService.captureRootConfiguration();
    await context.read<DownloadProvider>().resetDownloadLocation();
    await _settingsService.resetAllSettings();
    if (!mounted) return;
    final failures = await const SettingsMutationService().applyStoredEffects(
      context,
      previousRootConfiguration: previousRootConfiguration,
    );
    if (!mounted) return;
    // Every pref is reset either way; only some runtime effect declined, so the
    // reset itself is not a failure — name what did not take.
    if (failures.isEmpty) {
      showSuccessSnackBar(context, t.settings.resetSettingsSuccess);
    } else {
      showErrorSnackBar(context, failures.first.display);
    }
  }

  Future<void> _handleExportSettings() async {
    await guardSettingsOperation<void, SettingsExportException>(
      context,
      operation: 'Settings export',
      body: () async {
        final path = await (widget.settingsExporter ?? SettingsExportService.exportToFile)();
        if (!mounted || path == null) return;
        showSuccessSnackBar(context, t.settings.exportSettingsSuccess);
      },
    );
  }

  Future<void> _showImportSettingsDialog() async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.settings.importSettings,
      message: t.settings.importSettingsConfirm,
      confirmText: t.settings.importSettings,
    );
    if (!mounted || !confirmed) return;
    await _handleImportSettings();
  }

  Future<void> _handleImportSettings() async {
    await guardSettingsOperation<void, SettingsExportException>(
      context,
      operation: 'Settings import',
      body: () async {
        // The two typed import failures carry their own message, so they are
        // handled here instead of falling through to the generic guard.
        try {
          final previousRootConfiguration = SettingsMutationService.captureRootConfiguration();
          final result = await (widget.settingsImporter ?? SettingsExportService.importFromFile)();
          if (!mounted) return;
          if (result == null) return; // user cancelled file picker

          final hiddenLibrariesProvider = context.read<HiddenLibrariesProvider>();
          final librariesProvider = context.read<LibrariesProvider>();

          // Import wrote directly to SharedPreferences, bypassing `write`. Push
          // fresh values into active listenables before providers re-read settings.
          _settingsService.refreshListenables();
          await hiddenLibrariesProvider.refresh();
          unawaited(librariesProvider.refresh());
          if (!mounted) return;
          final failures = await const SettingsMutationService().applyStoredEffects(
            context,
            previousRootConfiguration: previousRootConfiguration,
          );

          if (!mounted) return;
          if (failures.isEmpty) {
            showSuccessSnackBar(context, t.settings.importSettingsSuccess);
          } else {
            showErrorSnackBar(context, failures.first.display);
          }
        } on NoUserSignedInException {
          if (mounted) showErrorSnackBar(context, t.settings.importSettingsNoUser);
        } on InvalidExportFileException {
          if (mounted) showErrorSnackBar(context, t.settings.importSettingsInvalidFile);
        }
      },
    );
  }

  /// 1.2.22 §65: the export file contains the logins, so the warning
  /// comes FIRST — the export only runs after the user confirms they
  /// understand the file must stay private.
  Future<void> _showExportForkBackupDialog() async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.settings.exportForkBackupWarningTitle,
      message: t.settings.exportForkBackupWarning,
      confirmText: t.settings.exportForkBackup,
    );
    if (!mounted || !confirmed) return;
    await _handleExportForkBackup();
  }

  Future<void> _handleExportForkBackup() async {
    await guardSettingsOperation<void, ForkBackupException>(
      context,
      operation: 'Fork backup export',
      body: () async {
        final path = await (widget.forkBackupExporter ??
            () => ForkBackupService(context.read<AppDatabase>()).exportToFile())();
        if (!mounted || path == null) return;
        showSuccessSnackBar(context, t.settings.exportForkBackupSuccess);
      },
    );
  }

  Future<void> _showImportForkBackupDialog() async {
    final confirmed = await showConfirmDialog(
      context,
      title: t.settings.importForkBackup,
      message: t.settings.importForkBackupConfirm,
      confirmText: t.settings.importForkBackup,
    );
    if (!mounted || !confirmed) return;
    await _handleImportForkBackup();
  }

  Future<void> _handleImportForkBackup() async {
    await guardSettingsOperation<void, ForkBackupException>(
      context,
      operation: 'Fork backup import',
      body: () async {
        // A malformed backup is the user's file being wrong, not a
        // settings failure — it gets its own plain-words snackbar, like
        // the settings import's typed failures above.
        try {
          final previousRootConfiguration = SettingsMutationService.captureRootConfiguration();
          final report = await (widget.forkBackupImporter ??
              () => ForkBackupService(context.read<AppDatabase>()).importFromFile())();
          if (!mounted) return;
          if (report == null) return; // user cancelled file picker

          final hiddenLibrariesProvider = context.read<HiddenLibrariesProvider>();
          final librariesProvider = context.read<LibrariesProvider>();

          // Import wrote directly to SharedPreferences and the database,
          // bypassing `write`. Push fresh values into active listenables
          // before providers re-read settings.
          _settingsService.refreshListenables();
          await hiddenLibrariesProvider.refresh();
          unawaited(librariesProvider.refresh());
          if (!mounted) return;
          final failures = await const SettingsMutationService().applyStoredEffects(
            context,
            previousRootConfiguration: previousRootConfiguration,
          );
          if (!mounted) return;
          // Rebind the restored connections so the new servers' libraries
          // appear without an app restart — only when the restore actually
          // brought connections or profiles. A bare settings restore must
          // not trigger a rebind that could pop a PIN prompt.
          if (report.connections.restored > 0 || report.profiles.restored > 0) {
            // 1.3.25 §68 (d): the restore wrote the restored active-profile
            // id to storage, but the in-memory provider never learned it —
            // a bare rebind here would target the stale profile and the
            // IPTV bind chain would never run. Re-resolve the active
            // profile first; the rebind then targets the restored profile
            // and its IPTV connection's bind chain starts the catalog
            // sync on its own. Not marked user-initiated: a restore must
            // not pop a PIN prompt.
            await context.read<ActiveProfileProvider>().reloadFromStorage();
            if (!mounted) return;
            await context.read<ActiveProfileBinder>().rebindActive();
            if (!mounted) return;
          }
          if (failures.isNotEmpty) {
            showErrorSnackBar(context, failures.first.display);
            return;
          }
          await _showForkBackupSummaryDialog(report);
        } on ForkBackupException {
          if (mounted) showErrorSnackBar(context, t.settings.importForkBackupInvalidFile);
        }
      },
    );
  }

  /// 1.2.22 §65: what the restore actually landed, in plain words —
  /// per-section counts, a line when anything was skipped, and the
  /// catalog note (the catalog was not in the backup). The button opens
  /// the IPTV settings screen, where "Sync catalog now" lives as the
  /// manual fallback; the sync itself now starts on its own via the
  /// post-restore rebind (1.3.25 §68 (d)).
  Future<void> _showForkBackupSummaryDialog(ForkBackupRestoreReport report) async {
    final lines = <String>[
      t.settings.importForkBackupSummary(
        connections: report.connections.restored,
        profiles: report.profiles.restored,
        settings: report.prefs.keysImported,
        guideSettings: report.epgPrefs.restored,
        guideStores: report.epg.restored,
        favourites: report.favorites.restored,
        resume: report.resume.restored,
      ),
      if (report.activeProfileRestored)
        t.settings.importForkBackupActiveProfile
      else
        t.settings.importForkBackupNoActiveProfile,
    ];
    final skipped =
        report.connections.skipped +
        report.profiles.skipped +
        report.profileConnections.skipped +
        report.epgPrefs.skipped +
        report.epg.skipped +
        report.favorites.skipped +
        report.resume.skipped +
        report.prefs.keysSkipped;
    if (skipped > 0) lines.add(t.settings.importForkBackupSkipped(n: skipped, count: skipped));
    lines.add(t.settings.importForkBackupCatalogNote);
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        title: Text(t.settings.importForkBackupSummaryTitle),
        content: Text(lines.join('\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(t.common.close),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              Navigator.push(context, MaterialPageRoute(builder: (context) => const IptvSettingsScreen()));
            },
            child: Text(t.settings.importForkBackupOpenIptvSettings),
          ),
        ],
      ),
    );
  }

  Future<void> _checkForUpdates() async {
    setState(() => _isCheckingForUpdate = true);

    try {
      final updateInfo = await UpdateService.checkForUpdates();

      if (mounted) {
        setState(() {
          _updateInfo = updateInfo;
          _isCheckingForUpdate = false;
        });

        if (updateInfo == null || updateInfo['hasUpdate'] != true) {
          showAppSnackBar(context, t.update.latestVersion);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isCheckingForUpdate = false);
        showErrorSnackBar(context, t.update.checkFailed);
      }
    }
  }

  void _showUpdateDialog() {
    final updateInfo = _updateInfo;
    if (updateInfo == null) return;
    unawaited(
      showUpdateAvailableDialog(context, updateInfo, title: t.settings.updateAvailable, dismissLabel: t.common.close),
    );
  }
}

class _RelayUrlDialog extends StatefulWidget {
  final settings.SettingsService settingsService;

  const _RelayUrlDialog({required this.settingsService});

  @override
  State<_RelayUrlDialog> createState() => _RelayUrlDialogState();
}

class _RelayUrlDialogState extends State<_RelayUrlDialog> {
  late final TextEditingController _controller;
  final _saveFocusNode = FocusNode(debugLabel: 'WatchTogetherRelaySave');
  bool _relayUrlInvalid = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.settingsService.read(settings.SettingsService.watchPartyRelayUrl) ?? '',
    );
  }

  @override
  void dispose() {
    _saveFocusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _reset() async {
    _controller.clear();
    await widget.settingsService.write(settings.SettingsService.watchPartyRelayUrl, null);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _save() async {
    final value = _controller.text;
    if (value.trim().isEmpty) {
      await widget.settingsService.write(settings.SettingsService.watchPartyRelayUrl, null);
      if (mounted) Navigator.pop(context);
      return;
    }

    final base = canonicalRelayBaseUrl(value);
    if (base == null) {
      setState(() => _relayUrlInvalid = true);
      return;
    }
    await widget.settingsService.write(settings.SettingsService.watchPartyRelayUrl, base);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.settings.watchTogetherRelay),
      content: FocusableTextField(
        controller: _controller,
        decoration: InputDecoration(
          labelText: t.common.url,
          hintText: t.settings.watchTogetherRelayHint,
          errorText: _relayUrlInvalid ? t.settings.watchTogetherRelayInvalid : null,
        ),
        autofocus: true,
        textInputAction: TextInputAction.done,
        onChanged: (_) {
          if (_relayUrlInvalid) {
            setState(() => _relayUrlInvalid = false);
          }
        },
        onEditingComplete: () => _saveFocusNode.requestFocus(),
        onNavigateDown: _saveFocusNode.requestFocus,
      ),
      actions: [
        DialogActionButton(onPressed: _reset, label: t.settings.resetToDefault),
        DialogActionButton(onPressed: () => Navigator.pop(context), label: t.common.cancel),
        DialogActionButton(focusNode: _saveFocusNode, onPressed: _save, label: t.common.save),
      ],
    );
  }
}
