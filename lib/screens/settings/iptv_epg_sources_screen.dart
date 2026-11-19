import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../connection/connection.dart';
import '../../i18n/app_locale_utils.dart';
import '../../i18n/strings.g.dart';
import '../../media/ids.dart';
import '../../media/iptv_client.dart';
import '../../media/iptv_live_tv.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/iptv/iptv_epg_sources.dart';
import '../../services/settings_service.dart';
import '../../utils/formatters.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focusable_list_tile.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/setting_tile.dart';
import '../../widgets/settings_section.dart';
import 'iptv_epg_no_guide_screen.dart';

/// The Reload / M3U-check report dialog's content (1.2.17): a header line
/// plus one line per report row, in a scroll view. The report grew a line
/// per release (R4 download, R6 coverage, feed/unmatched samples) and the
/// old plain `Column` overflowed the dialog by 435 px on the 1.2.15 phone
/// verdict — an `AlertDialog` constrains its content height, so a tall
/// report must scroll instead of overflowing. Public so widget tests can
/// pump it directly with a tall report in a short viewport.
class ReloadReportContent extends StatelessWidget {
  const ReloadReportContent({super.key, this.header, required this.lines});

  final String? header;
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header != null) Text(header!),
          if (lines.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final line in lines) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text(line)),
          ],
        ],
      ),
    );
  }
}

/// EPG sources for one IPTV connection (PlezTV 1.2.0, §3.1/§3.2): the
/// provider guide first (unremovable, never disabled or moved), then
/// added XMLTV sources in priority order — each with a status chip, an
/// enable switch, a per-source time shift, reorder and delete — plus the
/// "added sources take precedence" toggle, Reload TV details, and the
/// Channels without guide overview. Adding a source validates the URL
/// first (fetch the first bytes, confirm XMLTV); a failure shows the
/// reason instead of a silent add.
class IptvEpgSourcesScreen extends StatefulWidget {
  final Connection connection;

  const IptvEpgSourcesScreen({super.key, required this.connection});

  @override
  State<IptvEpgSourcesScreen> createState() => _IptvEpgSourcesScreenState();
}

class _IptvEpgSourcesScreenState extends State<IptvEpgSourcesScreen> {
  List<IptvEpgSourceConfig> _sources = [];
  Map<String, IptvEpgSourceStatus> _statuses = {};
  bool _addedFirst = false;
  bool _loading = true;
  // 1.2.3: true while a Reload is running — the Reload row shows a
  // spinner instead of looking dead while the list + feeds load.
  bool _reloading = false;
  // 1.2.15 R2: true while the one-time M3U tvg-id check runs — same
  // spinner treatment as the Reload row.
  bool _checkingM3uTvgIds = false;
  // 1.2.19 (L-3): live feed-download progress while a Reload runs
  // (polled from the support — the Reload row shows bytes instead of
  // a bare spinner) + whether a partial feed download is waiting to
  // resume (shown in the provider source's detail line).
  Timer? _reloadProgressTimer;
  ({int received, int? totalBytes})? _feedProgress;
  bool _pendingFeedResume = false;
  // 1.3.27 §P0-1/§P0-3: live playlist-download progress while a check
  // runs (polled from the support — the Check row shows bytes instead
  // of a bare spinner) and the last check's one-line verdict, carried
  // into the next Reload report so the dialog reads as a per-source
  // verdict (feed matched / short-EPG coverage / button result).
  Timer? _m3uCheckProgressTimer;
  ({int received, int? totalBytes, int resumedFromBytes})? _m3uCheckProgress;
  String? _lastM3uCheckSummary;
  int _updateIntervalHours = 24;

  IptvLiveTvSupport? _boundSupport() {
    try {
      final client = context.read<MultiServerProvider>().getClientForServer(ServerId(widget.connection.id));
      if (client is! IptvClient) return null;
      final support = client.liveTv;
      return support is IptvLiveTvSupport ? support : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _stopReloadProgress();
    _stopM3uCheckProgress();
    super.dispose();
  }

  /// Stop the Reload progress poll (1.2.19, L-3) — called on every
  /// Reload exit path and in [dispose].
  void _stopReloadProgress() {
    _reloadProgressTimer?.cancel();
    _reloadProgressTimer = null;
  }

  /// Stop the Check progress poll (1.3.27 §P0-1) — called on every
  /// Check exit path and in [dispose].
  void _stopM3uCheckProgress() {
    _m3uCheckProgressTimer?.cancel();
    _m3uCheckProgressTimer = null;
  }

  Future<void> _load() async {
    final support = _boundSupport();
    if (support == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final settings = await SettingsService.getInstance();
    // 1.3.28: the built-in-default preset — a no-op while the flag is
    // off, so the one-tap preset below is the only path by default.
    await support.ensurePresetDefault();
    final sources = await support.epgSources();
    final statuses = await support.epgSourceStatuses();
    final addedFirst = await support.addedSourcesTakePrecedence();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _statuses = statuses;
      _addedFirst = addedFirst;
      _updateIntervalHours = settings.read(SettingsService.iptvEpgUpdateIntervalHours);
      _loading = false;
    });
    // 1.2.19 (L-3): whether a partial feed download is waiting — the
    // provider source's detail line names it ("will resume").
    final pendingResume = await support.hasPendingFeedResume(support.xtreamFeedCacheKey);
    if (!mounted) return;
    setState(() => _pendingFeedResume = pendingResume);
  }

