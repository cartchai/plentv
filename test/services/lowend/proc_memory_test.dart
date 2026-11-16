// L-54 — PSS + VmHWM + swap in the dump (T4-5).
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/lowend/proc_memory.dart';

void main() {
  group('ProcMemorySnapshot (L-54)', () {
    test('parses /proc/self/status keys', () {
      const status = '''
Name:\tplezy
VmPeak:\t  1234567 kB
VmSize:\t  1234567 kB
VmHWM:\t   845000 kB
VmRSS:\t   581000 kB
RssAnon:\t   420000 kB
RssFile:\t   161000 kB
VmSwap:\t    12000 kB
''';
      final snap = ProcMemorySnapshot.parseStatus(status);
      expect(snap.vmHwmKb, 845000);
      expect(snap.vmRssKb, 581000);
      expect(snap.rssAnonKb, 420000);
      expect(snap.rssFileKb, 161000);
      expect(snap.vmSwapKb, 12000);
    });

    test('missing keys parse as null, never throw', () {
      final snap = ProcMemorySnapshot.parseStatus('Name:\tplezy\n');
      expect(snap.vmHwmKb, isNull);
      expect(snap.isEmpty, isTrue);
    });

    test('parses Pss from smaps_rollup', () {
      const rollup = '''
00100000-00200000 ---p 00000000 00:00 0                              [rollup]
Rss:             581000 kB
Pss:             402000 kB
Pss_Dirty:       380000 kB
''';
      expect(ProcMemorySnapshot.parseSmapsRollupPssKb(rollup), 402000);
      expect(ProcMemorySnapshot.parseSmapsRollupPssKb('no pss here'), isNull);
    });

    test('renderLines shows PSS + VmHWM + swap alongside RSS', () {
      const snap = ProcMemorySnapshot(
        pssKb: 402000,
        vmHwmKb: 845000,
        vmRssKb: 581000,
        rssAnonKb: 420000,
        rssFileKb: 161000,
        vmSwapKb: 12000,
      );
      final lines = snap.renderLines();
      expect(lines, contains('PSS: 392.6 MB'));
      expect(lines, contains('VmHWM: 825.2 MB'));
      expect(lines, contains('VmSwap: 11.7 MB'));
      expect(lines, contains('RssAnon: 410.2 MB'));
      expect(lines, contains('RssFile: 157.2 MB'));
    });

    test('empty snapshot renders an unavailable line, not a crash', () {
      const snap = ProcMemorySnapshot();
      expect(snap.renderLines(), contains('unavailable'));
    });

    test('toJson carries all six fields', () {
      const snap = ProcMemorySnapshot(pssKb: 1, vmHwmKb: 2, vmRssKb: 3, rssAnonKb: 4, rssFileKb: 5, vmSwapKb: 6);
      final json = snap.toJson();
      expect(json['pssKb'], 1);
      expect(json['vmHwmKb'], 2);
      expect(json['vmSwapKb'], 6);
    });
  });
}
