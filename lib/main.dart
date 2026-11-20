import 'dart:async';
import 'dart:io' show Directory, Platform, ProcessInfo;
import 'dart:ui' show AppExitResponse;
import 'package:flutter/foundation.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_foundation/shared_preferences_foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/material.dart' as material show ThemeMode;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:provider/provider.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'connection/connection.dart';
import 'connection/connection_bootstrap.dart';
import 'connection/connection_registry.dart';
import 'navigation/profile_navigation_scope.dart';
import 'navigation/profile_session_screen.dart';
import 'profiles/active_profile_binder.dart';
import 'profiles/active_profile_provider.dart';
import 'profiles/profile.dart';
import 'profiles/profile_connection_cleanup.dart';
import 'profiles/profile_connection_registry.dart';
import 'profiles/profile_registry.dart';
import 'profiles/profile_activation.dart';
import 'profiles/profile_selection_policy.dart';
import 'models/external_player_models.dart';
import 'mixins/mounted_set_state_mixin.dart';
import 'theme/mono_theme.dart';
import 'profiles/plex_home_service.dart';
import 'screens/auth_screen.dart';
import 'screens/auto_dump_safe_mode_screen.dart';
import 'screens/profile/pin_entry_dialog.dart';
import 'screens/profile/profile_switch_screen.dart';
import 'services/storage_service.dart';
import 'services/assistive_technology_service.dart';
import 'services/device_performance.dart';
import 'services/iptv/iptv_heavy_work_gate.dart';
import 'services/lowend/benchmark_mode.dart';
import 'services/lowend/frame_time_collector.dart';
import 'services/lowend/phase_rss_sampler.dart';
import 'services/lowend/relief_log.dart';
import 'services/lowend/slow_op_log.dart';
import 'utils/memory_pressure_breadcrumbs.dart';
import 'utils/native_trim_memory.dart';
import 'utils/device_channel.dart';
import 'services/video_decode_capabilities.dart';
import 'services/macos_window_service.dart';
import 'services/native_window_service.dart';
import 'services/fullscreen_state_manager.dart';
import 'services/settings_service.dart';
import 'services/agent_control_service.dart';
import 'services/android_display_mode_service.dart';
import 'widgets/agent_control_scope.dart';
import 'widgets/settings_builder.dart';
import 'utils/iphone_duo.dart';
import 'utils/platform_detector.dart';
import 'utils/app_scroll_behavior.dart';
import 'utils/pointer_scroll_axis.dart';
import 'services/apple_tv_remote_touch_service.dart';
import 'services/discord_rpc_service.dart';
import 'package:path_provider/path_provider.dart';
import 'services/image_cache_service.dart';
import 'services/storage_health.dart';
import 'services/app_icon/app_icon_service.dart';
import 'services/gamepad_service.dart';
import 'services/trackers/tracker_account_store.dart';
import 'services/trackers/tracker_coordinator.dart';
import 'services/playback_coordinator.dart';
import 'services/deep_links/deep_link_service.dart';
import 'providers/account_preferences_controller.dart';
import 'services/account_preferences_repository.dart';
import 'providers/multi_server_provider.dart';
import 'providers/theme_provider.dart';
import 'services/supporter/supporter_service.dart';
import 'providers/download_provider.dart';
import 'providers/offline_mode_provider.dart';
import 'providers/offline_watch_provider.dart';
import 'providers/shader_provider.dart';
import 'utils/snackbar_helper.dart';
import 'services/iptv/iptv_background_sync.dart';
import 'media/iptv_client.dart';
import 'services/multi_server_manager.dart';
import 'services/library_events/library_event_service.dart';
import 'services/offline_watch_sync_service.dart';
import 'services/data_aggregation_service.dart';
import 'services/credential_vault.dart';
import 'services/auto_dump_service.dart';
import 'services/last_crash_store.dart';
import 'services/main_thread_watchdog.dart';
import 'services/server_registry.dart';
import 'services/download_manager_service.dart';
import 'services/pip_service.dart';
import 'services/download_storage_service.dart';
import 'services/connectivity_probe.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'services/jellyfin_api_cache.dart';
import 'services/plex_api_cache.dart';
import 'database/app_database.dart';
import 'database/download_operations.dart';
import 'database/tvos_database_recovery_store.dart';
import 'screens/video_player_screen.dart';
import 'utils/app_logger.dart';
import 'utils/certificate_trust.dart';
import 'utils/managed_http_client.dart';
import 'utils/media_server_http_client.dart';
import 'utils/media_server_timeouts.dart';
import 'utils/orientation_helper.dart';
import 'utils/watch_state_notifier.dart';
import 'i18n/app_locale_utils.dart';
import 'i18n/strings.g.dart';
import 'widgets/app_icon.dart';
import 'widgets/app_system_ui_style.dart';
import 'focus/input_mode_tracker.dart';
import 'focus/key_event_utils.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'utils/navigation_transitions.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'utils/android_exit_diagnostics.dart';
import 'utils/startup_phase_timings.dart';
import 'utils/storage_failure.dart';
import 'services/base_shared_preferences_service.dart';
import 'services/prefs_recovery.dart';
import 'services/sensitive_prefs.dart';
import 'services/startup_diagnostics.dart';
import 'utils/dialogs.dart';
import 'widgets/dialog_action_button.dart';
import 'widgets/startup_failure_view.dart';

const String gitCommit = String.fromEnvironment('GIT_COMMIT');

// Workaround for Flutter bug #177992: iPadOS 26.1+ misinterprets fake touch events
// at (0,0) as barrier taps, causing modals to dismiss immediately.
// Remove when Flutter PR #179643 is merged.
bool _zeroOffsetPointerGuardInstalled = false;

void _installZeroOffsetPointerGuard() {
  if (_zeroOffsetPointerGuardInstalled || !Platform.isIOS) return;
  GestureBinding.instance.pointerRouter.addGlobalRoute(_absorbZeroOffsetPointerEvent);
  _zeroOffsetPointerGuardInstalled = true;
}

void _absorbZeroOffsetPointerEvent(PointerEvent event) {
  if (event is PointerDownEvent && event.position == Offset.zero) {
    GestureBinding.instance.cancelPointer(event.pointer);
  }
}

/// Register platform plugin stores manually for tvOS. Flutter's tool
/// doesn't support tvOS so it never generates a plugin registrant for it.
/// Each plugin whose iOS Swift implementation is tvOS-compatible must be
/// wired here; the Swift side (GeneratedPluginRegistrant.m / AppDelegate)
/// also needs to call the plugin's Swift register(with:) to attach its
/// message channels.
void _registerTvosPlatformPlugins() {
  if (!Platform.isIOS) return; // tvOS reports as iOS via dart:io.
  SharedPreferencesFoundation.registerWith();
  // in_app_purchase needs no entry here: `InAppPurchase.instance` registers
  // its StoreKit platform on first use (tvOS reports iOS), which
  // SupporterService reaches only in SUPPORTER_MODE=iap builds.
}

void main() {
  final binding = PlezyWidgetsBinding.ensureInitialized();
  if (agentControlEnabled) AgentControlService.instance.register();
  AndroidExitDiagnostics.markStartupPhase(AndroidStartupPhase.dartMain);
  // Keep the accessibility tree available to Maestro and other UI automation
  // without adding release-build overhead.
  if (kDebugMode) binding.ensureSemantics();
  // Android: skip the per-frame semantics pass when the only bound
  // accessibility service cannot read it (launcher hooks, key remappers).
  AssistiveTechnologyService.instance.ensureStarted();
  _installZeroOffsetPointerGuard(); // Workaround for iPadOS 26.1+ modal dismissal bug

  // On tvOS, Flutter's generated plugin registrant doesn't run (no tvOS
  // target in Flutter's tool), so register platform stores manually for
  // the plugins we use.
  _registerTvosPlatformPlugins();
  _registerAppLicenses();
  unawaited(_bootstrapApp());
}

/// Marks a clean exit so the next launch can tell a crash from a normal
/// close (build #14, D-6): `detached` fires when the engine is destroyed
/// on a normal close; a crash or a force-stop never gets here, so the
/// exit-state file still says 'running' on the next launch.
class _AppExitObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) LastCrashStore.markCleanExit();
  }
}

Future<void> _bootstrapApp() async {
  // In release mode, show a colored placeholder instead of a blank/white screen
  // when a widget build() throws an unhandled exception.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    if (kDebugMode) return ErrorWidget(details.exception);
    return const ColoredBox(color: Color(0xFF000000));
  };

  // Fatal-error catcher (build #14): persists the last fatal Dart error +
  // stack to disk so Settings can show it on the next launch — the v2.25.9
  // startup crash was never reproduced in the harness, so the crash itself,
  // from the phone, is the evidence. Installed before runApp, and chains to
  // whatever handler was there before. The support directory is resolved
  // ahead of any crash so the record writes synchronously when the process
  // is dying.
  LastCrashCatcher.install();
  unawaited(LastCrashStore.prime());
  // Always-on file logging (1.2.9): the rolling file is primed alongside
  // the crash store so the log survives a kill from the first launch.
  unawaited(FileLogOutput.prime());

  // Auto-dump bookkeeping (1.2.9) and the emergency saver (1.2.13):
  // mark this launch, update the cumulative abnormal-exit counter
  // from the previous launch's exit state, and — when 3 abnormal
  // exits have happened (1.2.16, TEMPORARY: ANY crash counts,
  // not just startup crashes; cumulative — any 3 crashes, ever) — stop
  // here and show the emergency
  // debug log saver instead of silently dumping and starting normally.
  // Safe mode runs no catalog bind, no Trex load, no background sync and
  // no splash-to-main, so it cannot crash the same way. The counter read
  // is two platform-channel round trips — negligible against a startup
  // that is about to load the whole catalog — so it is awaited: the
  // branch must not race the normal startup. Best-effort: diagnostics
  // must never break startup.
  //
  // 1.2.22 §63.6: the native previous-exit report is one-shot — read it
  // BEFORE the saver decision and hold it, or a saver launch never logs
  // it (the saver returns before normal startup runs logPreviousExit)
  // and the dump's "Previous exit" line goes stale (it showed the exit
  // before last). The watchdog ring is read here for the same reason:
  // the watchdog only starts in normal startup, so a saver launch must
  // read the previous run's ring before anything overwrites it. The
  // native reason is also recorded alongside the failed-start count.
  final previousExitReport = await AndroidExitDiagnostics.readPreviousExitReport();
  AndroidExitDiagnostics.holdPreviousExitReport(previousExitReport);
  final watchdogRing = await MainThreadWatchdog.readRingSnapshot();
  final previousExitReason = previousExitReport?['reason'];
  final failedStarts = await _recordLaunchAndCountFailedStarts(
    previousExitReason: previousExitReason is String ? previousExitReason : null,
  );
  if (shouldEnterAutoDumpSafeMode(failedStarts)) {
    _runAutoDumpSafeMode(
      failedStarts,
      previousExitReport: previousExitReport,
      watchdogRing: watchdogRing,
    );
    return;
  }
  _runNormalStartup();
}

/// The normal startup: install the clean-exit observer, prime the
/// version label, and run the bootstrap (splash → bind → main screen).
/// Reached when the failed-start counter is below the threshold, or when
/// the emergency saver hands control back ("Continue startup" /
/// "Restart PlezTV").
void _runNormalStartup() {
  // 1.2.22 §63.6: the main-thread watchdog beats only on a normal
  // startup — never on a saver launch, so the previous run's ring
  // survives for the dump to read.
  MainThreadWatchdog.instance.start();
  WidgetsBinding.instance.addObserver(_AppExitObserver());

  // Off the critical path: the version label only decorates a diagnostic.
  unawaited(_primeDiagnosticsVersion());

  AndroidExitDiagnostics.markStartupPhase(AndroidStartupPhase.runApp);
  runApp(
    StartupBootstrap<_StartupDependencies>(
      initialize: _initializeApplication,
      buildApp: (context, dependencies) => MainApp(
        settings: dependencies.settings,
        storage: dependencies.storage,
        appDatabase: dependencies.appDatabase,
        databaseRecoveryOutcome: dependencies.databaseRecoveryOutcome,
      ),
      discard: (dependencies) => dependencies.appDatabase.close(),
      onCommitted: (dependencies) => _startNonessentialInitialization(dependencies.settings),
      lightTheme: monoTheme(MonoPalette.light),
      darkTheme: monoTheme(MonoPalette.dark),
      resolveTheme: _resolveStartupTheme,
      // Android runs the Flutter surface in transparent mode over a window
      // whose background PlezyActivity already restored, so the loading frame
      // can leave the launch screen on display. Every other platform composites
      // opaquely and has nothing behind Flutter worth showing.
      transparentWhileLoading: Platform.isAndroid,
    ),
  );
}

/// Startup bookkeeping for the auto-dump (1.2.9, saver routing 1.2.13).
///
/// Abnormal-exit flag (build #14, D-6): [LastCrashStore.markLaunched]
/// marks this launch 'running' now; a clean engine detach (see
/// [_AppExitObserver]) marks it 'clean'. A crash, a force-stop, or the OS
/// killing the process never reaches the detach, so the next launch finds
/// 'running' and the Settings "Last crash" row can say the app did not
/// shut down cleanly even when no Dart error was recorded — the signature
/// of a native (mpv) crash. The failed-start counter reads that same
/// state: TEMPORARY (1.2.16) any abnormal exit increments it, and a clean
/// exit leaves it untouched (cumulative — any 3 crashes, ever; only the
/// saver flow resets it) — the good-start marker no longer resets it (the
/// TV crashed in the Discover hub load after the bind settled, so every
/// crash looked like a good start). Returns the counter (0 on any
/// bookkeeping failure). Unlike 1.2.9 this no longer writes the dump at
/// the threshold — the emergency saver owns the dump now, and only after
/// the user asks for it. Best-effort: diagnostics must never break
/// startup.
///
/// 1.2.19, L-12: one batched call — exit state + counter in ONE file,
/// ONE write, no fsync (was two `flush: true` fsyncs before the first
/// frame). 1.2.19, L-22: a force-stop during a hung bind does not
/// increment the counter (previous phase 'binding', no fatal record);
/// a genuine startup crash still does.
Future<int> _recordLaunchAndCountFailedStarts({String? previousExitReason}) async {
  try {
    return await LastCrashStore.markLaunchedAndCountFailedStarts(previousExitReason: previousExitReason);
  } catch (error, stackTrace) {
    appLogger.d('Failed-start bookkeeping failed', error: error, stackTrace: stackTrace);
    return 0;
  }
}

/// Routing predicate for the emergency debug log saver (1.2.13): at
/// [AutoDumpService.failedStartThreshold] abnormal exits (cumulative —
/// any 3 crashes, ever, not necessarily in a row) the app opens the
/// saver instead of starting normally. Testable on its
/// own — the counter and the threshold are the whole decision.
bool shouldEnterAutoDumpSafeMode(int failedStarts) => failedStarts >= AutoDumpService.failedStartThreshold;