  Duration? get _ttl => _updateIntervalHours <= 0 ? null : Duration(hours: _updateIntervalHours);

  String _statusLabel(IptvEpgSourceStatus status, bool enabled) {
    return switch (status.state(enabled: enabled, ttl: _ttl)) {
      IptvEpgSourceState.upToDate => t.iptv.epgSourceStatusUpToDate,
      IptvEpgSourceState.needsRefresh => t.iptv.epgSourceStatusNeedsRefresh,
      IptvEpgSourceState.failed => t.iptv.epgSourceStatusFailed,
      IptvEpgSourceState.disabled => t.iptv.epgSourceStatusDisabled,
    };
  }

  Color _statusColor(IptvEpgSourceState state, ThemeData theme) {
    return switch (state) {
      IptvEpgSourceState.upToDate => Colors.green,
      IptvEpgSourceState.needsRefresh => Colors.amber.shade700,
      IptvEpgSourceState.failed => theme.colorScheme.error,
      IptvEpgSourceState.disabled => theme.disabledColor,
    };
  }

  String _formatTime(DateTime time) =>
      '${DateFormat.MMMd(LocaleSettings.currentLocale.intlLocaleName).format(time.toLocal())} · '
      '${formatClockTime(time.toLocal(), is24Hour: MediaQuery.alwaysUse24HourFormatOf(context))}';

  String? _statusDetail(IptvEpgSourceConfig source, IptvEpgSourceStatus status) {
    final lines = <String>[];
    if (status.lastSuccess != null || status.programs > 0) {
      lines.add(t.iptv.epgSourceStatusDetail(programs: status.programs, channels: status.channels));
    }
    if (status.lastSuccess != null) lines.add(_formatTime(status.lastSuccess!));
    if (status.lastFailure != null && status.lastFailureReason != null) {
      lines.add('${_formatTime(status.lastFailure!)} · ${status.lastFailureReason}');
    }
    // 1.2.15 R4: the last feed download — bytes, SHA, 304-vs-200, and
    // the User-Agent the request carried. Shown whenever a download
    // has been recorded (a 304 records 0 bytes, so it counts too).
    if (status.bytesDownloaded > 0 || status.notModified) {
      lines.add(
        t.iptv.epgSourceDownloadDetail(
          detail: _feedDownloadDetail(
            bytesDownloaded: status.bytesDownloaded,
            sha256: status.sha256,
            notModified: status.notModified,
            userAgent: status.userAgent,
            resumed: status.resumed,
            resumedBytes: status.resumedBytes,
          ),
        ),
      );
    }
    // 1.2.19 (L-3): a partial feed download waits at the resume path
    // — the next Reload continues it instead of restarting from byte
    // 0. Provider source only (added sources have no resume file).
    if (source.isProvider && _pendingFeedResume) {
      lines.add(t.iptv.epgPartialFeedWillResume);
    }
    if (lines.isEmpty) return t.iptv.epgSourceStatusNeverFetched;
    return lines.join('\n');
  }

  Future<void> _setPrecedence(bool value) async {
    final support = _boundSupport();
    if (support == null) return;
    await support.setAddedSourcesTakePrecedence(value);
    if (!mounted) return;
    setState(() => _addedFirst = value);
  }

  Future<void> _toggleEnabled(IptvEpgSourceConfig source, bool enabled) async {
    final support = _boundSupport();
    if (support == null) return;
    await support.updateEpgSource(source.copyWith(enabled: enabled));
    await _load();
  }

