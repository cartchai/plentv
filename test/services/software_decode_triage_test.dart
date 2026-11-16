import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/software_decode_triage.dart';

/// 1.2.19 L-11: the zap-time triage decision — codec × hardware probe ×
/// measured frame drops → warn or not. Pure function, no player needed.
/// Device proof (zap AV1/HEVC on the Hisense, `hwdec-current` + frame-drop
/// count + fps) is UNPROVEN — it needs the TV, not this harness.
void main() {
  group('shouldWarn', () {
    test('HEVC with no hardware decoder and decoder drops warns', () {
      expect(
        SoftwareDecodeTriage.shouldWarn(
          codec: 'hevc',
          hardwareHevc: false,
          hardwareAv1: false,
          decoderDrops: 5,
          frameDrops: 0,
        ),
        isTrue,
      );
    });

    test('AV1 with no hardware decoder and output drops warns', () {
      expect(
        SoftwareDecodeTriage.shouldWarn(
          codec: 'av1',
          hardwareHevc: false,
          hardwareAv1: false,
          decoderDrops: 0,
          frameDrops: 15,
        ),
        isTrue,
      );
    });

    test('no drops means no warning even with no hardware decoder (a box that software-decodes fine is no false alarm)', () {
      expect(
        SoftwareDecodeTriage.shouldWarn(
          codec: 'hevc',
          hardwareHevc: false,
          hardwareAv1: false,
          decoderDrops: 0,
          frameDrops: 0,
        ),
        isFalse,
      );
    });

    test('a few open-time drops below the threshold do not warn', () {
      expect(
        SoftwareDecodeTriage.shouldWarn(
          codec: 'av1',
          hardwareHevc: false,
          hardwareAv1: false,
          decoderDrops: 4,
          frameDrops: 14,
        ),
        isFalse,
      );
    });

    test('a hardware decoder means no warning however many frames drop (a bad stream is not a decode problem)', () {
      expect(
        SoftwareDecodeTriage.shouldWarn(
          codec: 'hevc',
          hardwareHevc: true,
          hardwareAv1: false,
          decoderDrops: 500,
          frameDrops: 500,
        ),
        isFalse,
      );
      expect(
        SoftwareDecodeTriage.shouldWarn(
          codec: 'av1',
          hardwareHevc: false,
          hardwareAv1: true,
          decoderDrops: 500,
          frameDrops: 500,
        ),
        isFalse,
      );
    });

    test('an unprobed device never warns (never narrow on missing data)', () {
      expect(
        SoftwareDecodeTriage.shouldWarn(
          codec: 'av1',
          hardwareHevc: null,
          hardwareAv1: null,
          decoderDrops: 500,
          frameDrops: 500,
        ),
        isFalse,
      );
    });

    test('H.264 never warns — software H.264 is ~1 core and plays fine', () {
      expect(
        SoftwareDecodeTriage.shouldWarn(
          codec: 'h264',
          hardwareHevc: false,
          hardwareAv1: false,
          decoderDrops: 500,
          frameDrops: 500,
        ),
        isFalse,
      );
    });

    test('an unknown codec never warns (no probe to gate on)', () {
      expect(
        SoftwareDecodeTriage.shouldWarn(
          codec: 'vp9',
          hardwareHevc: false,
          hardwareAv1: false,
          decoderDrops: 500,
          frameDrops: 500,
        ),
        isFalse,
      );
      expect(
        SoftwareDecodeTriage.shouldWarn(
          codec: null,
          hardwareHevc: false,
          hardwareAv1: false,
          decoderDrops: 500,
          frameDrops: 500,
        ),
        isFalse,
      );
    });

    test('codec aliases map the same way as the transcode targets', () {
      expect(
        SoftwareDecodeTriage.shouldWarn(
          codec: 'h265',
          hardwareHevc: false,
          hardwareAv1: true,
          decoderDrops: 5,
          frameDrops: 0,
        ),
        isTrue,
      );
      expect(
        SoftwareDecodeTriage.shouldWarn(
          codec: 'avc1',
          hardwareHevc: false,
          hardwareAv1: false,
          decoderDrops: 500,
          frameDrops: 500,
        ),
        isFalse,
      );
    });

    test('the HEVC probe gates HEVC and the AV1 probe gates AV1, not each other', () {
      expect(
        SoftwareDecodeTriage.shouldWarn(
          codec: 'hevc',
          hardwareHevc: true,
          hardwareAv1: false,
          decoderDrops: 500,
          frameDrops: 500,
        ),
        isFalse,
      );
      expect(
        SoftwareDecodeTriage.shouldWarn(
          codec: 'av1',
          hardwareHevc: true,
          hardwareAv1: false,
          decoderDrops: 5,
          frameDrops: 0,
        ),
        isTrue,
      );
    });
  });

  group('warningFor', () {
    test('names the codec so one channel warning and another not makes sense', () {
      expect(SoftwareDecodeTriage.warningFor('av1'), contains('AV1'));
      expect(SoftwareDecodeTriage.warningFor('hevc'), contains('HEVC'));
      expect(SoftwareDecodeTriage.warningFor('h265'), contains('HEVC'));
      expect(SoftwareDecodeTriage.warningFor(null), contains('software decoding'));
    });
  });
}
