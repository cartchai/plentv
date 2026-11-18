import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../i18n/strings.g.dart';
import '../utils/log_redaction_manager.dart';
import '../utils/platform_detector.dart';
import '../utils/startup_phase_timings.dart';
import 'device_performance.dart';
import '../utils/last_decode_stats.dart';
import 'downloads_media_store.dart';
import 'file_picker_service.dart';
import 'iptv/iptv_refusal_log.dart';
import 'last_crash_store.dart';
import 'lowend/frame_time_collector.dart';
import 'lowend/phase_rss_sampler.dart';
import 'lowend/proc_memory.dart';
import 'lowend/relief_log.dart';
import 'lowend/slow_op_log.dart';
import 'main_thread_watchdog.dart';
import 'sensitive_prefs.dart';
import 'settings_export_service.dart';
import 'settings_service.dart';
import 'storage_health.dart';
import 'storage_service.dart';

/// Debug log export (1.2.6, the owner ~2026-11-13 16:25 EST): one file with
/// all settings, logs, errors and app info, saved from Settings → Logs.
/// The caller passes the already-formatted logs text ([buildDebugText]
/// appends the settings, memory and last-crash sections to it); the app
/// version + device + startup record come from that base text, so they
/// are not duplicated here.
///
/// Privacy (standing Trex ban): the file must NEVER carry the panel
/// address or login. Three layers: the settings section is built only
/// from the closed portable registry ([SettingsExportService
/// .buildExportMap] — endpoints and credentials are never in it), the
/// renderer drops sensitive keys and withholds URL-looking values, and
/// the whole file goes through [LogRedactionManager.redact] before it
/// is written.
class DebugLogExportService {
  /// File name for the export, e.g. `pleztv-debug-20261113-204500.txt`.
  @visibleForTesting
  static String debugFileName([DateTime? now]) {
    final t = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'pleztv-debug-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}.txt';
  }

  /// Render the settings export map as `key: value` lines, sorted by
  /// key, with the `prefs` map rendered one level indented. Pure and
  /// testable. Keys the sensitive-prefs list names never render, and
  /// any string value that looks like a URL (a server address that
  /// slipped into a portable string pref) renders as `[URL withheld]`
  /// instead of the address itself.
  @visibleForTesting
  static String renderSettingsSection(Map<String, dynamic> exportMap) {
    final lines = <String>[];
    final keys = exportMap.keys.toList()..sort();
    for (final key in keys) {
      final value = exportMap[key];
      if (value is Map) {
        lines.add('$key:');
        final subKeys = value.keys.map((k) => '$k').toList()..sort();
        for (final subKey in subKeys) {
          if (isSensitivePrefKey(subKey)) continue;
          lines.add('  $subKey: ${_renderSettingValue(value[subKey])}');
        }
      } else {
        lines.add('$key: ${_renderSettingValue(value)}');
      }
    }
    return lines.join('\n');
  }

  static String _renderSettingValue(Object? value) {
    if (value is Map && value.containsKey('value')) {
      final inner = _renderSettingValue(value['value']);
      final type = value['type'];
      return type == null ? inner : '$inner ($type)';
    }
    if (value is String && value.contains('://')) return '[URL withheld]';
    // 1.2.7 (T4b): a URL-looking element inside a List value is
    // withheld the same way — a list of server addresses is still a
    // list of server addresses.
    if (value is List) {
      return jsonEncode(
        value.map((e) => e is String && e.contains('://') ? '[URL withheld]' : e).toList(),
      );
    }
    return '$value';
  }

