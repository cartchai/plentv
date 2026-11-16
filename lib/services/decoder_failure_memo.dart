import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'base_shared_preferences_service.dart';

/// Decoder-failure memo (1.2.18 C-10): never re-pay a known-bad channel's
/// format rejection.
///
/// When the mpv plane rejects a file's format, the session rebuilds the
/// whole video chain on the GL vo and seeks — a CPU spike plus added zap
/// latency, every time the channel is tuned. The memo remembers channels
/// that reject twice in a row and starts them on the GL vo (`vo=gpu` at
/// open) instead, where mpv still tries hardware decode inside it
/// (`mediacodec-copy`) and only falls to full software if that fails too.
///
/// Rules, per the report: memo after 2 consecutive rejections; entries
/// expire after 7 days (a provider re-encode makes a stale memo merely
/// suboptimal, never broken); a clean hardware decode
/// (`hwdec-current=mediacodec`) clears the channel's count; never memo
/// software decode as permanent. The codec is deliberately not stored:
/// the decision is per channel, not per codec.
///
/// The in-memory map is the source of truth; SharedPreferences holds the
/// durable copy as one JSON blob. Reads are synchronous off memory;
/// writes update memory first, then persist fire-and-forget.
class DecoderFailureMemo extends BaseSharedPreferencesService {
  DecoderFailureMemo._();

  static const String _prefsKey = 'decoder_failure_memo_v1';

  /// Rejections needed before a channel starts on the GL vo.
  static const int failureThreshold = 2;

  /// A memo older than this is dropped on read (provider re-encodes).
  static const Duration memoTtl = Duration(days: 7);

  static DecoderFailureMemo? _cachedInstance;

  static Future<DecoderFailureMemo> getInstance() async {
    final memo = await BaseSharedPreferencesService.initializeInstance(
      () => DecoderFailureMemo._(),
    );
    _cachedInstance = memo;
    return memo;
  }

  /// Synchronous access once [getInstance] has run (the live screen
  /// awaits it before opening). Null before then — callers treat that
  /// as "no memo", never as an error.
  static DecoderFailureMemo? get instanceOrNull => _cachedInstance;

  /// The channel currently playing live (or the VOD item — 1.2.22
  /// §63.3 keys VOD by `vod:<serverId>:<itemId>`), set by the player
  /// screen at open and cleared when it disposes. The rejection event
  /// carries no identity of its own, so this is how the player
  /// attributes it. Null outside playback.
  static String? currentChannelKey;

  @visibleForTesting
  static void debugResetForTesting() {
    _cachedInstance = null;
    currentChannelKey = null;
  }

  final Map<String, _MemoEntry> _entries = {};

  @override
  Future<void> onInit() async {
    _entries.clear();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      for (final entry in decoded.entries) {
        final value = entry.value;
        if (value is! Map<String, dynamic>) continue;
        final failures = value['failures'];
        final lastRejectedAtMs = value['lastRejectedAtMs'];
        if (failures is! int || lastRejectedAtMs is! int) continue;
        _entries[entry.key] = _MemoEntry(
          failures: failures,
          lastRejectedAtMs: lastRejectedAtMs,
        );
      }
    } catch (_) {
      // A corrupt blob must not take the memo down — start empty.
      _entries.clear();
    }
    _pruneExpired(DateTime.now());
  }

  /// Whether [channelKey] has earned the GL-vo start (threshold met, not expired).
  bool shouldStartOnGlVo(String channelKey) {
    _pruneExpired(DateTime.now());
    final entry = _entries[channelKey];
    return entry != null && entry.failures >= failureThreshold;
  }

  /// Record one format rejection for [channelKey].
  Future<void> recordRejection(String channelKey) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final previous = _entries[channelKey];
    _entries[channelKey] = _MemoEntry(
      failures: (previous?.failures ?? 0) + 1,
      lastRejectedAtMs: nowMs,
    );
    _pruneExpired(DateTime.now());
    await _persist();
  }

  /// A clean hardware decode clears the channel's count: the plane works
  /// for it again, so the memo must not keep forcing the GL vo.
  Future<void> recordSuccess(String channelKey) async {
    if (_entries.remove(channelKey) == null) return;
    await _persist();
  }

  /// Manual reset (Settings): forget every saved decoder choice.
  Future<void> clearAll() async {
    _entries.clear();
    await prefs.remove(_prefsKey);
  }

  /// Test-only read of the live failure count (0 when absent/expired).
  @visibleForTesting
  int debugFailuresFor(String channelKey) {
    _pruneExpired(DateTime.now());
    return _entries[channelKey]?.failures ?? 0;
  }

  void _pruneExpired(DateTime now) {
    final cutoffMs = now.subtract(memoTtl).millisecondsSinceEpoch;
    _entries.removeWhere((_, entry) => entry.lastRejectedAtMs < cutoffMs);
  }

  Future<void> _persist() async {
    final encoded = jsonEncode({
      for (final entry in _entries.entries)
        entry.key: {
          'failures': entry.value.failures,
          'lastRejectedAtMs': entry.value.lastRejectedAtMs,
        },
    });
    await prefs.setString(_prefsKey, encoded);
  }
}

class _MemoEntry {
  const _MemoEntry({required this.failures, required this.lastRejectedAtMs});

  final int failures;
  final int lastRejectedAtMs;
}