/// Emergency debug log saver startup (1.2.13): the minimal startup that
/// runs when the failed-start counter hit the threshold. A plain
/// MaterialApp with the saver as its home — no StartupBootstrap, no
/// catalog bind, no Trex load, no background sync, no splash-to-main.
///
/// Deliberately does NOT install [_AppExitObserver]: closing the saver
/// without saving or skipping must NOT write a clean exit, so the
/// counter keeps counting and the saver shows again next launch.
/// Saving (either location) or "Continue startup" resets the counter
/// first, so a later clean exit is harmless. "Continue startup" /
/// "Restart PlezTV" re-enters [_runNormalStartup] in-process — runApp
/// twice in one process is standard Flutter.
///
/// L-21 (1.2.19): the saver also offers "Continue without IPTV" — the
/// same normal startup, but with the IPTV bind skipped for this launch
/// ([ActiveProfileBinder.skipIptvBindForSession], Plex/Jellyfin only),
/// so a bind-peak crash loop has an exit that isn't "crash again". The
/// flag is process-lifetime only, so the next launch binds IPTV again.
void _runAutoDumpSafeMode(
  int failedStarts, {
  Map<String, Object?>? previousExitReport,
  List<({DateTime at, String label})>? watchdogRing,
}) {
  AndroidExitDiagnostics.markStartupPhase(AndroidStartupPhase.runApp);
  runApp(
    TranslationProvider(
      child: Builder(
        builder: (context) => InputModeTracker(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            scrollBehavior: const AppScrollBehavior(),
            locale: TranslationProvider.of(context).locale.localizationsLocale,
            supportedLocales: supportedLocalizationsLocales,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: monoTheme(MonoPalette.light),
            darkTheme: monoTheme(MonoPalette.dark),
            themeMode: material.ThemeMode.system,
            home: EmergencyDebugLogSaverScreen(
              failedStarts: failedStarts,
              // 1.2.22 §63.6: the early-read evidence for the dump — the
              // fresh previous-exit report and the previous run's
              // watchdog ring. Without them the dump's lines go stale.
              previousExitReport: previousExitReport,
              watchdogRing: watchdogRing,
              onContinueStartup: _runNormalStartup,
              onContinueWithoutIptv: () {
                ActiveProfileBinder.skipIptvBindForSession = true;
                _runNormalStartup();
              },
              // Android TV has no document picker: the primary save button
              // writes straight to the app folder instead.
              showSavePicker: !(Platform.isAndroid && PlatformDetector.isTV()),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Resolves the theme the app will settle on, for the frames that precede it.
///
/// Also themes the native window frame, which is already on screen and would
/// otherwise keep the platform theme until [ThemeProvider] exists.
///
/// Both singletons are memoised and awaited again by the gate, so this costs
/// one preference load and one platform-channel round trip, shared. TV
/// detection has to come first: the `themeMode` default is TV-aware and
/// [TvDetectionService.isTVSync] answers false until its singleton exists,
/// which would make a fresh Android TV install resolve the light theme.
///
/// A stored Supporter perk is gated by the cached entitlement, the same rule
/// [ThemeProvider] applies, so a locked perk never flashes and an unlocked one
/// never flashes the fallback. That fallback is the same TV-aware default.
Future<StartupThemeResolution> _resolveStartupTheme() async {
  final settings = await SettingsService.getInstance();
  await TvDetectionService.getInstance(forceTv: settings.read(SettingsService.forceTvMode));
  final palette = ThemeProvider.resolveStored(settings, unlocked: SupporterService.startupUnlocked(settings)).palette;
  ThemeProvider.applyWindowChromeBrightness(
    ThemeProvider.isDarkFor(palette, WidgetsBinding.instance.platformDispatcher.platformBrightness),
  );
  return (
    themeMode: ThemeProvider.materialThemeModeFor(palette),
    lightTheme: ThemeProvider.lightThemeFor(palette),
    darkTheme: ThemeProvider.darkThemeFor(palette),
  );
}

/// Wraps [step] so a failure names the gate phase it came from.
///
/// `Future.wait` keeps only the first error and discards the rest, and the old
/// catch-all reported a bare `error.runtimeType`, so a startup failure could
/// not even be attributed to one of four concurrent steps (#1732).
Future<T> _gatePhase<T>(StartupPhase phase, Future<T> Function() step) async {
  try {
    return await step();
  } catch (error, stackTrace) {
    Error.throwWithStackTrace(StartupPhaseException(phase, error), stackTrace);
  }
}

/// How long a degradable startup step may block the launch before it is
/// abandoned. Generous next to the sub-second these normally take, but bounded:
/// `windowManager.ensureInitialized()` is a platform-channel round trip and the
/// Windows runner puts the UI on its own thread, so a stalled platform thread
/// would otherwise hold the splash forever with no error to report.
const Duration _optionalPhaseTimeout = Duration(seconds: 10);

/// Runs a startup step that the app can survive without.
///
/// Window chrome, locale selection, crash reporting and the artwork cache are
/// all degradable; before #1732 any one of them could veto the whole boot —
/// by throwing, or by never completing.
Future<void> _optionalGatePhase(
  StartupPhase phase,
  Future<void> Function() step, {
  Duration timeout = _optionalPhaseTimeout,
}) async {
  // Keep a handler on the original future. `timeout` abandons the work rather
  // than cancelling it, so a late failure would otherwise land as an unhandled
  // async error long after the gate moved on.
  final work = Future<void>.sync(step).catchError((Object error, StackTrace stackTrace) {
    appLogger.w('Optional startup phase "${phase.id}" failed', error: error, stackTrace: stackTrace);
  });
  try {
    await work.timeout(timeout);
  } on TimeoutException {
    appLogger.w('Optional startup phase "${phase.id}" did not finish in ${timeout.inSeconds}s; continuing without it');
  }
}

Future<_StartupDependencies> _initializeApplication() async {
  final settings = await _gatePhase(StartupPhase.preferences, SettingsService.getInstance);
  // 1.2.19, L-56: seed the scripted-benchmark override from the
  // persisted Settings → Logs toggle (the toggle itself writes through
  // onAfterWrite; this covers cold start before the Logs screen is
  // ever opened).
  BenchmarkMode.isEnabledOverride = settings.read(SettingsService.benchmarkMode);
  // 1.2.9: the debug-logging setting was removed (logging is not supposed
  // to be a setting) — the logger stays at its debug default, always on.


  // Registered rather than awaited: acknowledging must not sit on the
  // critical path, but it must finish before the success path consumes
  // the record off disk, or the file would linger forever.
  StartupDiagnosticsStore.holdForFlush(acknowledgePersistedStartupFailure());

  AndroidExitDiagnostics.markTelemetryReady();
  return _initializeStartup(settings);
}

const startupBootstrapProgressKey = Key('startup-bootstrap-progress');

/// Human-readable build label for a failure record, primed off the critical
/// path by [_primeDiagnosticsVersion].
String _diagnosticsVersion = gitCommit.isEmpty ? 'unknown' : gitCommit.substring(0, gitCommit.length.clamp(0, 7));

/// Resolves the package version for diagnostics without putting it in the gate.
///
/// `PackageInfo.fromPlatform()` reads the executable's Win32 version resource
/// and throws `WindowsException`/`ArgumentError` when that read fails (a UNC
/// launch, antivirus interception). It used to run inside the startup gate for
/// a value only the (now-removed) crash reporter consumed; here a failure
/// just leaves the commit label.
Future<void> _primeDiagnosticsVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    final commit = gitCommit.isEmpty ? '' : ' (${gitCommit.substring(0, gitCommit.length.clamp(0, 7))})';
    _diagnosticsVersion = '${info.version}+${info.buildNumber}$commit';
  } catch (error, stackTrace) {
    appLogger.d('Could not resolve the package version for diagnostics', error: error, stackTrace: stackTrace);
  }
}

/// Platform label for a failure record. Deliberately coarse — enough to
/// triage a report, never enough to identify a machine.
String _diagnosticsPlatform() => '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

/// Whether an in-app repair can address [error].
///
/// Only preference-store damage qualifies. Everything else — a denied
/// directory, a locked database, a native library that will not load — needs
/// the environment to change, and offering a destructive repair for it would
/// be worse than offering nothing.
bool _isRepairable(Object error) {
  final cause = StartupPhaseException.unwrap(error);
  return cause is CorruptPreferenceStoreException || cause is UnreadableSensitivePreferenceException;
}

/// Default [StartupBootstrap.describeFailure].
@visibleForTesting
StartupFailureRecord describeStartupFailure(Object error, StackTrace stackTrace) => StartupFailureRecord.fromError(
  error: error,
  stackTrace: stackTrace,
  appVersion: _diagnosticsVersion,
  platform: _diagnosticsPlatform(),
  repairable: _isRepairable(error),
);

/// Acknowledges a persisted startup failure locally, once.
///
/// 1.2.22 §66 (U4): there is no crash reporter any more (Sentry is cut —
/// its DSN was dead in shipped builds), so nothing is ever sent. The
/// record is still marked reported so
/// [StartupDiagnosticsStore.consumePrevious] can drop the file instead of
/// carrying it forever; the record itself stays visible for the session
/// in Settings › Logs, where the user can submit it to our GitHub repo.
/// Replaces `flushPendingStartupFailure`.
@visibleForTesting
Future<void> acknowledgePersistedStartupFailure() async {
  final record = await StartupDiagnosticsStore.peekPersisted();
  if (record == null || record.reported) return;
  await StartupDiagnosticsStore.markReported(record);
}


/// Default [StartupBootstrap.repair]: states the cost, runs the repair that
/// matches the failure, then reports what was kept and what was lost.
///
/// The result tells the bootstrap what it may do next; see
/// [StartupRepairResult]. Never returns [StartupRepairResult.retry] for a
/// repair that requires a restart — re-running initialization in that state
/// would destroy the salvage.
@visibleForTesting
Future<StartupRepairResult> repairStartupStorage(
  BuildContext context,
  StartupFailureRecord record,
  Object error,
) async {
  final cause = StartupPhaseException.unwrap(error);
  final unreadableKey = cause is UnreadableSensitivePreferenceException ? cause.key : null;
  final reopenSafe = cause is! CorruptPreferenceStoreException || cause.reopenSafe;

  // Name the real cost before touching anything, not the usual one. Servers
  // and profiles survive a repair only because their tokens are ciphertext in
  // the database and the key that decrypts them lives in the store — so a
  // store the key cannot be read out of signs the user out of everything. An
  // all-zero file is exactly that case (#1732), and telling them their
  // sign-ins are safe would be a promise the outcome dialog then contradicts.
  final signInsSurvive = unreadableKey != null
      ? unreadableKey != credentialVaultKeyPref
      : (await PrefsRecovery.previewSalvage()).vaultKey != null;
  if (!context.mounted) return StartupRepairResult.none;

  final confirmed = await showConfirmDialog(
    context,
    title: t.startup.repairTitle,
    message: repairConsentMessage(oneCredential: unreadableKey != null, signInsSurvive: signInsSurvive),
    confirmText: t.startup.repairConfirm,
    isDestructive: true,
  );
  if (!confirmed || !context.mounted) return StartupRepairResult.none;

  final outcome = unreadableKey != null
      ? await BaseSharedPreferencesService.dropUnreadableCredential(unreadableKey)
      : await BaseSharedPreferencesService.repairCorruptStore(reopenSafe: reopenSafe);
  // The repair replaced or dropped entries in the backing store, so the vault's
  // memoized key and its ciphertext -> plaintext cache now describe a store
  // that no longer exists. Drop both before anything reads a credential again,
  // or a repaired install could keep serving pre-repair plaintext.
  CredentialVault.invalidateCache();
  final result = outcome.requiresRestart ? StartupRepairResult.restart : StartupRepairResult.retry;
  if (!context.mounted) return result;

  await showRepairOutcomeDialog(context, outcome);
  return result;
}

/// The consent dialog's body: what is being repaired, then what it costs.
///
/// Separated from [repairStartupStorage] because the two halves fail
/// differently. Deciding whether the sign-ins survive is I/O against a
/// damaged file; deciding what to *tell* the user about it is a promise, and
/// #1732 is what happens when the promise is written once, optimistically,
/// for a case that does not always hold.
///
/// [signInsSurvive] covers servers and profiles only. Their tokens are
/// ciphertext in the database, so they live or die with the vault key —
/// which is exactly why that one value decides this sentence.
///
/// Tracker and Seerr sessions are plaintext preference entries, salvaged and
/// reseeded one by one and untouched entirely by the single-credential
/// repair. They therefore do not follow the vault key in either direction,
/// and get one cautious sentence in both branches rather than a promise
/// borrowed from a value that does not govern them.
@visibleForTesting
String repairConsentMessage({required bool oneCredential, required bool signInsSurvive}) => [
  oneCredential ? t.startup.repairBodyOneCredential : t.startup.repairBodyCommon,
  signInsSurvive ? t.startup.repairBodySignInsKept : t.startup.repairBodySignInsLost,
  t.startup.repairBodySessionsUncertain,
].join('\n\n');

/// Reports a completed repair, including the retained copy of the damaged
/// store.
///
/// The backup path is shown so the user can find and delete it, never so it
/// can be attached to a report: it can hold the credential-vault key, tracker
/// refresh tokens and Seerr cookies in plaintext. The warning is suppressed
/// only when the quarantined *bytes* prove there is nothing in them — an
/// all-zero file (#1732) — never on the strength of what the salvage managed
/// to recover, which says nothing about what is still in the file. A warning
/// on a file of zeros is the one that teaches users to ignore the warning
/// that matters.
@visibleForTesting
Future<void> showRepairOutcomeDialog(
  BuildContext context,
  PrefsRepairOutcome outcome, {
  // Test seam: the widget-test binding's fake-async zone never completes a
  // `dart:io` future, so a real delete cannot be driven from a widget test.
  Future<void> Function(String path) deleteBackup = PrefsRecovery.deleteBackup,
}) {
  final backupPath = outcome.backupPath;
  // Outside the builder: a `StatefulBuilder` re-runs its closure on every
  // rebuild, so state declared inside it would reset the moment the rebuild it
  // triggered arrives — leaving the sensitive path on screen after deletion.
  var deleted = false;
  return showScopedDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        return AlertDialog(
          title: Text(outcome.requiresRestart ? t.startup.repairNeedsRestart : t.startup.repairSucceeded),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(outcome.vaultKeySalvaged ? t.startup.repairKeptSignIns : t.startup.repairLostSignIns),
              if (outcome.sessionsAffected) ...[const SizedBox(height: 8), Text(t.startup.repairLostSessions)],
              if (backupPath != null && !deleted) ...[
                const SizedBox(height: 16),
                Text(t.startup.backupTitle, style: Theme.of(dialogContext).textTheme.titleSmall),
                const SizedBox(height: 4),
                SelectableText(backupPath, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                if (outcome.backupHoldsCredentials) ...[
                  const SizedBox(height: 4),
                  Text(t.startup.backupWarning, style: TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
                ],
                const SizedBox(height: 8),
                DialogActionButton(
                  label: t.startup.deleteBackup,
                  onPressed: () async {
                    await deleteBackup(backupPath);
                    // The barrier can dismiss this dialog while the delete is
                    // in flight; the file is gone either way.
                    if (!dialogContext.mounted) return;
                    setDialogState(() => deleted = true);
                  },
                ),
              ],
              if (deleted) ...[const SizedBox(height: 8), Text(t.startup.backupDeleted)],
            ],
          ),
          actions: [
            DialogActionButton(
              autofocus: true,
              isPrimary: true,
              onPressed: () => Navigator.of(dialogContext).pop(),
              label: t.common.close,
            ),
          ],
        );
      },
    ),
  );
}

/// Theme the startup frames adopt once the persisted preference is readable.
typedef StartupThemeResolution = ({material.ThemeMode themeMode, ThemeData lightTheme, ThemeData darkTheme});

/// Mounts a Flutter-owned startup frame before invoking the asynchronous
/// initialization gate. The generic seam keeps frame ordering, failure, and
/// retry behavior testable without constructing platform services.
@visibleForTesting
class StartupBootstrap<T> extends StatefulWidget {
  const StartupBootstrap({
    super.key,
    required this.initialize,
    required this.buildApp,
    this.discard,
    this.onCommitted,
    this.describeFailure = describeStartupFailure,
    this.repair = repairStartupStorage,
    this.lightTheme,
    this.darkTheme,
    this.themeMode = material.ThemeMode.system,
    this.resolveTheme,
    this.transparentWhileLoading = false,
  });

  final Future<T> Function() initialize;
  final Widget Function(BuildContext context, T value) buildApp;
  final FutureOr<void> Function(T value)? discard;
  final FutureOr<void> Function(T value)? onCommitted;

  /// Reduces a thrown error to the allowlisted record the failure screen,
  /// the persisted diagnostic and the crash report all share.
  final StartupFailureRecord Function(Object error, StackTrace stackTrace) describeFailure;

  /// Offers the user a consented repair for a recoverable failure and reports
  /// what the gate may do next. [StartupRepairResult.retry] re-runs
  /// [initialize]; [StartupRepairResult.restart] parks the app on the failure
  /// screen, because nothing may touch preferences until the process restarts.
  ///
  /// The context is a descendant of the gate's own bootstrap [MaterialApp]
  /// (never the gate `State`'s context, which sits above it), so dialogs and
  /// snackbars can resolve a `Navigator`, `MaterialLocalizations` and
  /// `ScaffoldMessenger` from it.
  final Future<StartupRepairResult> Function(BuildContext context, StartupFailureRecord record, Object error)? repair;

  final ThemeData? lightTheme;
  final ThemeData? darkTheme;
  final material.ThemeMode themeMode;

  /// Reads the persisted theme so the startup frames match the one the app
  /// settles on. Until it answers, [themeMode] resolves from platform
  /// brightness, which disagrees with the app's own default on every device
  /// that reports light while running the dark or OLED theme (#1833).
  final Future<StartupThemeResolution> Function()? resolveTheme;

  /// Whether the platform window behind Flutter already paints the launch
  /// background, so the loading frame must not cover it.
  ///
  /// True only on Android, where `TransparencyMode.transparent` lets the
  /// window decor show through and `PlezyActivity` has already restored the
  /// persisted launch colour.
  final bool transparentWhileLoading;

  @override
  State<StartupBootstrap<T>> createState() => _StartupBootstrapState<T>();
}

class _StartupBootstrapState<T> extends State<StartupBootstrap<T>> {
  T? _value;
  StartupFailureRecord? _failure;

  /// Retained alongside [_failure] so the repair hook can classify the real
  /// cause; the record is a redacted allowlist and deliberately cannot.
  Object? _failureError;
  bool _completed = false;
  bool _initializing = false;
  bool _repairing = false;

  /// Terminal: the store was repaired but the plugin still holds the bad
  /// document, so this process can never open it. Latched, never cleared —
  /// re-running the gate from here would flush the stale map over the seed.
  bool _restartRequired = false;
  int _generation = 0;

  /// Persisted theme for the startup frames, null until [StartupBootstrap.resolveTheme] answers.
  StartupThemeResolution? _resolvedTheme;

  @override
  void initState() {
    super.initState();
    unawaited(_resolveTheme());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AndroidExitDiagnostics.markStartupPhase(AndroidStartupPhase.firstFrame);
      // L-53: the session frame-time window starts at the first frame —
      // one addTimingsCallback, O(1) per frame, rendered in the dump.
      FrameTimeRegistry.startSessionWindow();
      if (mounted) unawaited(_initialize());
    });
  }

  /// Adopts the persisted theme for the startup frames.
  ///
  /// Deliberately best-effort and unbounded: on Android the loading frame is
  /// transparent, so a slow answer costs spinner contrast rather than the
  /// launch, and a store this cannot read is the gate's failure to report —
  /// reporting it twice would race the diagnostic record.
  Future<void> _resolveTheme() async {
    final resolve = widget.resolveTheme;
    if (resolve == null) return;
    try {
      final resolved = await resolve();
      if (!mounted) return;
      setState(() => _resolvedTheme = resolved);
    } catch (error, stackTrace) {
      appLogger.d('Could not resolve the persisted startup theme', error: error, stackTrace: stackTrace);
    }
  }

  Future<void> _initialize() async {
    if (_initializing) return;

    final generation = ++_generation;
    setState(() {
      _failure = null;
      _initializing = true;
    });

    try {
      final value = await widget.initialize();
      if (!mounted || generation != _generation) {
        await _discard(value);
        return;
      }

      setState(() {
        _value = value;
        _completed = true;
        _initializing = false;
      });
      // A launch that got through is the first chance to surface a record
      // written by one that did not. Consuming it takes the file off disk and
      // holds the contents in memory for Settings › Logs, so the user can
      // upload the failure that had no other way out (#1732).
      unawaited(StartupDiagnosticsStore.consumePrevious());
      unawaited(Future.sync(() => widget.onCommitted?.call(value)));
    } catch (error, stackTrace) {
      final failure = widget.describeFailure(error, stackTrace);
      // `headline` is the sanitised rendering; the raw error is deliberately
      // not passed, because `FormatException.toString()` embeds an excerpt of
      // whatever document failed to parse.
      appLogger.e('Startup initialization failed: ${failure.headline}', stackTrace: stackTrace);
      // Persist first: this record is the only thing that survives the
      // process. On Windows there is no log file and no console for a
      // double-clicked release build.
      unawaited(StartupDiagnosticsStore.record(failure));
      // Not sent from here: there is no crash reporter any more
      // (1.2.22 §66 U4), so the record is persisted and acknowledged
      // locally on the next launch — and the user can submit it from
      // Settings › Logs.
      if (!mounted || generation != _generation) return;
      setState(() {
        _failure = failure;
        _failureError = error;
        _initializing = false;
      });
    }
  }

  /// [context] must sit below the bootstrap `MaterialApp` — it comes from the
  /// `home` builder in [_buildBootstrapHome]. The gate `State`'s own context
  /// is above that `MaterialApp` and has no `Navigator`,
  /// `MaterialLocalizations` or `ScaffoldMessenger`, so the repair dialogs and
  /// the failure snackbar would all throw when built from it.
  Future<void> _repair(BuildContext context, StartupFailureRecord failure) async {
    final repair = widget.repair;
    final error = _failureError;
    if (repair == null || error == null || _repairing || _restartRequired) return;
    setState(() => _repairing = true);
    var result = StartupRepairResult.none;
    try {
      result = await repair(context, failure, error);
    } catch (error, stackTrace) {
      appLogger.e('Startup storage repair failed', error: error, stackTrace: stackTrace);
      if (context.mounted) showErrorSnackBar(context, t.startup.repairFailed);
    }
    if (!mounted) return;
    setState(() {
      _repairing = false;
      if (result == StartupRepairResult.restart) _restartRequired = true;
    });
    if (result == StartupRepairResult.retry) unawaited(_initialize());
  }

  Future<void> _discard(T value) async {
    try {
      await widget.discard?.call(value);
    } catch (error, stackTrace) {
      appLogger.e('Failed to dispose an uncommitted startup result (${error.runtimeType})', stackTrace: stackTrace);
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_completed) return widget.buildApp(context, _value as T);

    final resolved = _resolvedTheme;
    return TranslationProvider(
      child: Builder(
        builder: (context) => InputModeTracker(
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            // Quest laser pointer (mouse-kind) drags scroll, like touch.
            scrollBehavior: const AppScrollBehavior(),
            locale: TranslationProvider.of(context).locale.localizationsLocale,
            supportedLocales: supportedLocalizationsLocales,
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: resolved?.lightTheme ?? widget.lightTheme,
            darkTheme: resolved?.darkTheme ?? widget.darkTheme,
            themeMode: resolved?.themeMode ?? widget.themeMode,
            builder: (context, child) => AppSystemUiStyle(child: child!),
            home: Builder(builder: _buildBootstrapHome),
          ),
        ),
      ),
    );
  }

  Widget _buildBootstrapHome(BuildContext context) {
    final failure = _failure;
    if (failure != null) {
      return Scaffold(
        body: StartupFailureView(
          failure: failure,
          busy: _initializing || _repairing,
          restartRequired: _restartRequired,
          onRetry: () => unawaited(_initialize()),
          onRepair: failure.repairable && widget.repair != null ? () => _repair(context, failure) : null,
        ),
      );
    }

    // Nothing here is worth covering the launch screen for. The platform
    // window already holds the user's launch colour, and this frame outlives
    // the whole gate, so painting a theme guessed from platform brightness is
    // what turned a black Android TV splash into a flashbang (#1833).
    return Scaffold(
      backgroundColor: widget.transparentWhileLoading ? Colors.transparent : null,
      body: const Center(child: CircularProgressIndicator(key: startupBootstrapProgressKey)),
    );
  }
}

