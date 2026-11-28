import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../i18n/strings.g.dart';
import '../services/app_exit_service.dart';
import '../services/auto_dump_service.dart';
import '../services/last_crash_store.dart';
import '../services/log_submit_service.dart';
import '../utils/media_server_http_client.dart';
import '../utils/snackbar_helper.dart';

/// Emergency debug log saver (1.2.13, the owner 2026-11-14 ~17:21 EST): after
/// 3 failed starts the app does a DIFFERENT startup — this screen, and
/// nothing else. No catalog bind, no Trex load, no background sync, no
/// splash-to-main: a minimal startup that cannot crash the same way.
///
/// the owner's worry was that recording/saving the dump needs permissions.
/// Verified (Android Developers, "Access documents and other files", and
/// scoped storage since Android 10/API 29): NO permission is needed for
/// either half. Recording reads only in-app data (the app's own rolling
/// log file, settings, memory numbers, the last crash record — all
/// in-app, no logcat, no READ_LOGS). Saving goes through the system save
/// picker (Storage Access Framework, ACTION_CREATE_DOCUMENT) — "Because
/// the user is involved in selecting the files or directories that your
/// app can access, this mechanism doesn't require any system
/// permissions" — or the app-specific external files dir, which is
/// scoped-storage exempt on all API levels. So the screen asks WHERE to
/// save, not for a permission, and never requests
/// MANAGE_EXTERNAL_STORAGE (all-files access — a heavy permission the
/// picker makes unnecessary; Google Play restricts it to file managers
/// and backup tools anyway).
///
/// Exactly two paths, both on the screen (the owner's words, official copy):
/// (a) SAVE the debug file — the full summary-first dump, via the save
/// picker (primary) or the app-folder fallback; after a save, Share /
/// Restart PlenTV / Close. (b) MOVE FORWARD with the startup as usual —
/// "Continue startup" resets the counter and proceeds to normal startup.
///
/// 1.6.35 adds a third path: SUBMIT the dump straight to our GitHub repo
/// via the log-submit Worker ([submitDiagnosticLog] — redacted on-device
/// first, same as the Logs screen). The TV path: saving + sharing a file
/// is awkward on a TV, submitting is one button. It needs no saved file
/// — it builds the same dump text the save path writes — and it is
/// offered both before and after a save. A submit does NOT reset the
/// failed-start counter (only saving or continuing does); a failed submit
/// never traps the user: the hint shows and every other button stays live.
/// Closing the screen without saving or skipping leaves the counter at
/// the threshold — this screen never installs the clean-exit observer,
/// so a close here never writes a clean exit and the next launch shows
/// the screen again.
class EmergencyDebugLogSaverScreen extends StatefulWidget {
  const EmergencyDebugLogSaverScreen({
    super.key,
    required this.failedStarts,
    required this.onContinueStartup,
    this.onContinueWithoutIptv,
    required this.showSavePicker,
    this.requestExit = AppExitService.requestExit,
    // 1.2.22 §63.6: the early-read evidence for the dump (from main()).
    this.previousExitReport,
    this.watchdogRing,
    // 1.6.35: test seams for the submit path (same pattern as the Logs
    // screen's `logSubmitEndpoint` / `httpClient`). Production passes
    // neither: the endpoint comes from the build-time
    // [logSubmitEndpoint] constant and the shared [httpClient] is used.
    this.logSubmitEndpointOverride,
    this.logSubmitClient,
  });

  /// Abnormal exits (cumulative — any 3 crashes, ever) that brought the app here (3+).
  final int failedStarts;

  /// The previous-exit report main() read before the saver decision —
  /// the fresh record, not the stale log line.
  final Map<String, Object?>? previousExitReport;

  /// The previous run's main-thread watchdog ring, read before the
  /// saver decision so a new run never overwrites it first.
  final List<({DateTime at, String label})>? watchdogRing;

  /// Proceed to the normal startup (called after the counter reset).
  final VoidCallback onContinueStartup;

  /// L-21 (1.2.19): proceed to the normal startup with the IPTV bind
  /// skipped (Plex/Jellyfin only), so a bind-peak crash loop has an
  /// exit that isn't "crash again". Called after the counter reset,
  /// like [onContinueStartup]. Null in tests / callers that do not
  /// offer the escape hatch — the button is then hidden.
  final VoidCallback? onContinueWithoutIptv;

  /// False on Android TV, which has no document picker — the primary
  /// save button then writes to Downloads first (app folder fallback).
  final bool showSavePicker;

  /// Test seam (same pattern as StartupFailureView): quitting cannot be
  /// observed from a widget test, so the exit call is injectable.
  final Future<bool> Function({AppExitApplication? exitApplicationForTesting}) requestExit;

