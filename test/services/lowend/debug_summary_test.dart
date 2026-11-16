// L-50 — tier fingerprint in the debug dump Summary (T4-1).
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/debug_log_export_service.dart';
import 'package:plezy/services/device_performance.dart';

void main() {
  group('Tier fingerprint (L-50)', () {
    setUp(DevicePerformance.debugReset);
    tearDown(DevicePerformance.debugReset);

    test('debugSummary carries all ten spec keys', () {
      DevicePerformance.debugReset(
        totalMemBytes: 1400 << 20,
        is64Bit: false,
        isLowRam: true,
        heapClassMb: 256,
        sdkInt: 31,
        freeStorageBytes: 800 << 20,
      );
      final summary = DevicePerformance.debugSummary;
      for (final key in ['tier', 'totalMemMb', 'isLowRamDevice', 'is64Bit', 'heapClassMb', 'sdkInt', 'displayWidth', 'displayHeight', 'dpr', 'freeStorageMb']) {
        expect(summary, containsPair(key, isNotNull), reason: 'missing key $key');
      }
      expect(summary['tier'], 'survival');
      expect(summary['totalMemMb'], 1400);
      expect(summary['isLowRamDevice'], isTrue);
      expect(summary['is64Bit'], isFalse);
      expect(summary['heapClassMb'], 256);
      expect(summary['sdkInt'], 31);
      expect(summary['freeStorageMb'], 800);
    });

    test('tier derivation follows the round-3 §1 table (interim, until the enum lands)', () {
      // 1.5 GB 32-bit Hisense-class: low (1.5–2 GB band).
      DevicePerformance.debugReset(totalMemBytes: 1900 << 20, is64Bit: false, isLowRam: true);
      expect(DevicePerformance.debugSummary['tier'], 'low');
      // 2 GB 64-bit, lowRam false: standard.
      DevicePerformance.debugReset(totalMemBytes: 2048 << 20, is64Bit: true, isLowRam: false);
      expect(DevicePerformance.debugSummary['tier'], 'standard');
      // 4 GB Streamer-class: full.
      DevicePerformance.debugReset(totalMemBytes: 4096 << 20, is64Bit: true, isLowRam: false);
      expect(DevicePerformance.debugSummary['tier'], 'full');
      // isLowRamDevice caps at low even with 3 GB total.
      DevicePerformance.debugReset(totalMemBytes: 3072 << 20, is64Bit: true, isLowRam: true);
      expect(DevicePerformance.debugSummary['tier'], 'low');
      // Under 1.5 GB: survival.
      DevicePerformance.debugReset(totalMemBytes: 1024 << 20, is64Bit: false, isLowRam: true);
      expect(DevicePerformance.debugSummary['tier'], 'survival');
    });

    test('largeMemoryClass wins over memoryClass for heapClassMb', () {
      DevicePerformance.debugReset(totalMemBytes: 4096 << 20, heapClassMb: 256, largeHeapClassMb: 512);
      expect(DevicePerformance.debugSummary['heapClassMb'], 512);
      // debugReset keeps unspecified fields, so a full reset is needed
      // before asserting the memoryClass-only value.
      DevicePerformance.debugReset();
      DevicePerformance.debugReset(totalMemBytes: 4096 << 20, heapClassMb: 256);
      expect(DevicePerformance.debugSummary['heapClassMb'], 256);
    });

    test('buildTierLine names the tier + signals', () {
      DevicePerformance.debugReset(
        totalMemBytes: 1900 << 20,
        is64Bit: false,
        isLowRam: true,
        heapClassMb: 256,
        sdkInt: 31,
        freeStorageBytes: 800 << 20,
      );
      final line = DebugLogExportService.buildTierLine();
      expect(line, contains('Tier: low'));
      expect(line, contains('total RAM 1900 MB'));
      expect(line, contains('lowRam true'));
      expect(line, contains('32-bit'));
      expect(line, contains('heap class 256 MB'));
      expect(line, contains('API 31'));
      expect(line, contains('free storage 800 MB'));
    });

    test('buildTierLine reports unknown, never throws, before detection', () {
      final line = DebugLogExportService.buildTierLine();
      expect(line, contains('Tier: standard'));
      expect(line, contains('unknown'));
    });

    test('buildSummarySection contains the tier line', () async {
      DevicePerformance.debugReset(totalMemBytes: 1900 << 20, is64Bit: false, isLowRam: true);
      final summary = await DebugLogExportService.buildSummarySection(
        baseLogsText: 'nothing here',
        dumpReason: 'test',
        failedStarts: 0,
      );
      expect(summary, contains('Tier: low'));
      expect(summary, contains('Relief valve: none recorded'));
      expect(summary, contains('Slow ops: none recorded'));
    });

    test('buildSummarySection parses RELIEF + SLOW lines from the log text', () async {
      const logs = '''
RELIEF rss-high rssMb=745 rssMbAfter=700 dropped=iptv-catalogs+epg src=watchdog freedMb=45
SLOW op=feed-parse ms=24800 rssBeforeMb=500 rssAfterMb=561 maxRssMb=580 tier=low
''';
      final summary = await DebugLogExportService.buildSummarySection(
        baseLogsText: logs,
        dumpReason: 'test',
        failedStarts: 0,
      );
      expect(summary, contains('Relief valve: 1 trips, freed 45 MB (worst trip 45 MB)'));
      expect(summary, contains('Slow ops: 1 over threshold — feed-parse: 1× worst 24800ms'));
    });

    test('buildMemorySection carries the tier line + PSS/VmHWM/swap lines', () {
      final section = DebugLogExportService.buildMemorySection();
      expect(section, contains('Tier:'));
      expect(section, contains('PSS:'));
      expect(section, contains('VmHWM:'));
      expect(section, contains('VmSwap:'));
    });
  });
}