class _StartupDependencies {
  const _StartupDependencies({
    required this.settings,
    required this.storage,
    required this.appDatabase,
    required this.databaseRecoveryOutcome,
  });

  final SettingsService settings;
  final StorageService storage;
  final AppDatabase appDatabase;
  final TvosDatabaseRecoveryOutcome databaseRecoveryOutcome;
}

@visibleForTesting
Future<AppDatabaseBootstrap> openAppDatabaseWithDownloadRecovery({
  required Future<AppDatabaseBootstrap> Function() openDatabase,
  required Future<void> Function() recoverNativeDownloads,
  required String storageFullMessage,
}) async {
  // 1.2.19, L-13a (verified, no move needed): the downloads-recovery
  // directory/record walk does NOT run in this gate — it runs
  // post-first-frame via DownloadManagerService.recoveryFuture
  // (endOfFrame in _MainAppState). The only recovery in this path is the
  // two small native-downloader calls below, and only when the database
  // open actually fails with storage-full — there the recovery is
  // load-bearing for the retry (it frees the space the retry needs),
  // so it stays in the gate on that rare path.
  try {
    return await openDatabase();
  } catch (error, stackTrace) {
    if (!isStorageFullError(error)) rethrow;
    appLogger.w(
      'Application database could not open because storage is full; discarding interrupted downloads',
      error: error,
      stackTrace: stackTrace,
    );
  }

  await recoverNativeDownloads();
  final bootstrap = await openDatabase();
  try {
    final failedKeys = await bootstrap.database.failActiveDownloadsForStorageFull(storageFullMessage);
    appLogger.w('Recovered startup after storage exhaustion; stopped ${failedKeys.length} active download(s)');
    return bootstrap;
  } catch (_) {
    // The caller only takes ownership once this helper returns, so the freshly
    // opened background isolate has to be released here.
    await bootstrap.database.close();
    rethrow;
  }
}

Future<_StartupDependencies> _initializeStartup(SettingsService settings) async {
  // 1.2.7 (two modes): apply the stored catalog mode before any IPTV
  // client can bind — the prune switch defaults to Low RAM, so only a
  // stored Instant search install flips it off. An existing install
  // with no stored mode reads the Low RAM default, matching the 1.2.4
  // behaviour it already has.
  IptvClient.applyCatalogMode(settings.read(SettingsService.iptvCatalogMode));

  final startupWatch = Stopwatch()..start();
  var lastStartupMarkMs = 0;
  void markStartupPhase(String phase) {
    // 1.2.19, L-13c: phase durations are recorded in release builds too
    // (not profile-only) — the debug export renders them, so the next
    // phone/TV dump attributes startup time per phase.
    final elapsedMs = startupWatch.elapsedMilliseconds;
    StartupPhaseTimings.record(phase, elapsedMs - lastStartupMarkMs, elapsedMs);
    appLogger.i('Startup phase $phase: ${elapsedMs - lastStartupMarkMs}ms (total ${elapsedMs}ms)');
    lastStartupMarkMs = elapsedMs;
  }

  AppDatabase? openedDatabase;
  // Started first so the store walk overlaps the phases below. Every request
  // to a user-entered server verifies against the result, so it is awaited
  // before any client can exist (#2339); the load itself never throws.
  final userAuthorities = Platform.isAndroid ? CertificateTrust.loadUserAuthorities() : null;
  try {
    // Slang builds the base locale eagerly, so `t` already resolves before
    // this runs; a failure here degrades to English rather than no app.
    await _optionalGatePhase(StartupPhase.locale, () async {
      final savedLocale = settings.read(SettingsService.appLocale);
      await LocaleSettings.setLocale(savedLocale);
    });
    markStartupPhase('locale');

    // Window chrome is cosmetic; losing it costs the custom titlebar and the
    // remembered size, not the app. It is also the step most exposed to a
    // stalled platform thread, so it must not sit in the same combined future
    // as the services the first build genuinely needs.
    if (PlatformDetector.isDesktopOS()) {
      await _optionalGatePhase(StartupPhase.windowManager, () async {
        await windowManager.ensureInitialized();
        if (Platform.isMacOS) await MacOSWindowService.setupCustomTitlebar();
      });
    }

    // MainApp reads the first two synchronous facades during its first build
    // and the Jellyfin device profile the third at playback negotiation. All
    // three have a working sync fallback, so a detection failure is not fatal.
    // 1.2.19, L-13b: the codec probe is LAZY — VideoDecodeCapabilities is
    // only consumed at playback negotiation/transcode, never by the first
    // build, so the MediaCodecList enumeration no longer sits in the gate.
    // It starts post-first-frame (see _startNonessentialInitialization)
    // and on first use (VideoDecodeCapabilities.ensureProbed); until it
    // lands the accessors advertise both codecs (the documented safe
    // default).
    await _optionalGatePhase(StartupPhase.deviceCapabilities, () async {
      await (
        TvDetectionService.getInstance(forceTv: settings.read(SettingsService.forceTvMode)),
        DevicePerformance.getInstance(override: settings.read(SettingsService.visualEffects)),
      ).wait;
    });

    if (userAuthorities != null) {
      await _optionalGatePhase(StartupPhase.certificateTrust, () => userAuthorities);
    }

    final storage = await _gatePhase(StartupPhase.storage, StorageService.getInstance);
    markStartupPhase('platform-services');

    AndroidExitDiagnostics.markStartupPhase(AndroidStartupPhase.databaseOpenStarted);
    final databaseBootstrap = await _gatePhase(
      StartupPhase.database,
      () => openAppDatabaseWithDownloadRecovery(
        openDatabase: () => AppDatabase.open(isTvos: PlatformDetector.isAppleTV()),
        recoverNativeDownloads: DownloadManagerService.discardInterruptedNativeDownloadsAfterStorageFailure,
        storageFullMessage: t.downloads.storageFull,
      ),
    );
    openedDatabase = databaseBootstrap.database;
    AndroidExitDiagnostics.markStartupPhase(AndroidStartupPhase.databaseReady);
    markStartupPhase('database-recovery');

    await _optionalGatePhase(StartupPhase.imageCache, () async {
      DevicePerformance.applyImageCacheBudget();
      // L-20: read free space before any artwork loads, so the image
      // disk cache is built with the low-storage cap (500 objects) when
      // the disk is nearly full, and the verdict is persisted for the
      // background sync isolate (which has no platform channel).
      await StorageHealth.refresh();
      await PlexImageCacheManager.applyLowStorageCapIfLow();
    });

    markStartupPhase('image-cache');

    return _StartupDependencies(
      settings: settings,
      storage: storage,
      appDatabase: databaseBootstrap.database,
      databaseRecoveryOutcome: databaseBootstrap.recoveryOutcome,
    );
  } catch (_) {
    await openedDatabase?.close();
    rethrow;
  }
}