  /// Test seam for the submit path: overrides the build-time submit
  /// endpoint ([logSubmitEndpoint]). Production passes null.
  final String? logSubmitEndpointOverride;

  /// Test seam for the submit path: the HTTP client the submit posts
  /// with. Production passes null and the shared [httpClient] is used.
  final MediaServerHttpClient? logSubmitClient;

  @override
  State<EmergencyDebugLogSaverScreen> createState() => _EmergencyDebugLogSaverScreenState();
}

class _EmergencyDebugLogSaverScreenState extends State<EmergencyDebugLogSaverScreen> {
  /// Path of the saved dump, once either save path succeeds.
  String? _savedPath;

  /// A save is in flight — the save buttons are disabled.
  bool _saving = false;

  /// The last save failed (not cancelled): show the fallback hint.
  bool _saveFailed = false;

  /// L-21: the last save was refused because the disk cannot fit the
  /// dump — shown instead of the generic failure hint.
  String? _saveStorageFullMessage;

  /// "Continue startup" is in flight — the button is disabled.
  bool _continuing = false;

  /// A submit is in flight — the submit + save + continue buttons are disabled.
  bool _submitting = false;

  /// The last submit failed: show the hint, keep every button live.
  bool _submitFailed = false;

  /// The created GitHub issue URL, once a submit succeeds.
  String? _submittedIssueUrl;