  Future<void> _pickShift(IptvEpgSourceConfig source) async {
    final options = <int?>[null, -120, -60, -30, 30, 60, 120];
    // A null pick means "No offset" AND a dismissed dialog — tell them
    // apart with an explicit flag, so dismissing never clears the shift.
    var chose = false;
    int? picked;
    await showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(t.iptv.epgTimeShift),
        children: [
          for (final minutes in options)
            SimpleDialogOption(
              onPressed: () {
                chose = true;
                picked = minutes;
                Navigator.of(context).pop();
              },
              child: Text(
                minutes == null ? t.iptv.epgNoOffset : t.iptv.epgOffsetMinutes(n: minutes),
              ),
            ),
        ],
      ),
    );
    if (!chose) return;
    final support = _boundSupport();
    if (support == null) return;
    await support.updateEpgSource(source.copyWith(timeShiftMinutes: picked, clearTimeShift: picked == null));
    await _load();
  }

  Future<void> _move(IptvEpgSourceConfig source, int delta) async {
    final support = _boundSupport();
    if (support == null) return;
    await support.moveEpgSource(source.id, delta);
    await _load();
  }

  Future<void> _delete(IptvEpgSourceConfig source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.iptv.epgSourceDelete),
        content: Text(t.iptv.epgSourceDeleteConfirm(name: source.name)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.common.cancel)),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(t.common.delete)),
        ],
      ),
    );
    if (confirmed != true) return;
    final support = _boundSupport();
    if (support == null) return;
    await support.deleteEpgSource(source.id);
    if (!mounted) return;
    showSuccessSnackBar(context, t.iptv.epgSourceDeleted);
    await _load();
  }

  Future<void> _addSource() async {
    final urlController = TextEditingController();
    final nameController = TextEditingController();
    int? shiftMinutes;
    String? error;
    final added = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(t.iptv.epgAddSourceTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlController,
                decoration: InputDecoration(
                  labelText: t.iptv.epgAddSourceUrlLabel,
                  hintText: t.iptv.epgAddSourceUrlHint,
                ),
                keyboardType: TextInputType.url,
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: t.iptv.epgAddSourceNameLabel,
                  hintText: t.iptv.epgAddSourceNameHint,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                initialValue: shiftMinutes,
                decoration: InputDecoration(labelText: t.iptv.epgTimeShift),
                items: [
                  DropdownMenuItem<int?>(value: null, child: Text(t.iptv.epgNoOffset)),
                  for (final minutes in [-120, -60, -30, 30, 60, 120])
                    DropdownMenuItem<int?>(
                      value: minutes,
                      child: Text(t.iptv.epgOffsetMinutes(n: minutes)),
                    ),
                ],
                onChanged: (value) => setDialogState(() => shiftMinutes = value),
              ),
              if (error != null) ...[
                const SizedBox(height: 12),
                Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.common.cancel)),
            TextButton(
              onPressed: () async {
                final support = _boundSupport();
                if (support == null) return;
                try {
                  await support.addEpgSource(
                    urlController.text,
                    name: nameController.text,
                    timeShiftMinutes: shiftMinutes,
                  );
                  if (context.mounted) Navigator.of(context).pop(true);
                } on StateError catch (e) {
                  // Validation failed: show the reason in the dialog, not
                  // a silent add (research §3.1).
                  setDialogState(() => error = e.message);
                }
              },
              child: Text(t.iptv.epgAddSource),
            ),
          ],
        ),
      ),
    );
    urlController.dispose();
    nameController.dispose();
    if (added == true && mounted) {
      showSuccessSnackBar(context, t.iptv.epgSourceAdded);
      await _load();
    }
  }

  /// Presets not yet added for this connection (1.3.28): a preset
  /// already added — by id, or by URL for sources added before
  /// presets existed — is not offered again.
  List<IptvEpgSourcePreset> get _missingPresets => IptvEpgSourcePresets.all
      .where((p) => !_sources.any((s) => s.presetId == p.id || (s.presetId == null && s.url == p.url)))
      .toList();

  /// One tap adds a preset source (1.3.28): no URL to paste, no
  /// validation round-trip to run by hand — the same add path the
  /// dialog uses, with its error shown if the guide is unreachable.
  Future<void> _addPreset(IptvEpgSourcePreset preset) async {
    final support = _boundSupport();
    if (support == null) return;
    try {
      await support.addEpgPreset(preset);
      if (!mounted) return;
      showSuccessSnackBar(context, t.iptv.epgPresetAdded(name: preset.name));
      await _load();
    } on StateError catch (e) {
      if (!mounted) return;
      showErrorSnackBar(context, e.message);
    }
  }

  /// The label for one unmatched sample row's blocked reason (1.2.8
  /// F7): the same wording the EPG details view uses, plus the two
  /// split reasons the overview collapses into one.
  String _unmatchedReasonLabel(String reason) {
    return switch (reason) {
      'ambiguous' => t.iptv.epgNoGuideReasonAmbiguous,
      'foreign' => t.iptv.epgNoGuideReasonForeign,
      'matched-but-no-programmes' => t.iptv.epgNoGuideReasonMatchedButNoPrograms,
      'matched-but-no-programmes-declared' => t.iptv.epgNoGuideReasonMatchedButNoProgramsDeclared,
      'matched-but-no-programmes-outside-window' => t.iptv.epgNoGuideReasonMatchedButNoProgramsOutsideWindow,
      'no-tvg-id' => t.iptv.epgNoGuideReasonNoTvgId,
      'tvg-id-not-in-feed' => t.iptv.epgNoGuideReasonTvgIdNotInFeed,
      _ => t.iptv.epgNoGuideReasonNotLoaded,
    };
  }

  Future<void> _reloadTvDetails() async {
    final support = _boundSupport();
    if (support == null || _reloading) return;
    setState(() {
      _reloading = true;
      _feedProgress = null;
    });
    // 1.2.19 (L-3): poll the in-flight feed progress while the reload
    // runs — the Reload row shows live bytes instead of a bare
    // spinner. Stopped on every exit path below and in dispose.
    _reloadProgressTimer?.cancel();
    _reloadProgressTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final progress = support.feedDownloadProgress(support.xtreamFeedCacheKey);
      if (progress != _feedProgress) setState(() => _feedProgress = progress);
    });
    IptvReloadTvDetailsResult result;
    try {
      result = await support.reloadTvDetails();
    } catch (e) {
      // 1.2.3 RC1: reloadTvDetails never throws by contract — but a
      // throw must never escape the tap handler either (belt and
      // braces): build the failure into a report dialog so the tap
      // still ends in a report, never in silence.
      if (!mounted) return;
      _stopReloadProgress();
      setState(() => _reloading = false);
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.iptv.epgReloadTvDetails),
          content: Text(t.iptv.epgReloadUnexpectedFailure(reason: epgFeedErrorReason(e))),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.ok))],
        ),
      );
      if (mounted) await _load();
      return;
    }
    if (!mounted) return;
    // Clear the spinner BEFORE the report appears (1.2.3: the
    // indicator shows while the reload runs and clears when the report
    // appears — it must not keep spinning behind the dialog).
    _stopReloadProgress();
    setState(() => _reloading = false);
    final lines = <String>[];
    // 1.4.4 F6: the counts in the header are the previous feed's — the
    // fresh feed is still downloading in the background. Say so first,
    // before any count, or the report reads as if the Reload finished
    // the download.
    if (result.feedRefreshBackground) {
      lines.add(t.iptv.epgReloadFeedRefreshingBackground);
    }
    // 1.3.27 §P0-3 (C3): the last playlist check's verdict, first —
    // the Reload dialog reads as a per-source verdict (feed matched /
    // short-EPG coverage / button result), not a single count.
    if (_lastM3uCheckSummary != null) {
      lines.add(_lastM3uCheckSummary!);
    }
    if (result.channelListFailureKind != null) {
      lines.add(
        t.iptv.epgReloadChannelListFailed(
          reason: switch (result.channelListFailureKind!) {
            IptvEpgFeedOutcomeKind.denied => t.iptv.epgFeedDeniedReason,
            IptvEpgFeedOutcomeKind.notAnswering => t.iptv.epgFeedNotAnsweringReason,
            _ => result.channelListFailureReason ?? '',
          },
        ),
      );
    }
    for (final outcome in result.feedOutcomes) {
      lines.add(epgFeedOutcomeLine(outcome, result.channelsLoaded));
    }
    // 1.2.5 Fix 1: the diagnostics block — how channels matched, why
    // the rest did not, what the feed actually contains, and a sample
    // of each side. Only when a channel list was re-fetched (a Reload
    // whose list failed has no match counts to report).
    if (result.channelListFailureKind == null) {
      final tiers = result.matchTiers;
      lines.add(
        t.iptv.epgReloadMatchBreakdown(
          manual: tiers.manual,
          tvgId: tiers.tvgId,
          name: tiers.name,
          loose: tiers.nameLoose,
          affiliate: tiers.affiliateGuess,
        ),
      );
      if (tiers.unmatched > 0) {
        lines.add(
          t.iptv.epgReloadUnmatchedBreakdown(
            ambiguous: tiers.ambiguous,
            foreign: tiers.foreign,
            noTvgId: tiers.noTvgId,
            tvgIdNotInFeed: tiers.tvgIdNotInFeed,
            matchedButNoProgrammes: tiers.matchedButNoProgrammes,
          ),
        );
        // 1.2.8 F2: the matched-but-no-programmes split — declared
        // with nothing scheduled vs programmes outside the window.
        if (tiers.matchedButNoProgrammes > 0) {
          lines.add(
            t.iptv.epgReloadNoProgrammesSplit(
              declared: tiers.matchedButNoProgrammesDeclared,
              outsideWindow: tiers.matchedButNoProgrammesOutsideWindow,
            ),
          );
        }
      }
      // 1.2.8 F3: matches over ALL channels including hidden ones.
      if (result.channelsLoadedAll != null && result.withGuideAllChannels != null) {
        lines.add(
          t.iptv.epgReloadAllChannels(withGuide: result.withGuideAllChannels!, total: result.channelsLoadedAll!),
        );
      }
      for (final outcome in result.feedOutcomes) {
        if (outcome.feedProgramsParsed == null) continue;
        lines.add(
          t.iptv.epgReloadFeedStats(
            source: outcome.sourceName,
            channels: outcome.feedChannelsParsed ?? 0,
            // 1.2.8 F3: how many feed channels actually carry
            // programmes, next to the declared count.
            withProgrammes: outcome.feedChannels,
            parsed: outcome.feedProgramsParsed ?? 0,
            retained: outcome.feedProgramsRetained ?? 0,
          ),
        );
      }
      // 1.2.15 R4: one line per feed download — bytes, SHA, 304-vs-200,
      // and the User-Agent the request carried.
      for (final download in result.feedDownloads) {
        lines.add(
          t.iptv.epgReloadFeedDownload(
            source: download.sourceName,
            detail: _feedDownloadDetail(
              bytesDownloaded: download.bytesDownloaded,
              sha256: download.sha256,
              notModified: download.notModified,
              userAgent: download.userAgent,
              resumed: download.resumed,
              resumedBytes: download.resumedBytes,
            ),
          ),
        );
      }
      // 1.2.15 R6: what the guide actually showed before this Reload
      // — the feed-only match count above is not the guide. 1.2.17:
      // the never-fetched bucket is passed too — without it a fresh
      // start reads "0 of 200" as "no guide data" when all 200 rows
      // simply had never been opened yet.
      final sample = result.guideCoverageSample;
      if (sample != null && sample.sampled > 0) {
        // 1.3.27 §P0-3: when the guide was never opened, every sampled
        // row is never-fetched — the numeric line ("0 of 6 ... never
        // fetched: 6") reads as an empty guide, so say plainly that
        // short-EPG coverage is unknown until the guide is opened.
        if (sample.notFetched == sample.sampled) {
          lines.add(t.iptv.epgReloadGuideCoverageNotOpened);
        } else {
          // 1.2.20 (d): the scope label says which rows the sample
          // describes — the rows on screen, the matched channels, or
          // the first rows in guide order when the guide was not opened.
          final scopeLabel = switch (sample.scope) {
            IptvGuideSampleScope.visible => t.iptv.epgReloadGuideCoverageScopeVisible,
            IptvGuideSampleScope.matched => t.iptv.epgReloadGuideCoverageScopeMatched,
            IptvGuideSampleScope.guideOrder => t.iptv.epgReloadGuideCoverageScopeGuideOrder,
          };
          lines.add(
            t.iptv.epgReloadGuideCoverageSample(
              withPrograms: sample.withPrograms,
              sampled: sample.sampled,
              scopeLabel: scopeLabel,
              shortEpg: sample.fromShortEpg,
              feed: sample.fromFeedById + sample.fromFeedByName,
              mixed: sample.fromMixed,
              none: sample.none,
              notFetched: sample.notFetched,
            ),
          );
        }
      }
      // 1.2.20 (b): whether the Reload's end-of-load slide put the
      // visible rows' programmes into the window. 'no-feed' and the
      // silent T0 skip show nothing — the feed lines already cover a
      // missing feed, and T0 never loads one.
      final slide = result.windowSlide;
      if (slide.slid) {
        lines.add(t.iptv.epgReloadWindowSlideReady(count: slide.channelCount));
      } else if (slide.reason == 'store-unavailable' || slide.reason == 'slide-failed') {
        final reason = slide.reason == 'store-unavailable'
            ? t.iptv.epgReloadWindowSlideReasonStoreUnavailable
            : t.iptv.epgReloadWindowSlideReasonSlideFailed;
        lines.add(t.iptv.epgReloadWindowSlideSkipped(reason: reason));
      }
      if (result.feedSamples.isNotEmpty) {
        lines.add(
          t.iptv.epgReloadFeedSample(
            samples: result.feedSamples
                .map((e) => e.displayNames.isEmpty ? e.xmltvId : '${e.xmltvId} (${e.displayNames.join(', ')})')
                .join(', '),
          ),
        );
      }
      if (result.sampleUnmatched.isNotEmpty) {
        // 1.2.8 F7: each sample row names its reason and the id the
        // matcher tried (epg_channel_id, else tvg-id, else nothing).
        lines.add(
          t.iptv.epgReloadUnmatchedSample(
            samples: result.sampleUnmatched.map((e) {
              final id = e.epgChannelId ?? e.tvgId ?? '';
              final reason = _unmatchedReasonLabel(e.reason);
              return id.isEmpty ? '${e.channelName} — $reason' : '${e.channelName} — $reason — $id';
            }).join(', '),
          ),
        );
      }
      if (result.epgChannelIdCount != null) {
        lines.add(
          t.iptv.epgReloadEpgChannelIds(withId: result.epgChannelIdCount!, total: result.channelsLoaded),
        );
      }
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.iptv.epgReloadTvDetails),
        content: ReloadReportContent(
          header: t.iptv.epgReloadTvDetailsResult(
            channels: result.channelsLoaded,
            withGuide: result.withGuide,
            withoutGuide: result.withoutGuide,
          ),
          lines: lines,
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.ok))],
      ),
    );
    await _load();
  }

  /// Live feed-download progress for the Reload row (1.2.19, L-3):
  /// "Downloading feed — 12.4 MB of 88.0 MB (14%)", or bytes received
  /// when the server declared no total.
  String _feedProgressLine(({int received, int? totalBytes}) progress) {
    final received = _humanBytes(progress.received);
    final total = progress.totalBytes;
    if (total == null || total <= 0) {
      return t.iptv.epgFeedProgressNoTotal(received: received);
    }
    final percent = (progress.received * 100 / total).clamp(0, 100).round();
    return t.iptv.epgFeedProgressWithTotal(
      received: received,
      total: _humanBytes(total),
      percent: percent,
    );
  }

  /// Human-readable byte count for a feed download line (1.2.15 R4).
  static String _humanBytes(int bytes) {
    if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes bytes';
  }

  /// One feed download's detail line (1.2.15 R4): size, SHA (short),
  /// 304-vs-200, and the User-Agent the request carried. 1.2.19 (L-3):
  /// a resumed download also names how many bytes came from the
  /// previous partial, so a resumed feed is visible, not silent.
  static String _feedDownloadDetail({
    required int bytesDownloaded,
    required String? sha256,
    required bool notModified,
    required String? userAgent,
    bool resumed = false,
    int resumedBytes = 0,
  }) {
    final sha = sha256 == null
        ? 'no new download'
        : 'SHA ${sha256.length >= 12 ? sha256.substring(0, 12) : sha256}';
    final fresh = notModified ? 'not modified — kept the last download' : 'new download';
    final ua = userAgent == null ? 'no User-Agent sent' : 'User-Agent $userAgent';
    final resume = resumed ? ' · resumed from ${_humanBytes(resumedBytes)}' : '';
    return '${_humanBytes(bytesDownloaded)} · $sha · $fresh · $ua$resume';
  }

  /// 1.2.15 R2: run the one-time M3U tvg-id check and show its report.
  /// A failed playlist fetch still lands as a report (the error line),
  /// never as silence — the tap always ends in an answer. 1.3.27
  /// §P0-1/§P0-3: the Check row shows live byte progress while the
  /// check runs, and the check's one-line verdict is kept for the next
  /// Reload report; a zero-gain completion is reported as a finding
  /// (the playlist carries no ids the feed doesn't already have), not
  /// as a failure.
  Future<void> _checkM3uTvgIds() async {
    final support = _boundSupport();
    if (support == null || _checkingM3uTvgIds) return;
    setState(() {
      _checkingM3uTvgIds = true;
      _m3uCheckProgress = null;
    });
    // 1.3.27 §P0-1: poll the in-flight playlist progress while the
    // check runs — the Check row shows live bytes instead of a bare
    // spinner. Stopped on every exit path below and in dispose.
    _m3uCheckProgressTimer?.cancel();
    _m3uCheckProgressTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      final progress = support.m3uTvgIdCheckProgress;
      if (progress != _m3uCheckProgress) setState(() => _m3uCheckProgress = progress);
    });
    IptvM3uTvgIdDiagnostic result;
    try {
      result = await support.diagnoseM3uTvgIds();
    } catch (e) {
      // diagnoseM3uTvgIds never throws by contract — belt and braces.
      if (!mounted) return;
      _stopM3uCheckProgress();
      setState(() {
        _checkingM3uTvgIds = false;
        _m3uCheckProgress = null;
      });
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.iptv.epgM3uTvgIdCheck),
          content: Text(t.iptv.epgM3uTvgIdFailed(reason: epgFeedErrorReason(e))),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.ok))],
        ),
      );
      return;
    }
    if (!mounted) return;
    _stopM3uCheckProgress();
    // 1.3.27 §P0-3 (C1/C3): keep the check's verdict for the next
    // Reload report — a gain, a zero-gain finding, or the failure.
    final summary = result.error != null
        ? t.iptv.epgReloadCheckFailed(reason: result.error!)
        : result.gained > 0
            ? t.iptv.epgReloadCheckGained(gained: result.gained, inFeed: result.gainedInFeed)
            : t.iptv.epgReloadCheckNoGain;
    setState(() {
      _checkingM3uTvgIds = false;
      _m3uCheckProgress = null;
      _lastM3uCheckSummary = summary;
    });
    final lines = <String>[];
    if (result.error != null) {
      lines.add(t.iptv.epgM3uTvgIdFailed(reason: result.error!));
    } else {
      if (!result.feedLoaded) {
        lines.add(t.iptv.epgM3uTvgIdFeedNotLoaded);
      }
      lines.add(
        t.iptv.epgM3uTvgIdResult(
          checked: result.checked,
          noId: result.noId,
          gained: result.gained,
          inFeed: result.gainedInFeed,
        ),
      );
      // 1.3.27 §P0-3 (C1): a zero-gain completion is a finding — the
      // playlist carries no guide IDs the feed doesn't already have —
      // not a failure, and the rows' fate then rests on the guide
      // open, not on this button.
      if (result.gained == 0) {
        lines.add(t.iptv.epgM3uTvgIdNoGain);
      }
      if (result.samples.isNotEmpty) {
        lines.add(
          t.iptv.epgM3uTvgIdSample(
            samples: result.samples
                .map((e) => '${e.channelName} — ${e.tvgId}${e.inFeed ? '' : ' (not in the guide)'}')
                .join(', '),
          ),
        );
      }
      // 1.3.26 §69: the check is a repair now, not just a report —
      // Apply writes the gained ids as manual mappings, then a Reload
      // makes them take effect. Offered whenever the check gained
      // anything, feed loaded or not (the Reload loads the feed).
      if (result.gained > 0) {
        lines.add(t.iptv.epgM3uTvgIdApplyNote(gained: result.gained));
      }
    }
    final apply = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.iptv.epgM3uTvgIdCheck),
        content: ReloadReportContent(lines: lines),
        actions: [
          if (result.error == null && result.gained > 0)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(t.iptv.epgM3uTvgIdApply),
            ),
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(t.common.ok)),
        ],
      ),
    );
    if (apply != true || !mounted) return;
    final applied = await support.applyM3uTvgIds(result.gainedIds);
    if (!mounted) return;
    // 1.3.27 §P0-2: say when Apply kept existing assignments instead
    // of overwriting them.
    showSuccessSnackBar(
      context,
      applied.skippedHandAssigned > 0
          ? t.iptv.epgM3uTvgIdAppliedSkipped(applied: applied.applied, skipped: applied.skippedHandAssigned)
          : t.iptv.epgM3uTvgIdApplied(applied: applied.applied),
    );
    await _reloadTvDetails();
  }

  /// Live playlist-download progress for the Check row (1.3.27 §P0-1):
  /// "Downloading playlist — 12.4 MB of 88.0 MB (14%)", or bytes
  /// received when the server declared no total. A resumed download
  /// also names how many bytes came from the previous partial.
  String _m3uCheckProgressLine(({int received, int? totalBytes, int resumedFromBytes}) progress) {
    final received = _humanBytes(progress.received);
    final total = progress.totalBytes;
    final resumed = progress.resumedFromBytes > 0 ? ' · resumed from ${_humanBytes(progress.resumedFromBytes)}' : '';
    if (total == null || total <= 0) {
      return '${t.iptv.epgM3uTvgIdProgressNoTotal(received: received)}$resumed';
    }
    final percent = (progress.received * 100 / total).clamp(0, 100).round();
    return '${t.iptv.epgM3uTvgIdProgressWithTotal(received: received, total: _humanBytes(total), percent: percent)}$resumed';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.iptv.epgSourcesTitle),
      actions: [
        IconButton(
          icon: const AppIcon(Symbols.add_rounded),
          tooltip: t.iptv.epgAddSource,
          onPressed: _loading ? null : _addSource,
        ),
      ],
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Text(
              t.iptv.epgSourcesDescription,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Text(t.iptv.epgSourcesHint, style: theme.textTheme.bodySmall),
          ),
        ),
        if (_loading)
          const SliverPadding(
            padding: EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(child: Center(child: CircularProgressIndicator())),
          )
        else ...[
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverToBoxAdapter(
              child: SettingsGroup(
                title: t.iptv.epgSourcesTitle,
                children: [
                  FocusableSwitchListTile(
                    secondary: const AppIcon(Symbols.low_priority_rounded, fill: 1),
                    title: Text(t.iptv.epgAddedSourcesFirst),
                    subtitle: Text(t.iptv.epgAddedSourcesFirstDescription),
                    value: _addedFirst,
                    onChanged: (v) => unawaited(_setPrecedence(v)),
                  ),
                  for (var i = 0; i < _sources.length; i++) _SourceTile(
                    source: _sources[i],
                    status: _statuses[_sources[i].id] ?? IptvEpgSourceStatus.empty,
                    statusLabel: _statusLabel(
                      _statuses[_sources[i].id] ?? IptvEpgSourceStatus.empty,
                      _sources[i].enabled,
                    ),
                    statusColor: _statusColor(
                      (_statuses[_sources[i].id] ?? IptvEpgSourceStatus.empty).state(
                        enabled: _sources[i].enabled,
                        ttl: _ttl,
                      ),
                      theme,
                    ),
                    statusDetail: _statusDetail(
                      _sources[i],
                      _statuses[_sources[i].id] ?? IptvEpgSourceStatus.empty,
                    ),
                    canMoveUp: !_sources[i].isProvider && i > 1,
                    canMoveDown: !_sources[i].isProvider && i < _sources.length - 1,
                    onToggleEnabled: _sources[i].isProvider
                        ? null
                        : (v) => unawaited(_toggleEnabled(_sources[i], v)),
                    onPickShift: _sources[i].isProvider ? null : () => unawaited(_pickShift(_sources[i])),
                    onMoveUp: () => unawaited(_move(_sources[i], -1)),
                    onMoveDown: () => unawaited(_move(_sources[i], 1)),
                    onDelete: _sources[i].isProvider ? null : () => unawaited(_delete(_sources[i])),
                  ),
                ],
              ),
            ),
          ),
          // 1.3.28: one-tap preset guides — shown only while a preset
          // is not yet added for this connection. The tile says what
          // the guide covers and what it does not, in plain words.
          if (_missingPresets.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
              sliver: SliverToBoxAdapter(
                child: SettingsGroup(
                  title: t.iptv.epgPresetSectionTitle,
                  children: [
                    for (final preset in _missingPresets)
                      SettingNavigationTile(
                        icon: Symbols.add_circle_outline_rounded,
                        title: preset.name,
                        subtitle: preset.description,
                        onTap: () => unawaited(_addPreset(preset)),
                      ),
                  ],
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
            sliver: SliverToBoxAdapter(
              child: SettingsGroup(
                title: t.iptv.epgDetailsTitle,
                children: [
                  SettingNavigationTile(
                    icon: Symbols.refresh_rounded,
                    title: t.iptv.epgReloadTvDetails,
                    // 1.2.19 (L-3): while a feed download is in flight
                    // the row shows live bytes instead of the static
                    // description — a stalled 88 MB feed no longer
                    // looks like a dead tap.
                    subtitle: _reloading && _feedProgress != null
                        ? _feedProgressLine(_feedProgress!)
                        : t.iptv.epgReloadTvDetailsDescription,
                    // 1.2.3: visible working feedback while the reload
                    // runs — the row shows a spinner until the report
                    // appears, so the tap never looks dead.
                    trailing: _reloading
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : null,
                    onTap: () => unawaited(_reloadTvDetails()),
                  ),
                  SettingNavigationTile(
                    icon: Symbols.help_outline_rounded,
                    title: t.iptv.epgNoGuideTitle,
                    subtitle: t.iptv.epgNoGuideDescription,
                    onTap: () {
                      final support = _boundSupport();
                      if (support == null) return;
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => IptvEpgNoGuideScreen(support: support)),
                      );
                    },
                  ),
                  // 1.2.15 R2: one-time M3U tvg-id check — fetches the
                  // provider's playlist once and reports how many
                  // channels without a guide ID gain one from it. A
                  // diagnostic only: it never changes matching, and it
                  // never runs on its own (the playlist is tens of MB).
                  // 1.3.27 §P0-1: while a check runs the subtitle shows
                  // live bytes instead of the static description.
                  SettingNavigationTile(
                    icon: Symbols.fact_check_rounded,
                    title: t.iptv.epgM3uTvgIdCheck,
                    subtitle: _checkingM3uTvgIds && _m3uCheckProgress != null
                        ? _m3uCheckProgressLine(_m3uCheckProgress!)
                        : t.iptv.epgM3uTvgIdCheckDescription,
                    trailing: _checkingM3uTvgIds
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : null,
                    onTap: () => unawaited(_checkM3uTvgIds()),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }
}

/// One source row: name + URL, a status chip, an enable switch, the
/// per-source time shift, and (for added sources) reorder + delete.
class _SourceTile extends StatelessWidget {
  final IptvEpgSourceConfig source;
  final IptvEpgSourceStatus status;
  final String statusLabel;
  final Color statusColor;
  final String? statusDetail;
  final bool canMoveUp;
  final bool canMoveDown;
  final ValueChanged<bool>? onToggleEnabled;
  final VoidCallback? onPickShift;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback? onDelete;

  const _SourceTile({
    required this.source,
    required this.status,
    required this.statusLabel,
    required this.statusColor,
    required this.statusDetail,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.onToggleEnabled,
    required this.onPickShift,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      leading: AppIcon(source.isProvider ? Symbols.rss_feed_rounded : Symbols.link_rounded, fill: 1),
      title: Text(source.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (source.url != null) Text(source.url!, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(statusLabel, style: theme.textTheme.bodySmall?.copyWith(color: statusColor)),
          ),
        ],
      ),
      trailing: onToggleEnabled == null
          ? null
          : Switch(value: source.enabled, onChanged: onToggleEnabled),
      children: [
        if (statusDetail != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(statusDetail!, style: theme.textTheme.bodySmall),
            ),
          ),
        if (onPickShift != null)
          ListTile(
            leading: const AppIcon(Symbols.timelapse_rounded),
            title: Text(t.iptv.epgTimeShift),
            subtitle: Text(
              source.timeShiftMinutes == null
                  ? t.iptv.epgNoOffset
                  : t.iptv.epgOffsetMinutes(n: source.timeShiftMinutes!),
            ),
            onTap: onPickShift,
          ),
        if (!source.isProvider)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              children: [
                IconButton(
                  icon: const AppIcon(Symbols.arrow_upward_rounded),
                  tooltip: t.iptv.epgSourceMoveUp,
                  onPressed: canMoveUp ? onMoveUp : null,
                ),
                IconButton(
                  icon: const AppIcon(Symbols.arrow_downward_rounded),
                  tooltip: t.iptv.epgSourceMoveDown,
                  onPressed: canMoveDown ? onMoveDown : null,
                ),
                const Spacer(),
                IconButton(
                  icon: const AppIcon(Symbols.delete_rounded),
                  tooltip: t.iptv.epgSourceDelete,
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
