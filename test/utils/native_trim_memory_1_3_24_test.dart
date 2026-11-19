import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/native_trim_memory.dart';

/// 1.3.24 §67 F4 — the level-20 trim keeps the EPG guide on full-tier
/// devices with comfortable RSS.
///
/// Level 20 (UI hidden) is NOT memory pressure: it fires on every
/// app-switch, and dropping the guide there means the next guide open
/// re-downloads the feed. The gate keeps the guide only when all three
/// hold: the level is exactly UI-hidden, the device is full-tier (not
/// low-end), and RSS is below the watchdog threshold. Genuinely
/// critical trims and hot RSS still drop it.
///
/// Failing-first on the 1.3.23 base (92a82e6e1): the helper does not
/// exist, so this file fails to load there.

void main() {
  group('keepEpgOnTrim (1.3.24 §67 F4)', () {
    const fullTierRss = 350 << 20;
    const watchdogThreshold = 1536 << 20;

    test('level 20 + full-tier + comfortable RSS keeps the guide', () {
      expect(
        keepEpgOnTrim(
          level: trimMemoryUiHidden,
          isFullTier: true,
          rssBytes: fullTierRss,
          rssHotThresholdBytes: watchdogThreshold,
        ),
        isTrue,
      );
    });

    test('a critical trim drops the guide even on a full-tier device', () {
      expect(
        keepEpgOnTrim(
          level: 15,
          isFullTier: true,
          rssBytes: fullTierRss,
          rssHotThresholdBytes: watchdogThreshold,
        ),
        isFalse,
        reason: 'RUNNING_CRITICAL is genuine pressure, not an app-switch',
      );
    });

    test('a background trim drops the guide', () {
      expect(
        keepEpgOnTrim(
          level: 40,
          isFullTier: true,
          rssBytes: fullTierRss,
          rssHotThresholdBytes: watchdogThreshold,
        ),
        isFalse,
      );
    });

    test('a low-end device drops the guide at level 20', () {
      expect(
        keepEpgOnTrim(
          level: trimMemoryUiHidden,
          isFullTier: false,
          rssBytes: fullTierRss,
          rssHotThresholdBytes: watchdogThreshold,
        ),
        isFalse,
        reason: 'the L-14 T0–T2 background shed is unchanged',
      );
    });

    test('hot RSS drops the guide at level 20', () {
      expect(
        keepEpgOnTrim(
          level: trimMemoryUiHidden,
          isFullTier: true,
          rssBytes: watchdogThreshold,
          rssHotThresholdBytes: watchdogThreshold,
        ),
        isFalse,
        reason: 'RSS at the watchdog threshold is hot, not comfortable',
      );
    });

    test('a running-moderate trim never keeps the guide (images only)', () {
      expect(
        keepEpgOnTrim(
          level: trimMemoryRunningModerate,
          isFullTier: true,
          rssBytes: fullTierRss,
          rssHotThresholdBytes: watchdogThreshold,
        ),
        isFalse,
      );
    });
  });

  group('keepEpgOnComfortableMemory (1.4.5 F3)', () {
    const fullTierRss = 350 << 20;
    const watchdogThreshold = 1536 << 20;

    test('full-tier + comfortable RSS keeps the guide', () {
      expect(
        keepEpgOnComfortableMemory(
          isFullTier: true,
          rssBytes: fullTierRss,
          rssHotThresholdBytes: watchdogThreshold,
        ),
        isTrue,
        reason: 'the didHaveMemoryPressure callback gates on this, like the level-20 trim',
      );
    });

    test('a low-end device sheds everything', () {
      expect(
        keepEpgOnComfortableMemory(
          isFullTier: false,
          rssBytes: fullTierRss,
          rssHotThresholdBytes: watchdogThreshold,
        ),
        isFalse,
        reason: 'genuine pressure on low-end devices must still shed everything',
      );
    });

    test('hot RSS sheds everything even on a full-tier device', () {
      expect(
        keepEpgOnComfortableMemory(
          isFullTier: true,
          rssBytes: watchdogThreshold,
          rssHotThresholdBytes: watchdogThreshold,
        ),
        isFalse,
        reason: 'RSS at the watchdog threshold is hot, not comfortable',
      );
    });

    test('one byte below the threshold still keeps the guide', () {
      expect(
        keepEpgOnComfortableMemory(
          isFullTier: true,
          rssBytes: watchdogThreshold - 1,
          rssHotThresholdBytes: watchdogThreshold,
        ),
        isTrue,
      );
    });
  });
}
