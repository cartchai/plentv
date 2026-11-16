import 'dart:io';

/// PSS + VmHWM + swap in the dump (L-54 / T4-5).
///
/// The dump reports RSS only. RSS overcounts shared pages, so a Fold RSS
/// and a Hisense RSS are not directly comparable, and ZRAM swap (where a
/// pressured TV hides memory) is invisible. This reads both halves with
/// no platform channel:
///
/// * `/proc/self/status` — VmHWM (peak virtual memory, the true peak),
///   VmRSS, RssAnon, RssFile, VmSwap. `VmHWM` must agree with
///   `ProcessInfo.maxRss` — if it doesn't, one of them is wrong and
///   that itself is a finding.
/// * `/proc/self/smaps_rollup` — Pss (proportional set size, the number
///   that matters for LMK: shared pages counted once, proportionally).
///
/// Read at export time only, never sampled continuously. Every read is
/// best-effort: off-Android (or a locked-down kernel) yields nulls and
/// the dump says 'unavailable' instead of crashing.
class ProcMemorySnapshot {
  const ProcMemorySnapshot({
    this.pssKb,
    this.vmHwmKb,
    this.vmRssKb,
    this.rssAnonKb,
    this.rssFileKb,
    this.vmSwapKb,
  });

  final int? pssKb;
  final int? vmHwmKb;
  final int? vmRssKb;
  final int? rssAnonKb;
  final int? rssFileKb;
  final int? vmSwapKb;

  bool get isEmpty =>
      pssKb == null &&
      vmHwmKb == null &&
      vmRssKb == null &&
      rssAnonKb == null &&
      rssFileKb == null &&
      vmSwapKb == null;

  /// Parse `/proc/self/status` text. Keys are `kB` values.
  static ProcMemorySnapshot parseStatus(String content) {
    int? read(String key) {
      for (final line in content.split('\n')) {
        if (!line.startsWith(key)) continue;
        final parts = line.split(':');
        if (parts.length < 2) return null;
        final value = parts[1].trim().split(RegExp(r'\s+')).firstOrNull;
        return int.tryParse(value ?? '');
      }
      return null;
    }

    return ProcMemorySnapshot(
      vmHwmKb: read('VmHWM'),
      vmRssKb: read('VmRSS'),
      rssAnonKb: read('RssAnon'),
      rssFileKb: read('RssFile'),
      vmSwapKb: read('VmSwap'),
    );
  }

  /// Parse `/proc/self/smaps_rollup` text (one `Pss:` line for the
  /// whole process).
  static int? parseSmapsRollupPssKb(String content) {
    for (final line in content.split('\n')) {
      if (!line.startsWith('Pss:')) continue;
      final parts = line.split(':');
      if (parts.length < 2) return null;
      final value = parts[1].trim().split(RegExp(r'\s+')).firstOrNull;
      return int.tryParse(value ?? '');
    }
    return null;
  }

  /// Read both files synchronously (export-time only) and merge them.
  /// Never throws — returns an empty snapshot on any failure.
  static ProcMemorySnapshot readSync() {
    var status = const ProcMemorySnapshot();
    int? pssKb;
    try {
      final statusText = File('/proc/self/status').readAsStringSync();
      status = parseStatus(statusText);
    } catch (_) {
      // Off-Android / unreadable: the dump reports 'unavailable'.
    }
    try {
      final rollup = File('/proc/self/smaps_rollup').readAsStringSync();
      pssKb = parseSmapsRollupPssKb(rollup);
    } catch (_) {
      // smaps_rollup needs no privilege for self, but a locked-down
      // kernel may still refuse it.
    }
    return ProcMemorySnapshot(
      pssKb: pssKb,
      vmHwmKb: status.vmHwmKb,
      vmRssKb: status.vmRssKb,
      rssAnonKb: status.rssAnonKb,
      rssFileKb: status.rssFileKb,
      vmSwapKb: status.vmSwapKb,
    );
  }

  static String _mb(int? kb) => kb == null ? 'unavailable' : '${(kb / 1024).toStringAsFixed(1)} MB ($kb kB)';

  /// Dump lines, in the same shape as the existing Memory section.
  /// Gate on RSS, compare on PSS — the dump carries both so the next
  /// verdict can do each correctly.
  String renderLines() {
    if (isEmpty) return 'PSS / VmHWM / swap: unavailable (not Android, or /proc unreadable)';
    return [
      'PSS: ${_mb(pssKb)}',
      'VmHWM: ${_mb(vmHwmKb)}',
      'VmSwap: ${_mb(vmSwapKb)}',
      'RssAnon: ${_mb(rssAnonKb)}',
      'RssFile: ${_mb(rssFileKb)}',
    ].join('\n');
  }

  Map<String, Object?> toJson() => {
    'pssKb': pssKb,
    'vmHwmKb': vmHwmKb,
    'vmRssKb': vmRssKb,
    'rssAnonKb': rssAnonKb,
    'rssFileKb': rssFileKb,
    'vmSwapKb': vmSwapKb,
  };
}