void _startNonessentialInitialization(SettingsService settings) {
  // `onCommitted` runs before the rebuild that creates MainApp. Share one
  // end-of-frame hop so synchronous tasks cannot delay its first frame.
  final afterFirstAppFrame = WidgetsBinding.instance.endOfFrame;

  void bestEffort(String name, FutureOr<void> Function() action) {
    unawaited(
      afterFirstAppFrame.then((_) => action()).catchError((Object error, StackTrace stackTrace) {
        appLogger.e('$name startup task failed (${error.runtimeType})', stackTrace: stackTrace);
      }),
    );
  }

  bestEffort(
    'Date formatting',
    () => initializeDateFormatting(settings.read(SettingsService.appLocale).intlLocaleName, null),
  );
  bestEffort('Download storage', () => DownloadStorageService.instance.initialize(settings));
  // 1.5.2: Trakt, Simkl, MAL and AniList are gone. Wipe any session tokens
  // they left behind before the coordinator loads its (MDBList-only) sessions.
  bestEffort('Tracker removal purge', TrackerAccountStore.purgeRemovedServiceSessions);
  bestEffort('Trackers', TrackerCoordinator.instance.initialize);

  // 1.2.19, L-13b: the codec probe runs here, after the first frame —
  // never in the startup gate. Playback negotiation that happens
  // before it lands reads the safe defaults (both codecs advertised).
  bestEffort('Video decode capabilities', VideoDecodeCapabilities.ensureProbed);

  bestEffort('Legacy image cache cleanup', () async {
    if (settings.read(SettingsService.cleanedOldImageCache)) return;
    try {
      final tempDir = await getTemporaryDirectory();
      final oldCacheDir = Directory('${tempDir.path}/plexImageCache');
      if (await oldCacheDir.exists()) await oldCacheDir.delete(recursive: true);
    } finally {
      await settings.write(SettingsService.cleanedOldImageCache, true);
    }
  });

  bestEffort('Native window', () {
    if (Platform.isAndroid) PipService();
    NativeWindowService.initialize();
  });

  bestEffort('Fullscreen monitor', () async {
    FullscreenStateManager().startMonitoring();
    if (PlatformDetector.isDesktopOS() && settings.read(SettingsService.startInFullscreen)) {
      await FullscreenStateManager().enterFullscreen();
    }
  });

  bestEffort('Gamepad', () {
    GamepadService.instance.start();
    if (PlatformDetector.isAppleTV()) AppleTvRemoteTouchService.instance.start();
  });

  if (PlatformDetector.isDesktopOS()) {
    bestEffort('Discord RPC', DiscordRPCService.instance.initialize);
    // Detection forks helper processes; resolve it here so the External Player
    // settings page never has to wait on a cold probe.
    bestEffort('External player detection', KnownPlayers.getForCurrentPlatform);
  }

  // 1.2.22 §66 (U4): the crash-reporting setting is gone (Sentry is cut),
  // so the previous-exit record is always logged locally — it never
  // leaves the device except through the user's own log export/submit.
  unawaited(AndroidExitDiagnostics.logPreviousExit());

  // The startup-gate application can precede the engine's first metrics
  // report, which reads as a 1.0 display budget; re-derive it now that the
  // tree is mounted and the display is known.
  bestEffort('Image cache budget', DevicePerformance.applyImageCacheBudget);
  bestEffort('Environment diagnostics', _logEnvironmentDiagnostics);
}

Future<void> _logEnvironmentDiagnostics() async {
  final packageInfo = await PackageInfo.fromPlatform();
  final commitSuffix = gitCommit.isNotEmpty ? ' (${gitCommit.substring(0, 7)})' : '';
  String renderer = '';
  if (Platform.isAndroid) {
    final rendererName = await const MethodChannel('com.plezy/theme').invokeMethod<String>('getRenderer');
    renderer = ' [$rendererName]';
  }
  appLogger.i(
    'PlezTV v${packageInfo.version}+${packageInfo.buildNumber}$commitSuffix$renderer'
    ' [effects: ${DevicePerformance.describeSync()}]',
  );
  appLogger.i('Display: ${DevicePerformance.describeDisplay()}');
  appLogger.i('Video decoders: ${VideoDecodeCapabilities.describeSync()}');
  if (Platform.isAndroid) {
    appLogger.i('Startup RSS: ${ProcessInfo.currentRss >> 20}MB');
  }
}

/// Registers notices for code Plezy ships outside its pub packages.
///
/// Runs in [main] and must stay ahead of every
/// [LicenseRegistry.licenses] reader. A reader walks the registry's live
/// collector list across each collector's await: a collector added while that
/// walk is suspended throws `ConcurrentModificationError` on the next step and
/// the read never finishes. The collectors are lazy, so registering
/// them here loads nothing until a reader runs.
/// the event never finishes enriching. The collectors are lazy, so registering
/// them here loads nothing until a reader runs.
void _registerAppLicenses() {
  _registerShaderLicenses();
  // iOS covers iPhone, iPad, and Apple TV; mpv-build links SpatialAudioBridge
  // into libmpv there and not on macOS.
  if (Platform.isIOS) _registerSpatialAudioLicenses();
}

/// Notices for the SpatialAudioBridge core compiled into libmpv, verbatim from
/// the source commit mpv-build pins (versions.json `spatialaudiobridge`).
void _registerSpatialAudioLicenses() {
  LicenseRegistry.addLicense(() async* {
    final notices = await rootBundle.loadString('assets/licenses/SpatialAudioBridge.txt');
    yield LicenseEntryWithLineBreaks(const ['SpatialAudioBridge'], notices);
  });
}

void _registerShaderLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      ['Anime4K'],
      'MIT License\n'
      '\n'
      'Copyright (c) 2019-2021 bloc97\n'
      'All rights reserved.\n'
      '\n'
      'Permission is hereby granted, free of charge, to any person obtaining a copy '
      'of this software and associated documentation files (the "Software"), to deal '
      'in the Software without restriction, including without limitation the rights '
      'to use, copy, modify, merge, publish, distribute, sublicense, and/or sell '
      'copies of the Software, and to permit persons to whom the Software is '
      'furnished to do so, subject to the following conditions:\n'
      '\n'
      'The above copyright notice and this permission notice shall be included in all '
      'copies or substantial portions of the Software.\n'
      '\n'
      'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR '
      'IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, '
      'FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE '
      'AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER '
      'LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, '
      'OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE '
      'SOFTWARE.',
    );
    yield const LicenseEntryWithLineBreaks(
      ['NVIDIA Image Scaling (NVScaler)'],
      'The MIT License (MIT)\n'
      '\n'
      'Copyright (c) 2022 NVIDIA CORPORATION & AFFILIATES. All rights reserved.\n'
      '\n'
      'Permission is hereby granted, free of charge, to any person obtaining a copy of '
      'this software and associated documentation files (the "Software"), to deal in '
      'the Software without restriction, including without limitation the rights to '
      'use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of '
      'the Software, and to permit persons to whom the Software is furnished to do so, '
      'subject to the following conditions:\n'
      '\n'
      'The above copyright notice and this permission notice shall be included in all '
      'copies or substantial portions of the Software.\n'
      '\n'
      'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR '
      'IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS '
      'FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR '
      'COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER '
      'IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN '
      'CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.',
    );
  });
}

final rootNavigatorKey = GlobalKey<NavigatorState>();

@visibleForTesting
bool shouldEnterOfflineModeAfterStartupBind({required bool bindingSucceeded, required bool hasOnlineServers}) {
  return !bindingSucceeded && !hasOnlineServers;
}

/// Whether the splash proceeds to MainScreen after the startup-bind wait.
/// A cap expiry with the binder still running (network branch only) is not
/// a failed bind: the bind keeps running, and MainScreen's composite offline
/// verdict flips to the offline shell by itself if the bind ultimately fails
/// with zero servers online. Without this check a slow Trex probe would
/// route splash → offline shell → MainScreen a second later (R5 §5.1).
@visibleForTesting
bool shouldProceedToMainScreenAfterStartupBind({
  required bool bindingSucceeded,
  required bool hasOnlineServers,
  required bool bindStillRunning,
  required bool hasNetwork,
}) {
  if (hasNetwork && bindStillRunning) return true;
  return !shouldEnterOfflineModeAfterStartupBind(
    bindingSucceeded: bindingSucceeded,
    hasOnlineServers: hasOnlineServers,
  );
}

/// The splash's wait for the initial bind. The wait is capped in both
/// branches: the unified startup deadline's remaining time when the splash
/// started one (per-tier — L-15: T0 8 s, T1 10 s, T2+ 15 s), otherwise the
/// tier cap with a network, [MediaServerTimeouts.noNetworkStartupBind]
/// without one. A timeout reads as a failed bind AT THIS LAYER (the future
/// completes false) — the caller must disambiguate with the binder's
/// `isBinding` before routing to the offline shell (see
/// `shouldProceedToMainScreenAfterStartupBind`): a cap expiry with the bind
/// still running is a slow bind, not a failed one. The bind itself keeps
/// running either way. MainScreen's settle fallback waits whatever is left
/// of the same deadline (L-22) — the two ceilings no longer stack to 30 s.
@visibleForTesting
Future<bool> awaitStartupBindSettle(Future<bool> settle, {required bool hasNetwork}) {
  final cap =
      StartupDeadlineTracker.current?.remaining ??
      (hasNetwork
          ? DevicePerformance.splashBindCapFor(DevicePerformance.currentTier)
          : MediaServerTimeouts.noNetworkStartupBind);
  return settle.timeout(cap, onTimeout: () => false);
}

/// Top-level PIN prompt used by [ActiveProfileBinder] when it runs above the
/// profile-scoped widget tree. Routes through the app-global
/// [rootNavigatorKey] so the dialog survives profile-session remounts. Returns
/// `null` when no Navigator is available yet (early boot, post-dispose) so the
/// binder treats it as "PIN cancelled".
Future<String?> _rootPinPrompt(Profile profile, {String? errorMessage}) {
  final ctx = rootNavigatorKey.currentContext;
  if (ctx == null) return Future.value(null);
  return showPinEntryDialog(ctx, profile.displayName, errorMessage: errorMessage);
}

/// Applies the profile a deep link names once the app is running, from the
/// root navigator so the PIN dialog and the switch outlive the profile
/// session they replace.
class _RootDeepLinkProfileHost implements DeepLinkProfileHost {
  const _RootDeepLinkProfileHost();

  BuildContext? get _context => rootNavigatorKey.currentState?.overlay?.context;

  @override
  List<Profile> get profiles => _context?.read<ActiveProfileProvider>().profiles ?? const [];

  @override
  String? get activeProfileId => _context?.read<ActiveProfileProvider>().activeId;

  @override
  Future<bool> switchTo(Profile profile) async {
    // Playback leaves first so its final progress report still carries the
    // outgoing profile's token.
    final coordinator = PlaybackCoordinator.instance;
    if (!await coordinator.stopVideoAndExit()) await coordinator.shutdownVideo();
    final context = _context;
    if (context == null || !context.mounted) return false;
    return switchProfileFromUi(context, profile);
  }
}

class MainApp extends StatefulWidget {
  final SettingsService settings;
  final StorageService storage;
  final AppDatabase appDatabase;
  final TvosDatabaseRecoveryOutcome databaseRecoveryOutcome;

  const MainApp({
    super.key,
    required this.settings,
    required this.storage,
    required this.appDatabase,
    required this.databaseRecoveryOutcome,
  });

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> with WidgetsBindingObserver {
  late final MultiServerManager _serverManager;
  late final DataAggregationService _aggregationService;
  late final LibraryEventService _libraryEventService;
  late final AppDatabase _appDatabase;
  late final DownloadManagerService _downloadManager;
  late final OfflineWatchSyncService _offlineWatchSyncService;
  late final ConnectionRegistry _connections;
  late final ProfileConnectionRegistry _profileConnections;
  late final PlexHomeService _plexHomeService;
  late final AppLifecycleListener _appLifecycleListener;
  StreamSubscription<WatchStateEvent>? _watchStateSubscription;

  /// WiFi-reconnect sync trigger, listening on [OfflineModeProvider] — the
  /// app's single connectivity subscription lives there.
  VoidCallback? _connectivitySyncListener;
  OfflineModeProvider? _connectivitySyncProvider;
  Timer? _syncDebounce;
  final Set<String> _pendingSyncKeys = <String>{};

  /// The [_autoDeleteAndSync] pass in flight; exit teardown awaits it.
  Completer<void>? _autoDeleteRun;
  bool _lastConnectivityWasWifi = false;
  bool _lastConnectivityHadNetwork = true;
  Future<void>? _shutdownFuture;

  /// Last time server health probes ran from a resume event (cooldown for desktop)
  DateTime _lastResumeProbe = DateTime(0);

  /// True when the app went to the background since the last resume
  /// (build v1.0.13, R4.2): the resume-time catalog due-check runs only
  /// on a resume that follows a background trip — never at startup (the
  /// startup rule: the app opens from the local file) and never on a
  /// plain window-focus resume on desktop.
  bool _wasBackgrounded = false;

  /// Periodic RSS watchdog timer (desktop + Android).
  Timer? _memoryCheckTimer;

  /// Last watchdog eviction, for the cooldown; RSS at that moment so a
  /// still-climbing RSS can re-evict inside the cooldown window.
  DateTime _lastRssEviction = DateTime(0);
  int _lastEvictionRss = 0;

  /// Last images-only eviction from a native trim (1.2.19 L-6 throttle).
  DateTime _lastTrimImageEviction = DateTime(0);

  @override
  void initState() {
    super.initState();
    // 1.2.4: assigned before the observer registers — didHaveMemoryPressure
    // can fire as soon as this observes, and it drops the IPTV caches
    // through _serverManager (a late final: reading it before this line
    // would throw).
    _serverManager = MultiServerManager();
    // 1.2.18 S-4c: the pressure breadcrumb samples the IPTV memory
    // stats (before + after the eviction) through the manager.
    MemoryPressureBreadcrumbs.iptvMemoryStatsProvider =
        () => _serverManager.iptvMemoryStats();
    WidgetsBinding.instance.addObserver(this);
    // 1.2.19 L-6: the native trim forward (MpvPlayerPlugin) lands on the
    // device channel. Installed here — _serverManager already exists —
    // so the OS signal reaches the same drop path as the watchdog.
    deviceChannel.setMethodCallHandler(_handleDeviceChannelCall);

    // The watchdog's first useful sample is at least 15 seconds away; install
    // its timer only after the first app frame has completed.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startRssWatchdog();
      // 1.2.19 L-27: keep the native surface-render-mode flag in sync with
      // the Dart setting (the native side reads it in getRenderMode() on
      // the next cold start). Best-effort; the tile also writes it.
      if (mounted) unawaited(_syncNativeDisplayModes());
    });

    // Build v1.0.13 (R4): register the periodic background catalog sync
    // (WorkManager, at the user's sync-interval setting). Registration
    // is not a run — the app still opens from the local file (startup
    // rule); the job fires on the OS schedule. Never awaited: a failed
    // registration must not block startup.
    unawaited(
      IptvBackgroundSync.initialize().then((_) => IptvBackgroundSync.ensureRegistered()),
    );
    _aggregationService = DataAggregationService(_serverManager);
    _libraryEventService = LibraryEventService(_serverManager);
    _appDatabase = widget.appDatabase;

    PlexApiCache.initialize(_appDatabase);
    JellyfinApiCache.initialize(_appDatabase);

    _downloadManager = DownloadManagerService(
      database: _appDatabase,
      storageService: DownloadStorageService.instance,
      clientResolver: _serverManager.resolveDownloadClient,
    );
    // Keep the awaitable assigned synchronously, but do not let recovery's
    // Drift/native work compete with SetupScreen's first frame.
    _downloadManager.recoveryFuture = WidgetsBinding.instance.endOfFrame.then(
      (_) => _downloadManager.recoverInterruptedDownloads(),
    );