  /// The settings section, from the live portable prefs.
  static Future<String> buildSettingsSection() async {
    final prefs = (await SettingsService.getInstance()).prefs;
    final storage = await StorageService.getInstance();
    String appVersion = '';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = info.version;
    } on Exception {
      // Best-effort metadata; platforms without PackageInfo (and unit
      // tests, where the plugin channel has no implementation) still
      // export.
    }
    final exportMap = SettingsExportService.buildExportMap(
      prefs,
      currentUserUuid: storage.activeUserScope(),
      appVersion: appVersion,
    );
    return renderSettingsSection(exportMap);
  }

  /// Current memory numbers: RSS now/max and device RAM, plus the
  /// low-end flag the bind gate reads. The startup RSS and pressure
  /// history live in the base logs text already. PSS + VmHWM + swap
  /// (L-54) are appended from /proc — gate on RSS, compare on PSS.
  static String buildMemorySection() {
    final rss = ProcessInfo.currentRss;
    final maxRss = ProcessInfo.maxRss;
    final totalMem = DevicePerformance.totalMemBytes;
    final lines = <String>[
      'RSS now: ${rss >> 20} MB ($rss bytes)',
      'RSS max: ${maxRss >> 20} MB ($maxRss bytes)',
      'Device total RAM: ${totalMem == null ? 'unknown' : '${totalMem >> 20} MB ($totalMem bytes)'}',
      'Low-end hardware: ${DevicePerformance.isLowEndHardware}',
      buildTierLine(),
      ProcMemorySnapshot.readSync().renderLines(),
    ];
    return lines.join('\n');
  }

  /// Tier fingerprint (L-50 / T4-1): one line answering "which tier,
  /// and why" without asking the owner. Built from
  /// [DevicePerformance.debugSummary] — the dump never re-implements
  /// detection. `unknown` values mean detection has not run (or the
  /// native side did not send the signal) on this launch.
  static String buildTierLine() {
    final s = DevicePerformance.debugSummary;
    String v(Object? value, [String unit = '']) =>
        value == null ? 'unknown' : '$value$unit';
    final tier = s['tier'];
    final mem = s['totalMemMb'];
    final lowRam = s['isLowRamDevice'];
    final bitness = s['is64Bit'];
    final heap = s['heapClassMb'];
    final sdk = s['sdkInt'];
    final width = s['displayWidth'];
    final height = s['displayHeight'];
    final dpr = s['dpr'];
    final free = s['freeStorageMb'];
    final display = width == null || height == null
        ? 'unknown'
        : '${width}x$height @ ${dpr is num ? dpr.toStringAsFixed(2) : 'unknown'}x';
    return 'Tier: ${tier ?? 'unknown'} — total RAM ${v(mem, ' MB')} — lowRam ${v(lowRam)} — '
        '${bitness == null ? 'unknown bitness' : (bitness == true ? '64-bit' : '32-bit')} — '
        'heap class ${v(heap, ' MB')} — API ${v(sdk)} — display $display — '
        'free storage ${v(free, ' MB')}';
  }

  /// The last recorded crash, or that none was recorded.
  static Future<String> buildLastCrashSection() async {
    final record = await LastCrashStore.read();
    return record?.describe() ?? 'none recorded';
  }

  /// One line identifying the app + device for the summary block.
  /// Best-effort: on a platform without the device-info channel (and in
  /// unit tests) it falls back to 'unknown' rather than throwing.
  static Future<String> buildDeviceLine() async {
    String appVersion = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      appVersion = '${info.version}+${info.buildNumber}';
    } catch (_) {
      // Best-effort metadata.
    }
    String device = 'unknown device';
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final android = await plugin.androidInfo;
        device = '${android.manufacturer} ${android.model} — Android ${android.version.release} (API ${android.version.sdkInt})';
      } else if (Platform.isIOS) {
        final ios = await plugin.iosInfo;
        device = '${ios.model} — iOS ${ios.systemVersion}';
      } else {
        device = Platform.operatingSystem;
      }
    } catch (_) {
      // Best-effort metadata.
    }
    return 'App: PlezTV $appVersion — $device';
  }

  /// One-line memory numbers for the summary block (the full numbers
  /// stay in [buildMemorySection] below, unchanged).
  static String buildMemorySummaryLine() {
    final rss = ProcessInfo.currentRss;
    final maxRss = ProcessInfo.maxRss;
    final totalMem = DevicePerformance.totalMemBytes;
    return 'Memory: RSS now: ${rss >> 20} MB / max: ${maxRss >> 20} MB — device total RAM: ${totalMem == null ? 'unknown' : '${totalMem >> 20} MB'} — low-end: ${DevicePerformance.isLowEndHardware}';
  }

  /// Memory-pressure events in the log: the watchdog's 'RSS high'
  /// drop line (one per trip — the image-cache line from the same trip
  /// is not a second event) plus the OS pressure line. The worst RSS
  /// comes from the watchdog lines.
  static String buildPressureSummaryLine(String baseLogsText) {
    var events = 0;
    var worstRssMb = 0;
    for (final line in baseLogsText.split('\n')) {
      if (line.contains('System memory pressure')) {
        events++;
      } else if (line.contains('RSS high (') && line.contains('dropped IPTV catalogs')) {
        events++;
        final match = RegExp(r'RSS high \((\d+)MB').firstMatch(line);
        if (match != null) {
          final rss = int.tryParse(match.group(1)!) ?? 0;
          if (rss > worstRssMb) worstRssMb = rss;
        }
      }
    }
    if (events == 0) return 'Memory pressure: none recorded';
    return 'Memory pressure: $events events, worst RSS $worstRssMb MB';
  }

  /// The previous exit reason, from the last 'Previous Android
  /// application exit' line in the log (the whole line — it already
  /// carries the startup phase and RSS).
  ///
  /// 1.2.22 §63.6: [previousExitReport] is the report main() read
  /// BEFORE the saver decision — it wins over the log scan, because on
  /// a saver launch [AndroidExitDiagnostics.logPreviousExit] never runs
  /// and the log's last line is stale (the exit before last).
  /// 1.2.22 §66 (U4): the crash-reporting setting is gone (Sentry is
  /// cut), so the report is always included — there is no "off" state
  /// to stamp any more.
  static String buildPreviousExitSummaryLine(
    String baseLogsText, {
    Map<String, Object?>? previousExitReport,
  }) {
    if (previousExitReport != null) {
      return 'Previous exit: ${formatPreviousExitReport(previousExitReport)}';
    }
    const prefix = 'Previous Android application exit: ';
    String? last;
    for (final line in baseLogsText.split('\n')) {
      final index = line.indexOf(prefix);
      if (index != -1) last = line.substring(index + prefix.length).trim();
    }
    if (last == null || last.isEmpty) return 'Previous exit: none recorded';
    return 'Previous exit: $last';
  }

  /// The one-line form of a previous-exit report — the same fields the
  /// log line carries, so the fresh report and the log scan read alike.
  static String formatPreviousExitReport(Map<String, Object?> report) {
    return 'reason=${report['reason']} status=${report['status']} '
        'importance=${report['importance']} timestamp=${report['timestamp']} '
        'deviceModel=${report['deviceModel']} apiLevel=${report['apiLevel']} '
        'abi=${report['abi']} lowRam=${report['lowRam']} '
        'startupPhase=${report['startupPhase'] ?? 'omitted'} '
        'description=${report['description'] ?? 'omitted'} '
        'pssKb=${report['pssKb'] ?? 'omitted'} rssKb=${report['rssKb'] ?? 'omitted'} '
        'codecContext=${report['codecContext'] ?? 'omitted'} '
        'channels=${report['channelCount'] ?? 'omitted'} sampleRate=${report['sampleRate'] ?? 'omitted'} '
        'decoder=${report['selectedDecoder'] ?? 'omitted'} '
        'passthrough=${report['passthroughEnabled'] ?? 'omitted'} '
        'downmix=${report['downmixEnabled'] ?? 'omitted'} '
        'normalization=${report['normalizationEnabled'] ?? 'omitted'} '
        'uiState=${report['uiState'] ?? 'omitted'}';
  }

  /// The last recorded crash, one line: when + error type + short message.
  static Future<String> buildLastCrashSummaryLine() async {
    final record = await LastCrashStore.read();
    if (record == null) return 'Last crash: none recorded';
    final firstLine = record.message.split('\n').first;
    final short = firstLine.length > 120 ? '${firstLine.substring(0, 120)}…' : firstLine;
    return 'Last crash: ${record.timestamp.toUtc().toIso8601String()} [${record.source}] ${record.errorType}: $short';
  }

  /// The summary block (1.2.9, the owner ~2026-11-14 02:14 EST): the facts
  /// someone opens the file to find, at the very top, before the log —
  /// so the file is easy to access without scrolling through hundreds
  /// of lines. One line each; the sections below stay unchanged.
  static Future<String> buildSummarySection({
    required String baseLogsText,
    required String dumpReason,
    required int failedStarts,
    // 1.2.22 §63.6: the fresh previous-exit report (main()'s early read)
    // and the previous run's watchdog ring — both optional, both prefer
    // fresh evidence over the log scan.
    Map<String, Object?>? previousExitReport,
    List<({DateTime at, String label})>? watchdogRing,
  }) async {
    final previousExitReason = await LastCrashStore.readPreviousExitReason();
    final lines = <String>[
      '== Summary ==',
      await buildDeviceLine(),
      buildTierLine(),
      buildMemorySummaryLine(),
      LastDecodeStats.summaryLine(),
      buildPressureSummaryLine(baseLogsText),
      ReliefLog.summarizeLogText(baseLogsText),
      SlowOpLog.summarizeLogText(baseLogsText),
      buildPreviousExitSummaryLine(
        baseLogsText,
        previousExitReport: previousExitReport,
      ),
      MainThreadWatchdog.summaryLine(watchdogRing ?? const []),
      await buildLastCrashSummaryLine(),
      await buildRefusalSummaryLine(),
      'Failed starts: $failedStarts — $dumpReason${previousExitReason == null ? '' : ' (last exit: $previousExitReason)'}',
    ];
    return lines.join('\n');
  }

  /// One line on the IPTV refusal log (1.4.3 D2): how many refusals
  /// are recorded and, for the latest, what it was and which network
  /// and address family it happened on — the family is the D2 point
  /// (a 403 that only happens on IPv6 reads differently from one on
  /// both families). Reads the persisted log directly, so it reflects
  /// the newest entry even when the in-memory singleton has not
  /// loaded it yet. Never throws: an unreadable log reports itself.
  static Future<String> buildRefusalSummaryLine() async {
    try {
      final entries = await IptvRefusalLog().loadEntries();
      if (entries.isEmpty) return 'IPTV refusals: none recorded';
      final latest = entries.first;
      final status = latest.statusCode == null ? latest.failureKind : 'HTTP ${latest.statusCode}';
      return 'IPTV refusals: ${entries.length} recorded, latest $status on ${latest.network} (${latest.addressFamily})';
    } catch (_) {
      return 'IPTV refusals: unreadable';
    }
  }

  /// The log tail for the dump, capped at [StorageHealth
  /// .dumpLogTailCapBytes] (L-21, T2-22).
  ///
  /// The rolling log is 2 MB x 2 on disk plus a 5 MB memory buffer, so
  /// the uncapped dump assembled ~2x its size resident (one StringBuffer
  /// + one UTF-8 byte copy) and, on a nearly-full disk, failed to save
  /// with only a generic "save failed". The summary block (built from
  /// the FULL log before this runs) carries the verdicts — the worst
  /// RSS, the pressure events, the previous exit, the last crash — so
  /// the tail is evidence, not the verdict. Cut at a line boundary;
  /// the returned [trimmed] says whether anything was cut, so the
  /// caller can say so in the file. Pure and testable.
  ///
  /// Walks UTF-16 units backwards and counts UTF-8 bytes per unit, so
  /// the full text is never encoded to measure it (encoding it would be
  /// the second resident copy this cap exists to avoid).
  @visibleForTesting
  static ({String text, bool trimmed}) capLogTail(String text, int maxBytes) {
    if (maxBytes <= 0) return (text: '', trimmed: text.isNotEmpty);
    var bytes = 0;
    var i = text.length;
    while (i > 0 && bytes < maxBytes) {
      final unit = text.codeUnitAt(i - 1);
      if (unit >= 0xDC00 && unit <= 0xDFFF && i >= 2) {
        // Low surrogate: the pair is one 4-byte rune.
        bytes += 4;
        i -= 2;
      } else if (unit < 0x80) {
        bytes += 1;
        i -= 1;
      } else if (unit < 0x800) {
        bytes += 2;
        i -= 1;
      } else {
        bytes += 3;
        i -= 1;
      }
    }
    if (i <= 0) return (text: text, trimmed: false);
    // Cut at the next line boundary so the tail starts on a whole line.
    final newline = text.indexOf('\n', i);
    final start = newline == -1 ? i : newline + 1;
    if (start >= text.length) return (text: '', trimmed: true);
    return (text: text.substring(start), trimmed: true);
  }

  /// The full debug file text: a summary block first, then the base logs
  /// text (device + app info + startup record + logs, errors and stack
  /// traces — the log tail CAPPED at [StorageHealth.dumpLogTailCapBytes],
  /// L-21), plus the settings, memory and last-crash sections. The whole
  /// file is redacted before it is returned, so a panel URL, token or
  /// password-like value that somehow reached the logs or the settings
  /// never lands in the file.
  ///
  /// 1.2.19 L-21 supersedes the 1.2.14 "nothing gets cut" rule for the
  /// log body: the summary (built from the FULL log, before the cap)
  /// still carries every verdict, and a trim note in the file says how
  /// much was cut. The cap also bounds the resident size: the text +
  /// its UTF-8 encoding is ~2x the file, so an uncapped 9 MB log held
  /// ~18 MB while saving — on the low-end device that crashes, that
  /// alone could be the second crash.
  ///
  /// [dumpReason] says why this file was written ('auto-dump after 3
  /// failed starts', or the manual-export default); [failedStarts]
  /// defaults to the live counter.
  static Future<String> buildDebugText({
    required String baseLogsText,
    String? dumpReason,
    int? failedStarts,
    // 1.2.22 §63.6: forwarded to the summary (see [buildSummarySection]).
    Map<String, Object?>? previousExitReport,
    List<({DateTime at, String label})>? watchdogRing,
  }) async {
    final reason = dumpReason ?? 'manual export from Settings → Logs';
    final count = failedStarts ?? await LastCrashStore.readFailedStartCount();
    // The summary reads the FULL log (pressure events, previous exit)
    // before the tail is capped — the verdicts survive the trim.
    final summary = await buildSummarySection(
      baseLogsText: baseLogsText,
      dumpReason: reason,
      failedStarts: count,
      previousExitReport: previousExitReport,
      watchdogRing: watchdogRing,
    );
    final tail = capLogTail(baseLogsText, StorageHealth.dumpLogTailCapBytes);
    final buffer = StringBuffer(summary);
    buffer.writeln();
    buffer.writeln();
    if (tail.trimmed) {
      buffer.writeln(
        '[log trimmed to the last ${StorageHealth.dumpLogTailCapBytes ~/ 1024} KB — older lines omitted; see the Summary above for the verdicts]',
      );
      buffer.writeln();
    }
    buffer.writeln(tail.text);
    buffer.writeln();
    buffer.writeln('== Settings ==');
    buffer.writeln(await buildSettingsSection());
    buffer.writeln();
    buffer.writeln('== Startup phases ==');
    buffer.writeln(StartupPhaseTimings.describe());
    buffer.writeln();
    buffer.writeln('== Memory ==');
    buffer.writeln(buildMemorySection());
    buffer.writeln();
    buffer.writeln('== Phase RSS ==');
    buffer.writeln(PhaseRssSampler.instance.renderTable());
    buffer.writeln();
    buffer.writeln('== Slow ops ==');
    buffer.writeln(SlowOpLog.summarizeLogText(baseLogsText));
    buffer.writeln();
    buffer.writeln('== Frame times ==');
    buffer.writeln(FrameTimeRegistry.renderSection());
    buffer.writeln();
    buffer.writeln('== Relief valve ==');
    buffer.writeln(ReliefLog.summarizeLogText(baseLogsText));
    buffer.writeln();
    buffer.writeln('== Last crash ==');
    buffer.writeln(await buildLastCrashSection());
    return LogRedactionManager.redact(buffer.toString());
  }

  /// Test seam: when set, the TV branch uses this instead of
  /// [PlatformDetector.isTV] — the host cannot be a TV.
  @visibleForTesting
  static bool? debugUseDownloadsOverride;

  /// Build the debug file and write it to a location of the user's
  /// choosing. Returns the saved path, or `null` if the user cancelled
  /// the picker. Same shape as [SettingsExportService.exportToFile]:
  /// Android TV has no document picker, so it writes to the shared
  /// Downloads collection first (1.2.21) and falls back to the app docs
  /// dir, and the caller surfaces the path.
  static Future<String?> exportToFile({required String baseLogsText}) async {
    final text = await buildDebugText(baseLogsText: baseLogsText);
    final bytes = Uint8List.fromList(utf8.encode(text));
    // L-21: never attempt a write that cannot fit. The dump is capped
    // (see [buildDebugText]), so its size is known here; when free
    // space is below it, fail before the picker opens instead of failing
    // mid-write with a generic error. Null is the existing "no file"
    // signal for this entry point (the emergency saver surfaces the
    // plain-words message via [AutoDumpService]).
    final free = await StorageHealth.freeBytes();
    if (free != null && free < bytes.length) {
      return null;
    }
    final fileName = debugFileName();

    // Android TV has no document picker — write to the shared Downloads
    // collection first (1.2.21: the app docs dir is invisible to the
    // user, so a TV export used to vanish), falling back to the app
    // docs dir when Downloads is unavailable.
    if (debugUseDownloadsOverride ?? (Platform.isAndroid && PlatformDetector.isTV())) {
      final downloadsPath = await DownloadsMediaStore.writeFile(
        fileName: fileName,
        bytes: bytes,
      );
      if (downloadsPath != null) return downloadsPath;
      return _writeToAppDocuments(fileName, bytes);
    }

    return FilePickerService.instance.saveFile(
      dialogTitle: t.logs.exportDebugDialogTitle,
      fileName: fileName,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const ['txt'],
    );
  }

  static Future<String> _writeToAppDocuments(String fileName, Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }
}
