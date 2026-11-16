import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/last_decode_stats.dart';

void main() {
  setUp(LastDecodeStats.debugReset);

  test('summary says nothing recorded before any playback (1.2.18 C-7a)', () {
    expect(
      LastDecodeStats.summaryLine(),
      'Playback decode: no playback decode recorded yet',
    );
  });

  test('software fallback is named, with drop counts (1.2.18 C-7a)', () {
    LastDecodeStats.recordHwdec('no');
    LastDecodeStats.recordDrops(frame: 12, decoder: 3);
    expect(
      LastDecodeStats.summaryLine(),
      'Playback decode: software decode — frame drops 12 (decoder 3)',
    );
  });

  test('hardware decode names the backend, drops optional (1.2.18 C-7a)', () {
    LastDecodeStats.recordHwdec('mediacodec');
    expect(
      LastDecodeStats.summaryLine(),
      'Playback decode: hardware decode (mediacodec) — frame drops not recorded',
    );
  });

  test('recordHwdec reports change only on a flip (1.2.18 C-7a)', () {
    expect(LastDecodeStats.recordHwdec('mediacodec'), isTrue);
    expect(LastDecodeStats.recordHwdec('mediacodec'), isFalse);
    expect(LastDecodeStats.recordHwdec('no'), isTrue);
  });

  test('null drop values leave the last known counts alone (1.2.18 C-7a)', () {
    LastDecodeStats.recordDrops(frame: 5, decoder: 1);
    LastDecodeStats.recordDrops();
    expect(LastDecodeStats.frameDropCount, 5);
    expect(LastDecodeStats.decoderFrameDropCount, 1);
  });
}