    _offlineWatchSyncService = OfflineWatchSyncService(database: _appDatabase, serverManager: _serverManager);

    _connections = ConnectionRegistry(_appDatabase);
    _profileConnections = ProfileConnectionRegistry(_appDatabase);
    // Owned here rather than by its provider: exit teardown must settle it
    // before the database closes. Hydrate the disk cache eagerly for profile
    // resolution; live refresh starts only after MainScreen has settled the
    // startup offline decision.
    _plexHomeService = PlexHomeService(
      connections: _connections,
      profileConnections: _profileConnections,
      storage: widget.storage,
    );
    unawaited(_plexHomeService.hydrate());

    // The first read registers the link channel handler.
    DeepLinkService.instance.host = const _RootDeepLinkProfileHost();

    _appLifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        await _shutdownForExit();
        return AppExitResponse.exit;
      },
    );
  }

  Future<void> _shutdownForExit() => _shutdownFuture ??= _runShutdownForExit().timeout(
    const Duration(seconds: 15),
    onTimeout: () {
      appLogger.w('Application exit teardown exceeded its deadline');
    },
  );

  Future<void> _runShutdownForExit() async {
    // Hide the window before anything else so the exit reads as an instant
    // close: the teardown below runs against a still-mounted tree and its
    // state churn must never be user-visible. Cmd+Q and OS-initiated exits
    // arrive here directly, so the close-button path is not the only entry.
    // Bounded — hide() is a platform-channel round trip and a stalled
    // platform thread must not hold the already-accepted exit open.
    if (PlatformDetector.isDesktopOS()) {
      try {
        await windowManager.hide().timeout(const Duration(seconds: 1));
      } catch (e, st) {
        appLogger.w('Failed to hide window before exit teardown', error: e, stackTrace: st);
      }
    }

    // The player owns the backend session. Flush it while its client and
    // native position still exist, before unrelated cleanup can delay exit.
    try {
      await PlaybackCoordinator.instance.shutdownVideo().timeout(const Duration(seconds: 3));
    } catch (e, st) {
      appLogger.w('Video shutdown did not complete before exit', error: e, stackTrace: st);
    }

    _syncDebounce?.cancel();
    await _watchStateSubscription?.cancel();
    _removeConnectivitySyncListener();
    _memoryCheckTimer?.cancel();

    _libraryEventService.dispose();
    _downloadManager.dispose();
    // Quitting straight from the player is a real stop: the trackers that own
    // their own watched semantics need the terminal report before the process
    // goes away. Bounded — a hung tracker must not hold the app open.
    try {
      await TrackerCoordinator.instance.stopPlayback().timeout(const Duration(seconds: 3));
    } catch (e, st) {
      appLogger.w('Tracker shutdown did not complete before exit', error: e, stackTrace: st);
    }
    TrackerCoordinator.instance.cancelInFlight();

    await _serverManager.shutdown();
    await Future.wait([
      httpClient.closeGracefully(drainTimeout: const Duration(seconds: 5)),
      closeArtworkHttpClientGracefully(),
    ], eagerError: false);
    await ManagedHttpClient.closeAllGracefully();
    // Settle everything that can still query the database. A query issued
    // after close throws from whichever timer or callback started it, and
    // those keep firing if the process outlives this teardown (#2651, #3012).
    await Future.wait([
      _plexHomeService.dispose(),
      _offlineWatchSyncService.stopBackgroundSync(),
      ?_autoDeleteRun?.future,
    ]);
    await _appDatabase.close();
  }

  @override
  void dispose() {
    _syncDebounce?.cancel();
    _watchStateSubscription?.cancel();
    _removeConnectivitySyncListener();
    _memoryCheckTimer?.cancel();
    // 1.2.19 L-6: release the native trim forward handler.
    deviceChannel.setMethodCallHandler(null);
    _appLifecycleListener.dispose();
    if (_shutdownFuture == null) {
      _libraryEventService.dispose();
      _downloadManager.dispose();
      _serverManager.dispose();
      unawaited(_plexHomeService.dispose());
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 1.4 (F5): emit the structured RELIEF line 3 s after the drop,
  /// not synchronously — the RSS sampled right after a drop reads 0 MB
  /// freed because GC has not run yet (both 1.3.29 trips were OS trims
  /// level 20 that cleared 64 guide entries + 1,940 programmes yet read
  /// 0 MB). The delayed sample is the post-GC number, logged on the
  /// same line as `rssMbAfterDelayed`; the immediate `rssMbAfter` stays
  /// the at-drop number. The prose warnings at the call sites stay the
  /// contemporaneous record. Telemetry never breaks the valve:
  /// guarded by `mounted` + try/catch.
  void _logReliefDelayed({
    required String src,
    required String reason,
    required int rssBeforeMb,
    required int rssAfterMb,
    required String dropped,
    bool? memoDropped,
    int? epgWindowPrograms,
    int? epgCacheLen,
    int? imageCacheMbBefore,
    int? imageCacheMbAfter,
  }) {
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      try {
        ReliefLog.instance.log(
          src: src,
          reason: reason,
          rssBeforeMb: rssBeforeMb,
          rssAfterMb: rssAfterMb,
          rssDelayedMb: ProcessInfo.currentRss >> 20,
          dropped: dropped,
          memoDropped: memoDropped,
          epgWindowPrograms: epgWindowPrograms,
          epgCacheLen: epgCacheLen,
          imageCacheMbBefore: imageCacheMbBefore,
          imageCacheMbAfter: imageCacheMbAfter,
        );
      } catch (_) {
        // Telemetry must never break the valve it records.
      }
    });
  }

  /// 1.4 (F5): the native-trim full drops log prose only (no RELIEF
  /// line) — the same 0-MB-after misreading applies there, because
  /// both 1.3.29 trips took this path. Schedule a delayed prose
  /// follow-up carrying the post-GC RSS so the debug export shows
  /// what the drop actually freed.
  void _logNativeTrimDelayed({required int level, required int rssAfterMb}) {
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      try {
        final delayedMb = ProcessInfo.currentRss >> 20;
        appLogger.w(
          'Native trim level $level, RSS after GC ${delayedMb}MB '
          '(was ${rssAfterMb}MB right after the drop)',
        );
      } catch (_) {
        // Telemetry must never break the valve it records.
      }
    });
  }

  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    // L-55: the structured RELIEF line — the valve's value is the
    // after-number, which the old prose line never carried.
    final rssBefore = ProcessInfo.currentRss;
    final rssBeforeMb = rssBefore >> 20;
    final imageCacheMbBefore = PaintingBinding.instance.imageCache.currentSizeBytes >> 20;
    // 1.4.5 F3: the same gate the level-20 trim already has — a
    // pressure callback on a full-tier device with comfortable RSS
    // drops the catalogs but keeps the guide (it just parsed at great
    // cost, and the store re-serves rows anyway). Genuine pressure on
    // low-end devices, and hot RSS anywhere, still shed everything.
    // The RSS watchdog and the low-end background shed are unchanged
    // (already gated on RSS / tier).
    final keepEpg = keepEpgOnComfortableMemory(
      isFullTier: !DevicePerformance.isLowEndHardware,
      rssBytes: rssBefore,
      rssHotThresholdBytes: DevicePerformance.watchdogThresholdBytes,
    );
    appLogger.w(
      keepEpg
          ? 'System memory pressure, evicting image caches + IPTV catalogs (keeping EPG)'
          : 'System memory pressure, evicting image caches + IPTV catalogs/EPG',
    );
    _evictImageCaches();
    // 1.2.4 (catalog memory, item 1): the memo heap + guide are the
    // actual hogs (the owner's Fold: RSS 700MB with the image cache at
    // 0–6MB) — shedding them here is what makes the pressure callback
    // do anything. Relief valve only: the next browse/search/guide
    // re-reads from disk, no network.
    if (keepEpg) {
      _serverManager.dropIptvCachesFromMemoryKeepEpg();
    } else {
      _serverManager.dropIptvCachesFromMemory();
    }
    final rssAfterMb = ProcessInfo.currentRss >> 20;
    final iptvStats = _serverManager.iptvMemoryStats();
    // 1.4 (F5): the RELIEF line goes out 3 s after the drop with the
    // post-GC reading — the synchronous after-number read 0 MB freed.
    _logReliefDelayed(
      src: 'trim',
      reason: 'memory-pressure',
      rssBeforeMb: rssBeforeMb,
      rssAfterMb: rssAfterMb,
      dropped: keepEpg ? 'iptv-catalogs+image-caches' : 'iptv-catalogs+epg+image-caches',
      memoDropped: true,
      epgWindowPrograms: iptvStats['retainedFeedPrograms'] as int?,
      epgCacheLen: iptvStats['epgCacheEntries'] as int?,
      imageCacheMbBefore: imageCacheMbBefore,
      imageCacheMbAfter: PaintingBinding.instance.imageCache.currentSizeBytes >> 20,
    );
    PhaseRssSampler.instance.sample('relief-trim');
  }

  /// 1.2.19 L-6: native `onTrimMemory`, forwarded by MpvPlayerPlugin over
  /// the device channel. Same drop path as the RSS watchdog (S-4), gated
  /// on the level by [evictionForTrimLevel] so spurious trims do not churn
  /// re-fetches. The full drop shares the watchdog's 60 s cooldown
  /// (re-evicting only if RSS kept climbing past the last eviction); the
  /// images-only drop has its own 30 s throttle. Telemetry mirrors S-4c
  /// so the debug export proves what the valve shed (rssAfter + IPTV
  /// stats). Device proof (`adb shell am send-trim-memory` during a feed
  /// parse) is UNPROVEN — name it in the delivery report.
  Future<dynamic> _handleDeviceChannelCall(MethodCall call) async {
    if (call.method == 'onTrimMemory') {
      final raw = (call.arguments as Map?)?['level'];
      final level = raw is num ? raw.toInt() : null;
      if (level != null) _onNativeTrimMemory(level);
      return true;
    }
    throw MissingPluginException(
      'No implementation found for method ${call.method} on com.plezy/device',
    );
  }

  void _onNativeTrimMemory(int level) {
    final eviction = evictionForTrimLevel(level);
    if (eviction == NativeTrimEviction.none) {
      appLogger.d('Native trim level $level: no eviction');
      return;
    }
    final now = DateTime.now();
    if (eviction == NativeTrimEviction.full) {
      final rss = ProcessInfo.currentRss;
      final inCooldown = now.difference(_lastRssEviction) < const Duration(seconds: 60);
      if (inCooldown && rss <= _lastEvictionRss) {
        appLogger.d('Native trim level $level: full drop skipped (cooldown, RSS ${rss >> 20}MB)');
        return;
      }
      _lastRssEviction = now;
      _lastEvictionRss = rss;
      // 1.3.24 §67 F4: a UI-hidden trim is not pressure — on a
      // full-tier device with comfortable RSS, drop the catalogs but
      // keep the guide (images still evicted below). Genuinely
      // critical trims and hot RSS take the full path underneath.
      if (keepEpgOnTrim(
        level: level,
        isFullTier: !DevicePerformance.isLowEndHardware,
        rssBytes: rss,
        rssHotThresholdBytes: DevicePerformance.watchdogThresholdBytes,
      )) {
        _serverManager.dropIptvCachesFromMemoryKeepEpg();
        final rssAfter = ProcessInfo.currentRss;
        final iptvStats = _serverManager.iptvMemoryStats();
        appLogger.w(
          'Native trim level $level, dropped IPTV catalogs from memory, kept EPG '
          '(rss ${rss >> 20}MB, rssAfter ${rssAfter >> 20}MB, '
          '${iptvStats.entries.map((e) => '${e.key}=${e.value}').join(' ')})',
        );
        _evictImageCaches();
        // 1.4 (F5): post-GC follow-up — the synchronous rssAfter
        // reads 0 MB freed before GC runs.
        _logNativeTrimDelayed(level: level, rssAfterMb: rssAfter >> 20);
        return;
      }
      _serverManager.dropIptvCachesFromMemory();
      final rssAfter = ProcessInfo.currentRss;
      final iptvStats = _serverManager.iptvMemoryStats();
      appLogger.w(
        'Native trim level $level, dropped IPTV catalogs + EPG from memory '
        '(rss ${rss >> 20}MB, rssAfter ${rssAfter >> 20}MB, '
        '${iptvStats.entries.map((e) => '${e.key}=${e.value}').join(' ')})',
      );
      _evictImageCaches();
      // 1.4 (F5): post-GC follow-up — the synchronous rssAfter
      // reads 0 MB freed before GC runs.
      _logNativeTrimDelayed(level: level, rssAfterMb: rssAfter >> 20);
      return;
    }
    if (now.difference(_lastTrimImageEviction) < const Duration(seconds: 30)) {
      appLogger.d('Native trim level $level: image eviction skipped (throttled)');
      return;
    }
    _lastTrimImageEviction = now;
    _evictImageCaches();
    appLogger.w('Native trim level $level, evicting image caches');
  }

  /// RSS-based image-cache eviction. Desktop keeps its fixed 1.5GB bar;
  /// Android scales to the device because LMK on a 2GB TV box kills well
  /// below any fixed desktop threshold — and Android trim callbacks
  /// ([didHaveMemoryPressure]) are best-effort, LMK can kill without ever
  /// delivering one (#1349).
  ///
  /// 1.2.19 L-8: the threshold + poll come from the per-tier table in
  /// [DevicePerformance.watchdogBudgetFor] — T0 260 MB/5 s, T1 330 MB/5 s,
  /// T2 450 MB/10 s, T3 600 MB/15 s, T4 today's 45%/30 s — so the valve
  /// fires *before* LMK instead of after (the old 45% fired at 645 MB on
  /// 1.5 GB, above the estimated kill band). The T0–T3 numbers are
  /// ESTIMATES until L-60 measures the Hisense's actual LMK kill line.
  /// The bind gate in `iptv_client.dart` reads the same table (half the
  /// watchdog); never duplicate the formula again.
  void _startRssWatchdog() {
    final int threshold;
    final Duration period;
    if (PlatformDetector.isDesktopOS()) {
      threshold = 1536 << 20; // 1.5GB
      period = const Duration(seconds: 30);
    } else if (Platform.isAndroid) {
      final budget = DevicePerformance.watchdogBudgetFor(DevicePerformance.currentTier);
      threshold = budget.thresholdBytes;
      // Decode bursts can spike RSS in seconds on low-end boxes; the read
      // itself is an in-process syscall, cheap enough for a short period.
      period = budget.pollInterval;
    } else {
      return; // iOS/tvOS: jetsam pressure arrives via didHaveMemoryPressure.
    }

    // 1.2.18 S-4a: a self-rescheduling one-shot timer, not a fixed
    // periodic — while a heavy IPTV job is in flight the poll runs
    // every 5 s, so a spike shorter than the idle poll (feed parse
    // ~25 s, sync isolate jobs, hub loads) is still seen; idle, the
    // normal period applies. The check reschedules itself on every
    // path, including the early returns.
    void checkAndReschedule() {
      final rss = ProcessInfo.currentRss;
      if (rss > threshold) {
        final cache = PaintingBinding.instance.imageCache;
        // Cooldown: refetch churn is its own memory-spike and jank
        // source. Inside the cooldown, re-evict only if RSS kept climbing
        // past the last eviction.
        final now = DateTime.now();
        final inCooldown = now.difference(_lastRssEviction) < const Duration(seconds: 60);
        if (!inCooldown || rss > _lastEvictionRss) {
          _lastRssEviction = now;
          _lastEvictionRss = rss;
          // 1.2.4 (catalog memory, item 1): the IPTV drop is NOT gated on
          // the image cache size — the owner's Fold hit RSS 700MB with the image
          // cache at 0–6MB, so the old ≥8MB floor let the memo heap (the
          // actual hog) ride out every watchdog trip. It shares the
          // cooldown gate above; the image eviction keeps its own ≥8MB
          // floor (clearing an already-small cache buys nothing).
          _serverManager.dropIptvCachesFromMemory();
          // 1.2.18 S-4c: RSS after the drop + the IPTV stats prove
          // what the valve shed.
          final rssAfter = ProcessInfo.currentRss;
          final iptvStats = _serverManager.iptvMemoryStats();
          appLogger.w(
            'RSS high (${rss >> 20}MB > ${threshold >> 20}MB), dropped IPTV catalogs + EPG from memory '
            '(rssAfter ${rssAfter >> 20}MB, ${iptvStats.entries.map((e) => '${e.key}=${e.value}').join(' ')})',
          );
          if (cache.currentSizeBytes >= (8 << 20)) {
            appLogger.w(
              'RSS high (${rss >> 20}MB > ${threshold >> 20}MB), evicting image caches '
              '(cache ${cache.currentSizeBytes >> 20}MB/${cache.currentSize} images, ${cache.liveImageCount} live)',
            );
            _evictImageCaches();
          }
          // L-55: the structured RELIEF line (one line, parseable by
          // the benchmark harness) — the after-number is read after
          // BOTH drops, so the freed total is the valve's whole trip.
          // 1.4 (F5): the line goes out 3 s after the drop with the
          // post-GC reading — the synchronous after-number read 0 MB
          // freed on both 1.3.29 trips.
          final rssAfterValve = ProcessInfo.currentRss;
          _logReliefDelayed(
            src: 'watchdog',
            reason: 'rss-high',
            rssBeforeMb: rss >> 20,
            rssAfterMb: rssAfterValve >> 20,
            dropped: 'iptv-catalogs+epg',
            memoDropped: true,
            epgWindowPrograms: iptvStats['retainedFeedPrograms'] as int?,
            epgCacheLen: iptvStats['epgCacheEntries'] as int?,
          );
          PhaseRssSampler.instance.sample('relief-watchdog');
        }
      }
      final heavy = IptvHeavyWorkGate.instance.isBusy;
      _memoryCheckTimer = Timer(heavy ? const Duration(seconds: 5) : period, checkAndReschedule);
    }

    checkAndReschedule();
  }

  void _evictImageCaches() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }

  /// 1.2.19 L-27 (+ L-18): re-assert the Dart display-mode settings on the
  /// native side after the first frame. The surface-render-mode flag is
  /// read by native getRenderMode() on the next cold start; the 1080p UI
  /// mode (L-18) is applied live when enabled. Best-effort: a missing
  /// native handler must never break startup.
  Future<void> _syncNativeDisplayModes() async {
    if (!Platform.isAndroid) return;
    try {
      final settings = await SettingsService.getInstance();
      if (!mounted) return;
      await AndroidDisplayModeService.setSurfaceRenderMode(
        settings.read(SettingsService.surfaceRenderMode),
      );
      if (PlatformDetector.isTV() && settings.read(SettingsService.ui1080pMode)) {
        await AndroidDisplayModeService.setUi1080pMode(true);
      }
    } catch (e, st) {
      appLogger.w('Failed to sync native display modes', error: e, stackTrace: st);
    }
  }

  /// Two connectivity-driven triggers, both listening on [OfflineModeProvider],
  /// which owns the app's single connectivity subscription:
  ///
  /// * [_autoDeleteAndSync] on each WiFi/Ethernet reconnect, so download rules
  ///   run as soon as the device is back on an unmetered link. Rapid flapping is
  ///   bounded by the executor's cooldown.
  /// * A tracker write-queue flush whenever the network comes back at all,
  ///   metered included: tracker history writes are internet calls, so they can
  ///   land while media servers are still unreachable and the app stays offline.
  void _startConnectivitySyncTrigger(DownloadProvider downloadProvider, OfflineModeProvider offlineModeProvider) {
    _removeConnectivitySyncListener();
    _lastConnectivityWasWifi = offlineModeProvider.hasWifiOrEthernet;
    _lastConnectivityHadNetwork = offlineModeProvider.hasNetworkConnection;
    _connectivitySyncProvider = offlineModeProvider;
    _connectivitySyncListener = () {
      final hasWifi = offlineModeProvider.hasWifiOrEthernet;
      final movedOntoWifi = hasWifi && !_lastConnectivityWasWifi;
      _lastConnectivityWasWifi = hasWifi;

      final hasNetwork = offlineModeProvider.hasNetworkConnection;
      final networkRestored = hasNetwork && !_lastConnectivityHadNetwork;
      _lastConnectivityHadNetwork = hasNetwork;

      if (networkRestored) {
        appLogger.d('Network restored — replaying queued tracker writes');
        unawaited(TrackerCoordinator.instance.flushWriteQueue());
      }
      if (movedOntoWifi) {
        appLogger.d('Connectivity moved onto WiFi/Ethernet — triggering sync pass');
        _autoDeleteAndSync(downloadProvider);
      }
    };
    offlineModeProvider.addListener(_connectivitySyncListener!);
  }

  void _removeConnectivitySyncListener() {
    final listener = _connectivitySyncListener;
    if (listener != null) _connectivitySyncProvider?.removeListener(listener);
    _connectivitySyncListener = null;
    _connectivitySyncProvider = null;
  }

  /// Run auto-delete (if enabled) and then a sync-rule pass.
  ///
  /// When [targetKeys] is non-null, only those rules are re-evaluated
  /// (cooldown doesn't apply — targeted runs are always "we know this
  /// changed"). When null, every rule runs via the executor, with [force]
  /// gating the cooldown: `true` for user-initiated drains, `false` for
  /// background probes like a connectivity reconnect.
  Future<void> _autoDeleteAndSync(
    DownloadProvider downloadProvider, {
    List<String>? targetKeys,
    bool force = false,
  }) async {
    // Exit teardown awaits the pass in flight before closing the database; a
    // pass started after that would query a closed database (#3012).
    if (_shutdownFuture != null) return;
    if (_autoDeleteRun != null) {
      if (targetKeys != null) _pendingSyncKeys.addAll(targetKeys);
      return;
    }
    final run = _autoDeleteRun = Completer<void>();
    try {
      await downloadProvider.refreshMetadataFromCache();
      final activeGlobalKey = VideoPlayerScreenState.activeGlobalKey;
      final settings = SettingsService.instanceOrNull;
      if (settings != null && settings.read(SettingsService.autoRemoveWatchedDownloads)) {
        final deleted = await downloadProvider.autoDeleteWatchedDownloads(activeGlobalKey: activeGlobalKey);
        if (deleted.isNotEmpty) {
          final msg = deleted.length == 1
              ? t.messages.autoRemovedWatchedDownload(title: deleted.first)
              : t.messages.autoRemovedWatchedDownloads(n: deleted.length);
          showMainSnackBar(msg);
        }
      }

      if (targetKeys != null) {
        for (final key in targetKeys) {
          if (!downloadProvider.hasSyncRule(key)) continue;
          final result = await downloadProvider.executeSyncRuleFor(key, _serverManager);
          if (result != null && result.queuedCount > 0) {
            final title = result.title ?? t.common.unknown;
            showMainSnackBar(t.downloads.syncedNewEpisodes(count: '1', title: '$title (${result.queuedCount})'));
          }
        }
      } else {
        final synced = await downloadProvider.executeSyncRules(_serverManager, force: force);
        if (synced.isNotEmpty) {
          showMainSnackBar(t.downloads.syncedNewEpisodes(count: synced.length.toString(), title: synced.first));
        }
      }
    } finally {
      _autoDeleteRun = null;
      run.complete();
      if (_pendingSyncKeys.isNotEmpty) {
        final queuedKeys = _pendingSyncKeys.toList();
        _pendingSyncKeys.clear();
        unawaited(_autoDeleteAndSync(downloadProvider, targetKeys: queuedKeys));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // App came back to foreground - trigger sync check
        _offlineWatchSyncService.onAppResumed();
        unawaited(TrackerCoordinator.instance.flushWriteQueue());
        // Re-arm the per-server library push channels torn down on pause
        // (and any that exhausted their reconnect attempts).
        _libraryEventService.resume();
        // Re-probe servers — mobile OS may have dropped TCP connections during doze/sleep.
        // On desktop, resumed fires on every window focus (alt-tab), so apply a cooldown
        // to avoid piling up network probes from rapid alt-tabbing.
        final now = DateTime.now();
        final cooldown = (Platform.isIOS || Platform.isAndroid)
            ? const Duration(seconds: 10)
            : const Duration(minutes: 2);
        if (now.difference(_lastResumeProbe) >= cooldown) {
          _lastResumeProbe = now;
          // Await health check before reconnecting so stale "online" servers
          // get marked offline and included in the reconnection sweep. Servers
          // that stayed online but were failed over onto a remote endpoint
          // while local ones exist get re-raced: a same-interface sleep/wake
          // never fires the connectivity event that would otherwise do it.
          unawaited(() async {
            await _serverManager.checkServerHealth();
            await _serverManager.reconnectOfflineServers();
            await _serverManager.reoptimizeDemotedServers(reason: 'resume');
          }());
        }
        // Build v1.0.13 (R4.2): the app was backgrounded — the catalog
        // may be due for its interval sync. The check is the existing
        // coalesced sync: 0 requests when up-to-date, and it yields when
        // the background job is already syncing. Not gated on the probe
        // cooldown above (a sync is cheaper than a probe and the engine
        // due-checks). Not run at startup — only on a resume after a
        // background trip.
        if (_wasBackgrounded) {
          _wasBackgrounded = false;
          unawaited(_serverManager.ensureIptvSearchIndexesSynced());
        }
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // Build v1.0.13 (R4.2): the next resume runs the catalog
        // due-check. Registration of the background job is untouched
        // here (D7) — pausing the app must never cancel the job.
        _wasBackgrounded = true;
        // Backgrounded: drop the library push sockets — they are
        // foreground-only, and the stale-resume refresh covers the gap.
        _libraryEventService.suspend();
        // Backgrounded: stop talking to the IPTV panel — cancel any
        // search in flight (build #21, close-after-use). The user has
        // walked away; the sweep would otherwise keep fetching
        // categories for up to 50s for a search nobody is watching.
        // The connections stay usable — only the in-flight searches
        // are cancelled, and the resume path re-probes and reconnects.
        _serverManager.cancelActiveIptvSearches();
        // Build #28: background work too — the weekly index sync, the
        // stale-disk catalog refreshes, and the in-flight EPG fetches.
        // A sync parked on playback (or a feed download nobody watches)
        // stops instead of running to completion in the background.
        _serverManager.cancelActiveIptvBackgroundWork();
        // 1.2.19, L-14: on T0–T2 the background shed is unconditional —
        // drop memos + EPG + image caches synchronously when
        // backgrounded, so the app is not LMK-killed while backgrounded
        // holding its catalog. The next launch re-reads from disk/index
        // (no network); the trade is a cold-ish next launch for not
        // being killed while backgrounded. T3+ keeps the RSS-gated
        // image-cache eviction below. Same pair as didHaveMemoryPressure.
        if (DevicePerformance.shedCachesOnBackground) {
          _evictImageCaches();
          _serverManager.dropIptvCachesFromMemory();
        }
        // Database is session-scoped and must survive suspend/resume.
        // Closing here would kill the Drift isolate channel while services
        // (sync, downloads, cache) still hold references to the executor.
        // SQLite WAL mode handles process death; desktop uses onExitRequested.
        if (PlatformDetector.isDesktopOS()) {
          if (ProcessInfo.currentRss > 1024 * 1024 * 1024) {
            // 1GB
            _evictImageCaches();
          }
        } else if (Platform.isAndroid) {
          // A backgrounded app is LMK's first candidate; shed the image
          // caches at a lower bar than the foreground watchdog to survive
          // the HOME press on low-RAM boxes.
          final totalMem = DevicePerformance.totalMemBytes;
          final bar = totalMem != null ? (totalMem * 0.35).round() : 768 << 20;
          if (ProcessInfo.currentRss > bar) {
            _evictImageCaches();
          }
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        // Transitional states - don't trigger session events
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Expose AppDatabase + ConnectionRegistry so screens (Settings, Setup)
        // can manage stored Jellyfin/Plex connections without re-creating
        // the registry per-call site.
        Provider<SettingsService>.value(value: widget.settings),
        Provider<StorageService>.value(value: widget.storage),
        Provider<AppDatabase>.value(value: _appDatabase),
        Provider<ConnectionRegistry>.value(value: _connections),
        Provider<ProfileRegistry>(create: (_) => ProfileRegistry(_appDatabase)),
        Provider<ProfileConnectionRegistry>.value(value: _profileConnections),
        Provider<PlexHomeService>.value(value: _plexHomeService),
        ChangeNotifierProvider<ActiveProfileProvider>(
          create: (context) {
            final provider = ActiveProfileProvider(
              registry: context.read<ProfileRegistry>(),
              plexHome: context.read<PlexHomeService>(),
              connections: context.read<ConnectionRegistry>(),
              profileConnections: context.read<ProfileConnectionRegistry>(),
              storage: context.read<StorageService>(),
            );
            unawaited(provider.initialize());
            return provider;
          },
        ),
        ChangeNotifierProvider(
          create: (context) {
            _serverManager.onJellyfinConnectionUpdated = context.read<ConnectionRegistry>().upsert;
            return MultiServerProvider(_serverManager, _aggregationService);
          },
        ),
        ChangeNotifierProxyProvider<MultiServerProvider, OfflineModeProvider>(
          create: (context) {
            final provider = OfflineModeProvider(
              _serverManager,
              multiServerProvider: context.read<MultiServerProvider>(),
            );
            provider.initialize(); // Initialize immediately so statusStream listener is ready
            return provider;
          },
          update: (_, multiServerProvider, previous) {
            final provider = previous!;
            provider.updateMultiServerProvider(multiServerProvider);
            provider.initialize(); // Idempotent - safe to call again
            return provider;
          },
        ),
        // Profile binder owns the cold-start client connect: Plex token
        // refresh + Jellyfin client creation. Hoisted out of MainScreen so
        // the splash can await its first settle — without this, MainScreen
        // mounts (and discover/libraries query) before any client exists.
        // It is intentionally not auto-started here: SetupScreen starts it
        // once the active profile is hydrated and the OS connectivity check
        // has chosen the initial bind's PIN policy.
        Provider<ActiveProfileBinder>(
          lazy: false,
          create: (context) {
            final activeProfile = context.read<ActiveProfileProvider>();
            return ActiveProfileBinder(
              activeProfile: activeProfile,
              connections: context.read<ConnectionRegistry>(),
              profileConnections: context.read<ProfileConnectionRegistry>(),
              serverManager: _serverManager,
              multiServerProvider: context.read<MultiServerProvider>(),
              pinPrompt: _rootPinPrompt,
              shouldDeferInitialBind: (profile) async {
                // A launch link that names another profile replaces this bind.
                final linkProfileId = DeepLinkService.instance.startupProfileId;
                if (linkProfileId != null) return profile.id != linkProfileId;
                final settings = await SettingsService.getInstance();
                return activeProfile.requiresSelectionOnOpen(settings);
              },
            );
          },
          dispose: (_, binder) => binder.dispose(),
        ),
        // Download provider. Downloads are shared, but sync rules are scoped to
        // the active profile and reload when the profile changes.
        ChangeNotifierProxyProvider<ActiveProfileProvider, DownloadProvider>(
          create: (context) => DownloadProvider(downloadManager: _downloadManager, database: _appDatabase),
          update: (context, activeProfile, previous) {
            final provider = previous!;
            provider.setActiveProfileId(activeProfile.activeId);
            return provider;
          },
        ),
        ChangeNotifierProxyProvider<ActiveProfileProvider, OfflineWatchSyncService>(
          create: (context) {
            final offlineModeProvider = context.read<OfflineModeProvider>();
            final downloadProvider = context.read<DownloadProvider>();
            final activeProfile = context.read<ActiveProfileProvider>();
            _offlineWatchSyncService.setActiveProfileId(
              activeProfile.activeId,
              // Legacy-adoption gate: only trust the count once the provider
              // has hydrated (locals + cached home users) — a transient
              // count of 1 mid-load would permanently mis-adopt pre-profile
              // watch actions.
              availableProfileCount: activeProfile.isInitialized ? activeProfile.profiles.length : null,
            );

            // Offline-sync drain replays a batch of queued watch actions without
            // per-item data, so we can't target rules — force a full pass.
            _offlineWatchSyncService.onWatchStatesRefreshed = () async {
              await _autoDeleteAndSync(downloadProvider, force: true);
            };

            // In-session watch events carry the episode's parent chain, so we
            // only re-evaluate rules that actually cover the watched item —
            // leaves unrelated collection/playlist rules alone. Debounced so
            // binge-watching coalesces into one pass.
            _watchStateSubscription = WatchStateNotifier().stream.listen((event) {
              if (event.changeType != WatchStateChangeType.watched) return;
              if (VideoPlayerScreenState.activeGlobalKey == event.globalKey) return;

              _pendingSyncKeys.addAll(downloadProvider.syncRuleKeysForWatchEvent(event));

              _syncDebounce?.cancel();
              _syncDebounce = Timer(const Duration(seconds: 5), () {
                final keys = _pendingSyncKeys.toList();
                _pendingSyncKeys.clear();
                _autoDeleteAndSync(downloadProvider, targetKeys: keys);
              });
            });

            _startConnectivitySyncTrigger(downloadProvider, offlineModeProvider);

            // Thread the offline flag into services so queue/resume paths can
            // short-circuit instead of hitting the network and failing.
            downloadProvider.setOfflineSource(offlineModeProvider);

            _offlineWatchSyncService.startConnectivityMonitoring(offlineModeProvider);
            return _offlineWatchSyncService;
          },
          update: (_, activeProfile, previous) {
            final provider = previous!;
            provider.setActiveProfileId(
              activeProfile.activeId,
              availableProfileCount: activeProfile.isInitialized ? activeProfile.profiles.length : null,
            );
            return provider;
          },
        ),
        ChangeNotifierProxyProvider2<OfflineWatchSyncService, DownloadProvider, OfflineWatchProvider>(
          create: (context) => OfflineWatchProvider(
            syncService: context.read<OfflineWatchSyncService>(),
            downloadProvider: context.read<DownloadProvider>(),
          ),
          update: (_, syncService, downloadProvider, previous) => previous!,
        ),
        // Account preferences (server-stored: Jellyfin UserConfiguration,
        // plex.tv user profile) live above the profile session so a write
        // survives navigation, and so a profile switch clears the cache in one
        // place. The repository is exposed separately because UI reads it
        // directly; the controller owns and disposes it.
        ChangeNotifierProxyProvider2<ActiveProfileProvider, ConnectionRegistry, AccountPreferencesController>(
          create: (_) => AccountPreferencesController(),
          update: (context, activeProfile, connections, previous) {
            final controller = previous!;
            controller.attach(
              connections: connections,
              profileConnections: context.read<ProfileConnectionRegistry>(),
              activeProfile: activeProfile,
              serverManager: context.read<MultiServerProvider>().serverManager,
            );
            return controller;
          },
        ),
        ProxyProvider<AccountPreferencesController, AccountPreferencesRepository>(
          update: (_, controller, _) => controller.repository,
        ),
        // App-global: a Supporter purchase belongs to the store account on this
        // device, not to a profile.
        ChangeNotifierProvider(
          create: (context) {
            final supporter = SupporterService();
            unawaited(supporter.init());
            return supporter;
          },
        ),
        ChangeNotifierProvider(create: (context) => ThemeProvider(supporter: context.read<SupporterService>())),
        // Shader presets are app-global — deliberately outside the
        // profile-scoped session in ProfileSessionScreen.
        ChangeNotifierProvider(create: (context) => ShaderProvider()),
        // Created eagerly: it must be listening when a Supporter refund is
        // confirmed, so the default app icon comes back even with Settings closed.
        ChangeNotifierProvider(
          lazy: false,
          create: (context) {
            final appIcons = AppIconService(supporter: context.read<SupporterService>());
            unawaited(appIcons.refresh());
            return appIcons;
          },
        ),
      ],
      child: _AppShell(databaseRecoveryOutcome: widget.databaseRecoveryOutcome),
    );
  }
}