  Future<void> _saveViaPicker() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
      _saveStorageFullMessage = null;
    });
    final result = await AutoDumpService.writeDumpToPicker(
      failedStarts: widget.failedStarts,
      previousExitReport: widget.previousExitReport,
      watchdogRing: widget.watchdogRing,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.path != null) {
      setState(() => _savedPath = result.path);
    } else if (result.storageFullMessage != null) {
      setState(() => _saveStorageFullMessage = result.storageFullMessage);
    } else if (!result.cancelled) {
      // The picker failed (not dismissed): try Downloads once — on a
      // TV the picker is absent, and the file belongs in Downloads
      // where the user can find it. Only if that fails too does the
      // app-folder hint appear.
      await _saveToDownloadsOrAppFolder();
    }
    // Cancelled: nothing changes — both save buttons stay on screen.
  }

  /// TV primary save (1.2.21): Downloads first, the app folder as the
  /// fallback. On Android TV the save picker is absent, so this is the
  /// only save button — and the file must land somewhere the user can
  /// find it.
  Future<void> _saveToDownloadsOrAppFolder() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
      _saveStorageFullMessage = null;
    });
    final result = await AutoDumpService.writeDumpToDownloadsOrAppFolder(
      failedStarts: widget.failedStarts,
      previousExitReport: widget.previousExitReport,
      watchdogRing: widget.watchdogRing,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.path != null) {
      setState(() => _savedPath = result.path);
    } else if (result.storageFullMessage != null) {
      setState(() => _saveStorageFullMessage = result.storageFullMessage);
    } else {
      setState(() => _saveFailed = true);
    }
  }

  Future<void> _saveToAppFolder() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveFailed = false;
      _saveStorageFullMessage = null;
    });
    final result = await AutoDumpService.writeDump(
      failedStarts: widget.failedStarts,
      previousExitReport: widget.previousExitReport,
      watchdogRing: widget.watchdogRing,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (result.path != null) {
      setState(() => _savedPath = result.path);
    } else if (result.storageFullMessage != null) {
      setState(() => _saveStorageFullMessage = result.storageFullMessage);
    } else {
      setState(() => _saveFailed = true);
    }
  }

  Future<void> _shareSavedFile() async {
    final path = _savedPath;
    if (path == null) return;
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], subject: 'PlenTV emergency debug log'),
      );
    } catch (_) {
      if (!mounted) return;
      showErrorSnackBar(context, t.messages.autoDumpShareFailed);
    }
  }

  Future<void> _continueStartup() async {
    if (_continuing) return;
    setState(() => _continuing = true);
    await LastCrashStore.resetFailedStartCounter();
    widget.onContinueStartup();
  }

  /// L-21: the bind-peak escape hatch — reset the counter, then start
  /// without the IPTV bind (Plex/Jellyfin only). Same counter rule as
  /// [_continueStartup]: the saver rule itself is untouched (any 3
  /// crashes, cumulative); only the startup that follows differs.
  Future<void> _continueWithoutIptv() async {
    if (_continuing) return;
    setState(() => _continuing = true);
    await LastCrashStore.resetFailedStartCounter();
    widget.onContinueWithoutIptv?.call();
  }

  /// 1.6.35: submit the same dump text the save path writes, straight
  /// to our GitHub repo via the log-submit Worker. No saved file needed,
  /// no database opened: this screen runs in minimal startup with no
  /// database in scope, and opening one here would break the "cannot
  /// crash the same way" guarantee — so the submit runs on pattern
  /// redaction alone (the dump text is already redacted by
  /// [DebugLogExportService], and [submitDiagnosticLog] applies the
  /// pattern rules on top). A submit never resets the failed-start
  /// counter and never navigates anywhere: on success the issue link
  /// shows inline and the user still saves or continues as usual; on
  /// failure the hint shows and every button stays live.
  Future<void> _submitLog() async {
    if (_submitting || _submittedIssueUrl != null) return;
    final endpoint = widget.logSubmitEndpointOverride ?? logSubmitEndpoint;
    if (endpoint.isEmpty) return;
    setState(() {
      _submitting = true;
      _submitFailed = false;
    });
    try {
      final dumpText = await AutoDumpService.buildDumpText(
        failedStarts: widget.failedStarts,
        dumpReason: 'emergency debug log saver after ${widget.failedStarts} failed starts',
        previousExitReport: widget.previousExitReport,
        watchdogRing: widget.watchdogRing,
      );
      final issue = await submitDiagnosticLog(
        title: 'PlenTV emergency debug log ${DateTime.now().toUtc().toIso8601String().substring(0, 10)}',
        logText: dumpText,
        client: widget.logSubmitClient,
        endpointOverride: endpoint,
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submittedIssueUrl = issue.url;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitFailed = true;
      });
    }
  }

  /// The submit action + its status, shared by both branches: the
  /// pre-save button list and the post-save Share / Restart / Close
  /// list. Hidden entirely when no submit endpoint is configured in
  /// this build (local dev builds) — saving always works.
  List<Widget> _submitWidgets(ThemeData theme) {
    final endpoint = widget.logSubmitEndpointOverride ?? logSubmitEndpoint;
    if (endpoint.isEmpty) return const [];
    final busy = _saving || _continuing || _submitting;
    final submitted = _submittedIssueUrl != null;
    final strings = t.emergencyDebugLogSaver;
    return [
      OutlinedButton(
        onPressed: (busy || submitted) ? null : _submitLog,
        child: Text(strings.submitDebugLog),
      ),
      if (submitted) ...[
        const SizedBox(height: 12),
        Text(
          strings.submitDebugLogSubmitted,
          style: theme.textTheme.titleSmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 4),
        SelectableText(
          _submittedIssueUrl!,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          textAlign: TextAlign.center,
        ),
      ],
      if (_submitFailed) ...[
        const SizedBox(height: 12),
        Text(
          strings.submitDebugLogFailed,
          style: TextStyle(color: theme.colorScheme.error),
          textAlign: TextAlign.center,
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final strings = t.emergencyDebugLogSaver;
    final theme = Theme.of(context);
    final submitWidgets = _submitWidgets(theme);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 48, color: theme.colorScheme.error),
                  const SizedBox(height: 16),
                  Text(
                    strings.title,
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  Text(strings.body, style: theme.textTheme.bodyLarge, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(
                    strings.noPermissionNeeded,
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (_savedPath == null) ...[
                    FilledButton(
                      onPressed: (_saving || _submitting) ? null : (widget.showSavePicker ? _saveViaPicker : _saveToDownloadsOrAppFolder),
                      child: Text(strings.saveDebugLog),
                    ),
                    if (widget.showSavePicker) ...[
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: (_saving || _submitting) ? null : _saveToAppFolder,
                        child: Text(strings.saveInAppFolder),
                      ),
                    ],
                    if (submitWidgets.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      ...submitWidgets,
                    ],
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: (_saving || _continuing || _submitting) ? null : _continueStartup,
                      child: Text(strings.continueStartup),
                    ),
                    if (widget.onContinueWithoutIptv != null) ...[
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: (_saving || _continuing || _submitting) ? null : _continueWithoutIptv,
                        child: Text(strings.continueWithoutIptv),
                      ),
                    ],
                    if (_saveStorageFullMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _saveStorageFullMessage!,
                        style: TextStyle(color: theme.colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (_saveFailed) ...[
                      const SizedBox(height: 12),
                      Text(
                        strings.saveFailed,
                        style: TextStyle(color: theme.colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (_saving || _submitting) ...[
                      const SizedBox(height: 16),
                      const Center(child: CircularProgressIndicator()),
                    ],
                  ] else ...[
                    Text(strings.savedTo, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    SelectableText(
                      _savedPath!,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: _shareSavedFile,
                      icon: const Icon(Icons.share),
                      label: Text(t.logs.shareAutoDump),
                    ),
                    if (submitWidgets.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      ...submitWidgets,
                    ],
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: widget.onContinueStartup,
                      child: Text(strings.restartPlezTv),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: () => widget.requestExit(),
                      child: Text(t.common.close),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
