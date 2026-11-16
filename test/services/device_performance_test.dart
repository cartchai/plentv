import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/device_performance.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    DevicePerformance.debugReset();
    addTearDown(DevicePerformance.debugReset);
  });

  test('concurrent callers wait for hardware detection', () async {
    final detection = Completer<void>();
    DevicePerformance.debugDetectionGate = detection.future;

    final first = DevicePerformance.getInstance(override: VisualEffectsSetting.reduced);
    var secondCompleted = false;
    final second = DevicePerformance.getInstance();
    unawaited(second.then((_) => secondCompleted = true));
    await Future<void>.delayed(Duration.zero);

    expect(secondCompleted, isFalse);
    detection.complete();

    final instances = await Future.wait([first, second]);
    expect(identical(instances.first, instances.last), isTrue);
    expect(DevicePerformance.isReduced, isTrue);
  });

  test('failed hardware detection can be retried', () async {
    DevicePerformance.debugDetectionGate = Future<void>.error(StateError('detection failed'));

    await expectLater(DevicePerformance.getInstance(), throwsStateError);

    DevicePerformance.debugDetectionGate = null;
    final recovered = await DevicePerformance.getInstance();
    expect(recovered, isNotNull);
  });

  group('tierForSignals (L-2)', () {
    test('MemTotal is the primary key', () {
      expect(DevicePerformance.tierForSignals(totalMemBytes: 1024 << 20), DeviceTier.survival);
      expect(DevicePerformance.tierForSignals(totalMemBytes: 1535 << 20), DeviceTier.survival);
      expect(DevicePerformance.tierForSignals(totalMemBytes: 1536 << 20), DeviceTier.low);
      expect(DevicePerformance.tierForSignals(totalMemBytes: 1900 << 20), DeviceTier.low);
      expect(DevicePerformance.tierForSignals(totalMemBytes: 2048 << 20), DeviceTier.standard);
      expect(DevicePerformance.tierForSignals(totalMemBytes: 2400 << 20), DeviceTier.standard);
      expect(DevicePerformance.tierForSignals(totalMemBytes: 3072 << 20), DeviceTier.mid);
      expect(DevicePerformance.tierForSignals(totalMemBytes: 3500 << 20), DeviceTier.mid);
      expect(DevicePerformance.tierForSignals(totalMemBytes: 4096 << 20), DeviceTier.full);
      expect(DevicePerformance.tierForSignals(totalMemBytes: 11264 << 20), DeviceTier.full);
    });

    test('isLowRamDevice caps the tier at low regardless of totalMem', () {
      expect(
        DevicePerformance.tierForSignals(totalMemBytes: 8192 << 20, isLowRamDevice: true),
        DeviceTier.low,
      );
      expect(
        DevicePerformance.tierForSignals(totalMemBytes: 3072 << 20, isLowRamDevice: true),
        DeviceTier.low,
      );
      // Below the cap it does not raise the tier.
      expect(
        DevicePerformance.tierForSignals(totalMemBytes: 1024 << 20, isLowRamDevice: true),
        DeviceTier.survival,
      );
    });

    test('bitness does not move the tier', () {
      // 32-bit 2.4 GiB Hisense lands in standard; 64-bit 1 GB stick in survival.
      expect(DevicePerformance.tierForSignals(totalMemBytes: 2400 << 20, is64Bit: false), DeviceTier.standard);
      expect(DevicePerformance.tierForSignals(totalMemBytes: 1024 << 20, is64Bit: true), DeviceTier.survival);
    });

    test('unknown totalMem falls back to standard, never full', () {
      expect(DevicePerformance.tierForSignals(), DeviceTier.standard);
      expect(DevicePerformance.tierForSignals(isLowRamDevice: true), DeviceTier.low);
    });

    test('T0-T2 map to reduced, T3-T4 do not', () {
      for (final tier in DeviceTier.values) {
        DevicePerformance.debugReset(tier: tier);
        expect(DevicePerformance.isLowEndHardware, tier.isReducedTier);
        expect(DevicePerformance.isReduced, tier.isReducedTier);
      }
    });
  });

  group('per-tier budgets (L-7 / L-10 / L-28 / L-37)', () {
    test('EPG window, cache entries and short-EPG fan-out per tier', () {
      const expected = {
        DeviceTier.survival: (0, 16, 1),
        DeviceTier.low: (16, 32, 1),
        DeviceTier.standard: (32, 64, 2),
        DeviceTier.mid: (64, 64, 2),
        DeviceTier.full: (64, 64, 4),
      };
      for (final entry in expected.entries) {
        DevicePerformance.debugReset(tier: entry.key);
        expect(DevicePerformance.epgWindowFeedIds, entry.value.$1, reason: '${entry.key} window');
        expect(DevicePerformance.epgCacheEntries, entry.value.$2, reason: '${entry.key} cache');
        expect(DevicePerformance.shortEpgFanOut, entry.value.$3, reason: '${entry.key} fan-out');
      }
    });

    test('image cache caps per tier', () {
      const expected = {
        DeviceTier.survival: (100, 16),
        DeviceTier.low: (200, 32),
        DeviceTier.standard: (400, 64),
        DeviceTier.mid: (500, 64),
      };
      for (final entry in expected.entries) {
        DevicePerformance.debugReset(tier: entry.key);
        expect(DevicePerformance.imageCacheMaxEntries, entry.value.$1);
        expect(DevicePerformance.imageCacheMaxBytes, entry.value.$2 << 20);
      }
      DevicePerformance.debugReset(tier: DeviceTier.full);
      expect(DevicePerformance.imageCacheMaxEntries, isNull);
      expect(DevicePerformance.imageCacheMaxBytes, isNull);
    });

    test('Skia cap per tier', () {
      DevicePerformance.debugReset(tier: DeviceTier.survival);
      expect(DevicePerformance.skiaResourceCacheMaxBytes, 24 << 20);
      for (final tier in [DeviceTier.low, DeviceTier.standard, DeviceTier.mid]) {
        DevicePerformance.debugReset(tier: tier);
        expect(DevicePerformance.skiaResourceCacheMaxBytes, 48 << 20, reason: '$tier');
      }
      DevicePerformance.debugReset(tier: DeviceTier.full);
      expect(DevicePerformance.skiaResourceCacheMaxBytes, isNull);
    });

    test('browse page size and search rank window per tier', () {
      const pages = {
        DeviceTier.survival: 50,
        DeviceTier.low: 100,
        DeviceTier.standard: 150,
        DeviceTier.mid: 200,
        DeviceTier.full: 200,
      };
      const ranks = {
        DeviceTier.survival: 2000,
        DeviceTier.low: 4000,
        DeviceTier.standard: 6000,
        DeviceTier.mid: 8000,
        DeviceTier.full: 8000,
      };
      for (final tier in DeviceTier.values) {
        DevicePerformance.debugReset(tier: tier);
        expect(DevicePerformance.browsePageSize, pages[tier]);
        expect(DevicePerformance.searchRankWindow, ranks[tier]);
      }
    });
  });

  group('effects defaults (L-38)', () {
    test('T0 effects off, T1 blur off but animations on, T2 half durations', () {
      DevicePerformance.debugReset(tier: DeviceTier.survival, override: VisualEffectsSetting.auto);
      expect(DevicePerformance.animationsEnabled, isFalse);
      expect(DevicePerformance.blurEnabled, isFalse);
      expect(DevicePerformance.animationDurationScale, 0.0);
      expect(DevicePerformance.reducedDuration(const Duration(milliseconds: 300)), Duration.zero);

      DevicePerformance.debugReset(tier: DeviceTier.low, override: VisualEffectsSetting.auto);
      expect(DevicePerformance.animationsEnabled, isTrue);
      expect(DevicePerformance.blurEnabled, isFalse);
      expect(DevicePerformance.animationDurationScale, 1.0);
      expect(
        DevicePerformance.reducedDuration(const Duration(milliseconds: 300)),
        const Duration(milliseconds: 300),
      );

      DevicePerformance.debugReset(tier: DeviceTier.standard, override: VisualEffectsSetting.auto);
      expect(DevicePerformance.animationsEnabled, isTrue);
      expect(DevicePerformance.blurEnabled, isTrue);
      expect(DevicePerformance.animationDurationScale, 0.5);
      expect(
        DevicePerformance.reducedDuration(const Duration(milliseconds: 300)),
        const Duration(milliseconds: 150),
      );

      for (final tier in [DeviceTier.mid, DeviceTier.full]) {
        DevicePerformance.debugReset(tier: tier, override: VisualEffectsSetting.auto);
        expect(DevicePerformance.animationsEnabled, isTrue, reason: '$tier');
        expect(DevicePerformance.blurEnabled, isTrue, reason: '$tier');
        expect(DevicePerformance.animationDurationScale, 1.0, reason: '$tier');
      }
    });

    test('user override beats the tier default', () {
      DevicePerformance.debugReset(tier: DeviceTier.survival, override: VisualEffectsSetting.full);
      expect(DevicePerformance.animationsEnabled, isTrue);
      expect(DevicePerformance.blurEnabled, isTrue);
      expect(DevicePerformance.animationDurationScale, 1.0);
      expect(DevicePerformance.isReduced, isFalse);

      DevicePerformance.debugReset(tier: DeviceTier.full, override: VisualEffectsSetting.reduced);
      expect(DevicePerformance.animationsEnabled, isFalse);
      expect(DevicePerformance.blurEnabled, isFalse);
      expect(DevicePerformance.animationDurationScale, 0.0);
      expect(DevicePerformance.isReduced, isTrue);
    });
  });

  group('debugSummary (L-19)', () {
    test('exposes the tier and the raw signals under the fixed keys', () {
      DevicePerformance.debugReset(
        tier: DeviceTier.low,
        totalMemBytes: 1900 << 20,
        isLowRam: true,
        is64Bit: false,
      );
      final summary = DevicePerformance.debugSummary;
      expect(summary.keys.toSet(), {
        'tier',
        'totalMemMb',
        'isLowRamDevice',
        'is64Bit',
        'heapClassMb',
        'sdkInt',
        'displayWidth',
        'displayHeight',
        'dpr',
        'freeStorageMb',
      });
      expect(summary['tier'], 'low');
      expect(summary['totalMemMb'], 1900);
      expect(summary['isLowRamDevice'], isTrue);
      expect(summary['is64Bit'], isFalse);
      // Signals never delivered in a unit test stay null, never throw.
      expect(summary['heapClassMb'], isNull);
      expect(summary['sdkInt'], isNull);
      expect(summary['freeStorageMb'], isNull);
    });
  });

  group('displayBudgetFactor', () {
    void detectAt(double shortestSide) {
      DevicePerformance.debugDisplayShortestSideOverride = shortestSide;
      DevicePerformance.debugDetectDisplayBudget();
    }

    test('stays 1.0 until a latch runs', () {
      DevicePerformance.debugReset(autoReduced: false, override: VisualEffectsSetting.auto);
      expect(DevicePerformance.displayBudgetFactor(), 1.0);
    });

    test('scales with the display shortest side up to 2x', () {
      DevicePerformance.debugReset(autoReduced: false, override: VisualEffectsSetting.auto);

      detectAt(1080);
      expect(DevicePerformance.displayBudgetFactor(), 1.0);

      detectAt(1440);
      expect(DevicePerformance.displayBudgetFactor(), closeTo(1440 / 1080, 0.001));

      detectAt(2160);
      expect(DevicePerformance.displayBudgetFactor(), 2.0);

      // 8K stays at the 2x ceiling.
      detectAt(4320);
      expect(DevicePerformance.displayBudgetFactor(), 2.0);
    });

    test('sub-1080p displays never shrink the budget below 1.0', () {
      DevicePerformance.debugReset(autoReduced: false, override: VisualEffectsSetting.auto);
      detectAt(720);
      expect(DevicePerformance.displayBudgetFactor(), 1.0);
    });

    test('mid-RAM hardware holds a 4K budget at 1.5x', () {
      DevicePerformance.debugReset(autoReduced: false, override: VisualEffectsSetting.auto, totalMemBytes: 3500 << 20);
      detectAt(2160);
      expect(DevicePerformance.displayBudgetFactor(), 1.5);
    });

    test('high-RAM hardware keeps the full 4K budget', () {
      DevicePerformance.debugReset(autoReduced: false, override: VisualEffectsSetting.auto, totalMemBytes: 5000 << 20);
      detectAt(2160);
      expect(DevicePerformance.displayBudgetFactor(), 2.0);
    });

    test('standard tier (2-3 GB) pins the budget to 1.0 even after a 4K latch', () {
      DevicePerformance.debugReset(autoReduced: false, override: VisualEffectsSetting.auto, totalMemBytes: 2400 << 20);
      detectAt(2160);
      expect(DevicePerformance.displayBudgetFactor(), 1.0);
    });

    test('reduced tier pins the budget to 1.0 even after a 4K latch', () {
      DevicePerformance.debugReset(autoReduced: true, override: VisualEffectsSetting.auto);
      detectAt(2160);
      expect(DevicePerformance.displayBudgetFactor(), 1.0);
    });
  });

  // Startup-group budgets ported at integration (L-8/L-14/L-15/L-61).
  // Thresholds are the canonical tier-group ones (1536/2048/3072/4096
  // MiB) — the startup group's draft used 2252/2867/3789 MiB, so its
  // triple test was NOT ported (it contradicts the canonical table).
  group('startup budgets (L-8 / L-14 / L-15 / L-61)', () {
    test('watchdog budget per tier (L-8): thresholds below the kill bands', () {
      final survival = DevicePerformance.watchdogBudgetFor(DeviceTier.survival);
      expect(survival.thresholdBytes, 260 << 20);
      expect(survival.pollInterval, const Duration(seconds: 5));

      final low = DevicePerformance.watchdogBudgetFor(DeviceTier.low);
      expect(low.thresholdBytes, 330 << 20);
      expect(low.pollInterval, const Duration(seconds: 5));

      final standard = DevicePerformance.watchdogBudgetFor(DeviceTier.standard);
      expect(standard.thresholdBytes, 450 << 20);
      expect(standard.pollInterval, const Duration(seconds: 10));

      final mid = DevicePerformance.watchdogBudgetFor(DeviceTier.mid);
      expect(mid.thresholdBytes, 600 << 20);
      expect(mid.pollInterval, const Duration(seconds: 15));

      // T4 keeps today's 45%-of-RAM / 30 s (45% of 4 GiB clamps to 1536 MB).
      DevicePerformance.debugReset(totalMemBytes: 4096 << 20, isLowRam: false, is64Bit: true);
      final full = DevicePerformance.watchdogBudgetFor(DeviceTier.full);
      expect(full.thresholdBytes, 1536 << 20);
      expect(full.pollInterval, const Duration(seconds: 30));

      // The bind gate is half the watchdog (L-8).
      expect(DevicePerformance.bindWarmBudgetBytes, full.thresholdBytes ~/ 2);
    });

    test('splash bind cap per tier (L-15): T0 8 s, T1 10 s, T2+ 15 s', () {
      expect(DevicePerformance.splashBindCapFor(DeviceTier.survival), const Duration(seconds: 8));
      expect(DevicePerformance.splashBindCapFor(DeviceTier.low), const Duration(seconds: 10));
      expect(DevicePerformance.splashBindCapFor(DeviceTier.standard), const Duration(seconds: 15));
      expect(DevicePerformance.splashBindCapFor(DeviceTier.full), const Duration(seconds: 15));
    });

    test('background-sync cadence per tier (L-14): T0 none, T1 monthly, T2+ weekly', () {
      expect(DevicePerformance.backgroundSyncIntervalFor(DeviceTier.survival), isNull);
      expect(DevicePerformance.backgroundSyncIntervalFor(DeviceTier.low), const Duration(days: 30));
      expect(DevicePerformance.backgroundSyncIntervalFor(DeviceTier.standard), const Duration(days: 7));
      expect(DevicePerformance.backgroundSyncIntervalFor(DeviceTier.full), const Duration(days: 7));
    });

    test('startup deferral + background shed apply to T0–T2 only (L-14/L-15)', () {
      DevicePerformance.debugReset(totalMemBytes: 1024 << 20, isLowRam: true, is64Bit: false);
      expect(DevicePerformance.deferStartupWorkPastFirstFrame, isTrue);
      expect(DevicePerformance.shedCachesOnBackground, isTrue);
      expect(DevicePerformance.isSurvivalMode, isTrue);

      DevicePerformance.debugReset(totalMemBytes: 2458 << 20, isLowRam: false, is64Bit: false);
      expect(DevicePerformance.deferStartupWorkPastFirstFrame, isFalse);
      expect(DevicePerformance.shedCachesOnBackground, isTrue);
      expect(DevicePerformance.isSurvivalMode, isFalse);

      // 3584 MiB is genuinely mid (T3) under the canonical table.
      DevicePerformance.debugReset(totalMemBytes: 3584 << 20, isLowRam: false, is64Bit: true);
      expect(DevicePerformance.deferStartupWorkPastFirstFrame, isFalse);
      expect(DevicePerformance.shedCachesOnBackground, isFalse);
    });

    test('survival startup jobs are live TV + search + favourites + playback only (L-61)', () {
      expect(
        DevicePerformance.startupJobsFor(DeviceTier.survival),
        const {StartupJob.liveTv, StartupJob.search, StartupJob.favourites, StartupJob.playback},
        reason: 'no feed, no hubs, no sync, no Discover, no VOD/series browse, no updater at T0 startup',
      );
      for (final tier in [DeviceTier.low, DeviceTier.standard, DeviceTier.mid, DeviceTier.full]) {
        expect(
          DevicePerformance.startupJobsFor(tier),
          containsAll(StartupJob.values),
          reason: '$tier runs the full startup list',
        );
      }
    });
  });
}