/// App-global shell: theme consumer, translations, root input handling, and the
/// root MaterialApp. Profile-scoped providers/navigation live in
/// [ProfileSessionScreen], not here, so root auth/PIN/global dialogs survive a
/// profile switch.
class _AppShell extends StatelessWidget {
  const _AppShell({required this.databaseRecoveryOutcome});

  final TvosDatabaseRecoveryOutcome databaseRecoveryOutcome;

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return TranslationProvider(
          child: Builder(
            builder: (context) {
              return Listener(
                onPointerDown: (event) {
                  if ((event.buttons & kBackMouseButton) != 0) {
                    unawaited(() async {
                      final rootNavigator = rootNavigatorKey.currentState;
                      if (rootNavigator?.canPop() ?? false) {
                        await rootNavigator?.maybePop();
                        return;
                      }
                      await profileNavigationRegistry.maybePopProfileRoute();
                    }());
                  }
                },
                behavior: HitTestBehavior.translucent,
                child: InputModeTracker(
                  child: MaterialApp(
                    title: t.app.title,
                    debugShowCheckedModeBanner: false,
                    // Quest laser pointer (mouse-kind) drags scroll, like touch.
                    scrollBehavior: const AppScrollBehavior(),
                    // The app language, not Flutter's en-US default: every
                    // Text inherits it as the locale that selects CJK glyph
                    // forms, and Material's own strings follow it.
                    locale: TranslationProvider.of(context).locale.localizationsLocale,
                    supportedLocales: supportedLocalizationsLocales,
                    localizationsDelegates: GlobalMaterialLocalizations.delegates,
                    theme: themeProvider.lightTheme,
                    darkTheme: themeProvider.darkTheme,
                    themeMode: themeProvider.materialThemeMode,
                    navigatorKey: rootNavigatorKey,
                    navigatorObservers: [BackKeySuppressorObserver()],
                    home: SetupScreen(databaseRecoveryOutcome: databaseRecoveryOutcome),
                    // Siri Remote select + gamepad A report as
                    // LogicalKeyboardKey.{select,gameButtonA} which aren't
                    // in Flutter's default shortcut set — Material-level
                    // widgets (menu items, showModalBottomSheet actions)
                    // ignore them. Map both to ActivateIntent so tapping
                    // select on tvOS activates the focused widget.
                    shortcuts: <ShortcutActivator, Intent>{
                      ...WidgetsApp.defaultShortcuts,
                      const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
                      const SingleActivator(LogicalKeyboardKey.gameButtonA): const ActivateIntent(),
                      const SingleActivator(LogicalKeyboardKey.goBack): const DismissIntent(),
                      const SingleActivator(LogicalKeyboardKey.browserBack): const DismissIntent(),
                      const SingleActivator(LogicalKeyboardKey.gameButtonB): const DismissIntent(),
                    },
                    builder: (context, child) {
                      // 1.2.19, L-49: clamp the text scaler — a system
                      // text scale above ~1.3x breaks the guide layout
                      // on TV (1.5x on phone). The user's font-size
                      // choice is respected up to the cap.
                      final shell = MediaQuery.withClampedTextScaling(
                        maxScaleFactor: clampedTextScaleCap(isTv: PlatformDetector.isTV()),
                        child: rootShell(child),
                      );
                      if (!agentControlEnabled) return shell;
                      return AgentControlScope(
                        commandContext: () => rootNavigatorKey.currentState?.overlay?.context,
                        child: shell,
                      );
                    },
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// The root shell every route renders inside.
///
/// The form-factor scale sits above the messenger and its root [Scaffold], not inside them:
/// Flutter presents a messenger's snackbars on the rootmost registered scaffold, so anything
/// below would leave global snackbars at the car's native density while the rest of the
/// interface grew.
/// 1.2.19, L-49: the text-scale cap — 1.3x on TV, 1.5x on phone. A
/// system text scale above the cap breaks the guide layout; the user's
/// font-size choice is respected up to the cap. Applied in the
/// MaterialApp builder via [MediaQuery.withClampedTextScaling].
@visibleForTesting
double clampedTextScaleCap({required bool isTv}) => isTv ? 1.3 : 1.5;

Widget rootShell(Widget? child) {
  return AppSystemUiStyle(
    child: IphoneDuoScope(
      child: FormFactorScale(
        child: ScaffoldMessenger(
          key: rootScaffoldMessengerKey,
          child: Scaffold(backgroundColor: Colors.transparent, body: child),
        ),
      ),
    ),
  );
}

/// Apple TV receives a full-HD logical surface, while Android Automotive can
/// report a very low display density. Both make otherwise comfortable controls
/// physically too small, so render through a smaller, self-consistent logical
/// viewport and scale the result back to the physical surface.
class FormFactorScale extends StatelessWidget {
  final Widget? child;
  const FormFactorScale({super.key, required this.child});

  static const double _appleTvScale = 2.0;

  @override
  Widget build(BuildContext context) {
    final child = this.child;
    if (child == null) return const SizedBox.shrink();

    // Keep the existing Apple TV path independent of settings so its 2×
    // behavior and overscan handling remain unchanged.
    if (PlatformDetector.isAppleTV()) {
      return _scaledSurface(child: child, scale: _appleTvScale, zeroInsets: true);
    }
    if (!PlatformDetector.isAutomotive()) return child;

    // Car system bars can sit on the left or right, are opaque, and may be
    // impossible to hide (OEM policy). Nothing is worth drawing under them,
    // and the mobile screens only honour top/bottom insets, so consume the
    // horizontal ones here, once, for every route (car app quality AR-1).
    // Inside the scaled MediaQuery so the SafeArea reads the scaled padding.
    final insetChild = SafeArea(top: false, bottom: false, child: child);
    return SettingValueBuilder<double>(
      pref: SettingsService.automotiveUiScale,
      builder: (context, scale, _) => _scaledSurface(child: insetChild, scale: scale, zeroInsets: false),
    );
  }

  Widget _scaledSurface({required Widget child, required double scale, required bool zeroInsets}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final logicalSize = Size(constraints.maxWidth / scale, constraints.maxHeight / scale);
        final outerQ = MediaQuery.of(context);
        // tvOS reports conservative overscan insets (~60pt top/bottom,
        // ~90pt left/right). Modern TVs don't overscan, so treat them as
        // dead margin and zero them out — the UI can use the full surface.
        //
        // Automotive system bars are real touch-exclusion regions. Preserve
        // their physical size in the scaled coordinate system so SafeArea
        // continues to keep controls out from underneath them.
        return Transform.scale(
          scale: scale,
          alignment: .topLeft,
          transformHitTests: true,
          // Align loosens what it passes down. Without it a tight incoming constraint — which is
          // what the app's root hands its builder — forces the SizedBox back to the full surface,
          // and the transform then only magnifies a full-size layout instead of rendering a
          // smaller one into the same space.
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: logicalSize.width,
              height: logicalSize.height,
              child: MediaQuery(
                data: outerQ.copyWith(
                  size: logicalSize,
                  devicePixelRatio: outerQ.devicePixelRatio * scale,
                  padding: zeroInsets ? .zero : outerQ.padding * (1 / scale),
                  viewPadding: zeroInsets ? .zero : outerQ.viewPadding * (1 / scale),
                  viewInsets: zeroInsets ? .zero : outerQ.viewInsets * (1 / scale),
                  systemGestureInsets: zeroInsets ? .zero : outerQ.systemGestureInsets * (1 / scale),
                ),
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

@visibleForTesting
bool shouldBypassSetupForDatabaseRecovery(TvosDatabaseRecoveryOutcome outcome) {
  return outcome == TvosDatabaseRecoveryOutcome.recoveryRequired;
}

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.databaseRecoveryOutcome,
    this.initializeAuthServices = true,
    this.debugRecoveryRequiredRouter,
  });

  final TvosDatabaseRecoveryOutcome databaseRecoveryOutcome;
  final bool initializeAuthServices;
  @visibleForTesting
  final FutureOr<void> Function(BuildContext context, String message)? debugRecoveryRequiredRouter;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> with MountedSetStateMixin {
  String _statusMessage = '';
  bool _enteringOffline = false;

  // Per-server connection status: serverId -> (name, connected?)
  final Map<String, (String name, bool? connected)> _serverStatus = {};

  /// When the bind started, for the per-server "Contacting … Ns" label
  /// (1.2.19, L-22) — a hung bind shows which server is still pending
  /// and for how long, instead of a silent spinner.
  DateTime? _bindStartedAt;

  /// Ticks once a second while any server is still pending, so the
  /// elapsed label above keeps counting. Cancelled once every server
  /// has settled, or when the splash goes away.
  Timer? _bindElapsedTimer;

  void _startBindElapsedTimer() {
    _bindElapsedTimer?.cancel();
    _bindElapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        _stopBindElapsedTimer();
        return;
      }
      if (_serverStatus.values.every((status) => status.$2 != null)) {
        _stopBindElapsedTimer();
        return;
      }
      setStateIfMounted(() {});
    });
  }

  void _stopBindElapsedTimer() {
    _bindElapsedTimer?.cancel();
    _bindElapsedTimer = null;
  }

  int get _bindElapsedSeconds {
    final startedAt = _bindStartedAt;
    if (startedAt == null) return 0;
    return DateTime.now().difference(startedAt).inSeconds;
  }

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
    // The app's first screen: undo any orientation lock a previous run's
    // full-screen player left behind.
    unawaited(OrientationHelper.restoreDefaultOrientations());
  }

  void _setStatus(String message) {
    setStateIfMounted(() => _statusMessage = message);
  }

  Future<void> _enterOfflineMode({bool initialPromptHandled = false}) async {
    if (_enteringOffline) return;
    _enteringOffline = true;
    _setStatus(t.common.startingOfflineMode);
    await context.read<DownloadProvider>().ensureInitialized();
    if (!mounted) return;
    AndroidExitDiagnostics.markStartupPhase(AndroidStartupPhase.mainScreen);
    unawaited(
      Navigator.pushReplacement(
        context,
        fadeRoute(ProfileSessionScreen(isOfflineMode: true, initialPromptHandled: initialPromptHandled)),
      ),
    );
  }

  Future<void> _loadSavedCredentials() async {
    if (shouldBypassSetupForDatabaseRecovery(widget.databaseRecoveryOutcome)) {
      final message = t.auth.localDataRecoveryRequired;
      final debugRouter = widget.debugRecoveryRequiredRouter;
      if (debugRouter != null) {
        await Future.sync(() => debugRouter(context, message));
        return;
      }
      await Future<void>.delayed(Duration.zero);
      if (mounted) {
        unawaited(
          Navigator.pushReplacement(
            context,
            fadeRoute(
              AuthScreen(
                initialErrorMessage: message,
                initializeServices: widget.initializeAuthServices,
                databaseRecoveryRequired: true,
              ),
            ),
          ),
        );
      }
      return;
    }

    _setStatus(t.common.checkingNetwork);

    final storage = await StorageService.getInstance();
    final registry = ServerRegistry(storage);

    // Idempotent: brings legacy SharedPreferences state (plexToken,
    // currentUserUUID, homeUsersCache) into the new ConnectionRegistry +
    // ProfileRegistry tables. No-op on subsequent launches.
    if (mounted) {
      try {
        final connRegistry = context.read<ConnectionRegistry>();
        final profileConnections = context.read<ProfileConnectionRegistry>();
        final profileRegistry = context.read<ProfileRegistry>();
        final activeProfiles = context.read<ActiveProfileProvider>();
        final serverManager = context.read<MultiServerProvider>().serverManager;
        final bootstrap = ConnectionBootstrap(
          storage: storage,
          connectionRegistry: connRegistry,
          serverRegistry: registry,
          profileRegistry: profileRegistry,
          plexHome: context.read<PlexHomeService>(),
        );
        await bootstrap.run();
        final pruned = await ProfileConnectionCleanup(
          profileConnections: profileConnections,
          connections: connRegistry,
          storage: storage,
          serverManager: serverManager,
        ).pruneUnreferencedJellyfinConnections();
        if (pruned > 0) {
          appLogger.i('Setup: pruned $pruned unreferenced MediaBrowser connection${pruned == 1 ? '' : 's'}');
        }
        // Provider initialization starts before this screen runs the legacy
        // migration. Reload after bootstrap so copied Plex Home users and the
        // selected active profile are visible before setup decides binding is
        // already settled and navigates to MainScreen.
        await activeProfiles.reloadFromStorage();
      } catch (e, st) {
        appLogger.w('Boot-time migration failed', error: e, stackTrace: st);
      }
    }

    // OS connectivity only bounds how long the splash waits for the bind
    // below. It never skips connecting: `none` means "no internet-capable
    // adapter", and a loopback or LAN-without-WAN server is still reachable
    // (#2505).
    unawaited(Sentry.addBreadcrumb(Breadcrumb(message: 'Checking network connectivity', category: 'setup')));
    final hasNetwork = !(await ConnectivityProbe.check()).contains(ConnectivityResult.none);

    unawaited(
      Sentry.addBreadcrumb(Breadcrumb(message: 'Network check done: hasNetwork=$hasNetwork', category: 'setup')),
    );

    _setStatus(t.common.loadingServers);

    if (!mounted) return;

    // Snapshot ConnectionRegistry before we cross any awaits — Provider lookups
    // through `context` after async gaps trip the use_build_context_synchronously
    // lint, and reading early is safe because the registry is a singleton.
    final connectionRegistry = context.read<ConnectionRegistry>();
    final List<Connection> allConnections;
    try {
      allConnections = await connectionRegistry.list();
      AndroidExitDiagnostics.markStartupPhase(AndroidStartupPhase.credentialsLoaded);
    } catch (e, st) {
      // Defence-in-depth: a DB-open failure here used to propagate
      // uncaught and strand the splash forever (#1022). Route to auth so
      // the user is never trapped; the log line above is the record —
      // there is no crash reporter any more (1.2.22 §66 U4).
      // regression doesn't go silent.
      appLogger.e('Setup: failed to load connections; returning to auth', error: e, stackTrace: st);
      if (mounted) {
        unawaited(Navigator.pushReplacement(context, fadeRoute(const AuthScreen())));
      }
      return;
    }

    if (allConnections.isEmpty) {
      if (mounted) {
        unawaited(Navigator.pushReplacement(context, fadeRoute(const AuthScreen())));
      }
      return;
    }

    if (!mounted) return;

    if (mounted) {
      setState(() {
        for (final conn in allConnections) {
          if (conn is PlexAccountConnection) {
            for (final s in conn.servers) {
              _serverStatus[s.clientIdentifier] = (s.name, null);
            }
          } else if (conn is JellyfinConnection) {
            _serverStatus[conn.serverMachineId] = (conn.serverName, null);
          }
        }
      });
    }

    final plexCount = allConnections.whereType<PlexAccountConnection>().fold<int>(0, (n, c) => n + c.servers.length);
    final mediaBrowserCount = allConnections.whereType<JellyfinConnection>().length;
    unawaited(
      Sentry.addBreadcrumb(
        Breadcrumb(
          message: 'Handing off to MainScreen with $plexCount Plex + $mediaBrowserCount MediaBrowser server(s)',
          category: 'setup',
        ),
      ),
    );
    _setStatus(t.common.connectingToServers);

    // Snapshot Provider refs before further awaits.
    final activeProfile = context.read<ActiveProfileProvider>();
    // The Provider is `lazy: false` so the binder is constructed already, but
    // SetupScreen starts it only after the active profile has been hydrated.
    final binder = context.read<ActiveProfileBinder>();
    final downloadProvider = context.read<DownloadProvider>();

    // Wait for the active profile to load from disk so the binder has a
    // profile to bind. `initialize` is fire-and-forget at provider creation,
    // so awaiting here pulls control through the same future and triggers
    // the listener-driven rebind synchronously.
    await activeProfile.reloadFromStorage();
    if (!mounted) return;

    if (activeProfile.active == null && activeProfile.profiles.isEmpty) {
      appLogger.w('Setup: stored connections exist but no profiles resolved after bootstrap; returning to auth');
      unawaited(Navigator.pushReplacement(context, fadeRoute(const AuthScreen())));
      return;
    }

    // Wire the per-server status listener before either branch so the splash
    // checkmarks fill in even while the user is choosing a profile.
    _bindServerStatusListener();

    // A launch link that names a profile chooses it, in place of both the
    // previously active profile (the binder defers that bind, see
    // `shouldDeferInitialBind`) and the profile picker. A protected profile
    // still asks for its PIN; backing out drops the link and, since nothing
    // is bound, shows the picker.
    final deepLinks = DeepLinkService.instance;
    await deepLinks.fetchInitialLink();
    if (!mounted) return;
    final linkProfile = deepLinks.claimStartupProfile(activeProfile.profiles);
    final linkSwitches = linkProfile != null && linkProfile.id != activeProfile.activeId;
    var linkApplied = linkProfile != null && !linkSwitches;
    try {
      // Start only after the active profile snapshot is hydrated. Without a
      // network the initial bind stays PIN-free: plex.tv cannot verify a PIN,
      // and the capped wait below would navigate out from under the dialog.
      AndroidExitDiagnostics.markStartupPhase(AndroidStartupPhase.bindingStarted);
      // 1.2.19, L-15/L-22: one unified startup deadline for the splash cap
      // + MainScreen's settle fallback (per-tier: T0 8 s, T1 10 s, T2+ 15 s),
      // and the bind-phase mark the saver counter reads back — a death
      // while 'binding' with no fatal record is a hung-bind force-stop,
      // not a crash.
      StartupDeadlineTracker.start(DevicePerformance.splashBindCapFor(DevicePerformance.currentTier));
      LastCrashStore.markStartupPhase(LastCrashStore.startupPhaseBinding);
      _bindStartedAt = DateTime.now();
      _startBindElapsedTimer();
      binder.start(allowInitialPinPrompt: hasNetwork);

      if (linkSwitches) {
        // Waits for the profile's bind, like the picker's switch.
        linkApplied = await switchProfileFromUi(context, linkProfile);
        if (!mounted) return;
      }

      // If "prompt for profile on launch" is on (or no profile is selected
      // yet), surface the picker BEFORE waiting for the previously-active
      // profile's bind to settle — otherwise the user sees the splash fully
      // connect before the prompt arrives. The picker's own `_switchTo` calls
      // `awaitBindingSettle` after activation, so by the time it pops, the
      // chosen profile's bind is settled.
      final settings = await SettingsService.getInstance();
      if (!mounted) return;
      final hasNoActive = activeProfile.active == null && activeProfile.profiles.isNotEmpty;
      final shouldPrompt =
          !linkApplied && (linkSwitches || hasNoActive || activeProfile.requiresSelectionOnOpen(settings));

      var bindingSucceeded = activeProfile.lastBindingSucceeded;
      if (shouldPrompt) {
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const ProfileSwitchScreen(requireSelection: true)));
        if (!mounted) return;
        bindingSucceeded = activeProfile.active != null && activeProfile.lastBindingSucceeded;
      } else if (!linkSwitches) {
        // Now wait for the binder to settle. This is the media-server client
        // race: per-server status flips on the splash list as each client comes
        // online, and we don't push MainScreen until they're all done (success
        // or fail). Eliminates the "Failed to load discover content: No servers
        // available" race the old eager-navigate flow caused. The wait is
        // capped in both branches (15 s with a network, 2 s without) so a
        // slow panel cannot hold the splash indefinitely; a cap expiry with
        // the binder still running routes to MainScreen, not the offline
        // shell (see shouldProceedToMainScreenAfterStartupBind).
        bindingSucceeded = await awaitStartupBindSettle(activeProfile.awaitBindingSettle(), hasNetwork: hasNetwork);
        if (!mounted) return;
      }
      AndroidExitDiagnostics.markStartupPhase(AndroidStartupPhase.bindingSettled);
      LastCrashStore.markStartupPhase(LastCrashStore.startupPhaseSettled);
      _stopBindElapsedTimer();
      // L-52: the bind is a named slow op (threshold 5 s). Silence is
      // the pass signal — a fast bind logs nothing.
      final bindStartedAt = _bindStartedAt;
      if (bindStartedAt != null) {
        SlowOpLog.instance.record(
          'bind',
          DateTime.now().difference(bindStartedAt).inMilliseconds,
        );
        _bindStartedAt = null;
      }

      // R5: a cap expiry with the binder still running is a slow bind, not
      // a failed one — the launch stays online and MainScreen's composite
      // offline verdict flips to the offline shell by itself if the bind
      // ultimately fails with zero servers online.
      if (!shouldProceedToMainScreenAfterStartupBind(
        bindingSucceeded: bindingSucceeded,
        hasOnlineServers: _serverManagerFromContext().onlineServerIds.isNotEmpty,
        bindStillRunning: activeProfile.isBinding,
        hasNetwork: hasNetwork,
      )) {
        appLogger.w('Setup: no servers online after startup bind; starting offline mode');
        await _enterOfflineMode(initialPromptHandled: linkApplied);
        return;
      }

      AndroidExitDiagnostics.markStartupPhase(AndroidStartupPhase.mainScreen);
      unawaited(
        Navigator.pushReplacement(
          context,
          fadeRoute(ProfileSessionScreen(initialPromptHandled: shouldPrompt || linkApplied)),
        ),
      );

      // R5.2: repopulate metadata for downloaded items AFTER first paint.
      // The refresh walks every download and network-fills on a metadata
      // miss, serially — awaiting it here used to hold first paint behind
      // one round-trip per download, after the bind had already settled.
      // It notifies listeners when it finishes, so the downloads list and
      // sync-rule titles populate shortly after MainScreen lands. The
      // catchError keeps a failing refresh from surfacing as an unhandled
      // async error now that nothing awaits it.
      unawaited(
        downloadProvider.refreshMetadataFromCache().catchError((Object e, StackTrace st) {
          appLogger.w('Setup: post-launch download metadata refresh failed', error: e, stackTrace: st);
        }),
      );
    } finally {
      deepLinks.settleStartupProfile(applied: linkApplied);
    }
  }

  /// Wire per-server status updates from [MultiServerManager] into the
  /// splash list so the user sees check/cross marks land as the binder
  /// brings each client online. [MultiServerManager.connectProgressStream]
  /// fires as each individual server settles; [MultiServerManager.statusStream]
  /// emits once per connect pass and back-fills anything the progress stream
  /// missed (e.g. servers torn down by the binder's visibility sweep).
  /// Best-effort: stops listening when the state goes away.
  StreamSubscription<Map<String, bool>>? _statusSub;
  StreamSubscription<({String serverId, bool online})>? _connectProgressSub;

  void _bindServerStatusListener() {
    _statusSub?.cancel();
    _connectProgressSub?.cancel();
    final manager = _serverManagerFromContext();
    _connectProgressSub = manager.connectProgressStream.listen((progress) {
      if (!mounted) return;
      final existing = _serverStatus[progress.serverId];
      if (existing == null) return;
      setState(() {
        _serverStatus[progress.serverId] = (existing.$1, progress.online);
      });
    });
    _statusSub = manager.statusStream.listen((status) {
      if (!mounted) return;
      setState(() {
        for (final entry in status.entries) {
          final existing = _serverStatus[entry.key];
          if (existing != null) {
            _serverStatus[entry.key] = (existing.$1, entry.value);
          }
        }
      });
    });
  }

  MultiServerManager _serverManagerFromContext() => context.read<MultiServerProvider>().serverManager;

  @override
  void dispose() {
    _stopBindElapsedTimer();
    _statusSub?.cancel();
    _connectProgressSub?.cancel();
    super.dispose();
  }

  Widget _buildStatusText(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: Text(
        _statusMessage,
        key: ValueKey(_statusMessage),
        textAlign: TextAlign.center,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
      ),
    );
  }

  Widget _buildServerStatusList(BuildContext context) {
    if (_serverStatus.isEmpty) return const SizedBox.shrink();
    final textTheme = Theme.of(context).textTheme;
    final dimColor = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5);
    const successColor = Color(0xFF4CAF50);
    const failColor = Color(0xFFEF5350);

    return Column(
      mainAxisSize: .min,
      children: _serverStatus.entries.map((entry) {
        final (name, connected) = entry.value;
        final Widget statusIcon;
        // 1.2.19, L-22: a still-pending server shows how long the bind
        // has been waiting on it ("Trex … 12s"), so a hung bind names
        // the slow leg instead of spinning silently.
        final label = connected == null && _bindStartedAt != null ? '$name … ${_bindElapsedSeconds}s' : name;
        if (connected == null) {
          statusIcon = AppIcon(Symbols.circle_rounded, size: 10, color: dimColor);
        } else if (connected) {
          statusIcon = const AppIcon(Symbols.check_circle_rounded, size: 14, color: successColor);
        } else {
          statusIcon = const AppIcon(Symbols.cancel_rounded, size: 14, color: failColor);
        }
        return Padding(
          key: ValueKey(entry.key),
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: .min,
            children: [
              statusIcon,
              const SizedBox(width: 8),
              Text(label, style: textTheme.bodySmall?.copyWith(color: dimColor)),
            ],
          ),
        );
      }).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    const coralColor = Color(0xFFE5A00D);
    final height = MediaQuery.sizeOf(context).height;
    // The stacked layout below hangs its two rows off fixed ±170/180 offsets from the middle, which
    // needs roughly 700 logical pixels of height. A car at a large interface scale — and a phone in
    // landscape — has less than that, and the rows would collide or fall outside the Stack's clip.
    if (height < 700) {
      return ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SvgPicture.asset('assets/plezy_adaptive_foreground.svg', width: 160, height: 160),
                  _buildStatusText(context),
                  const SizedBox(height: 16),
                  Center(
                    child: _serverStatus.isEmpty
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: coralColor),
                          )
                        : _buildServerStatusList(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Stack(
        children: [
          Center(child: SvgPicture.asset('assets/plezy_adaptive_foreground.svg', width: 288, height: 288)),
          Positioned(left: 0, right: 0, bottom: height * 0.5 - 170, child: _buildStatusText(context)),
          Positioned(
            left: 0,
            right: 0,
            top: height * 0.5 + 180,
            child: Center(
              child: _serverStatus.isEmpty
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: coralColor),
                    )
                  : _buildServerStatusList(context),
            ),
          ),
        ],
      ),
    );
  }
}
