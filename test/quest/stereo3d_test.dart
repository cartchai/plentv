import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/quest/stereo3d.dart';

void main() {
  group('detectStereo3dFromFilename', () {
    test('HSBS tag is half SBS', () {
      final d = detectStereo3dFromFilename('Avatar.2009.3D.HSBS.mkv');
      expect(d.layout, Stereo3dLayout.sbs);
      expect(d.packing, Stereo3dPacking.half);
      expect(d.source, Stereo3dSource.filename);
      expect(d.is3d, isTrue);
    });

    test('Full-SBS tag is full SBS', () {
      final d = detectStereo3dFromFilename('Movie.2020.Full-SBS.mkv');
      expect(d.layout, Stereo3dLayout.sbs);
      expect(d.packing, Stereo3dPacking.full);
    });

    test('FSBS tag is full SBS', () {
      final d = detectStereo3dFromFilename('Movie.2020.FSBS.mkv');
      expect(d.layout, Stereo3dLayout.sbs);
      expect(d.packing, Stereo3dPacking.full);
    });

    test('bare SBS tag defaults to half SBS', () {
      final d = detectStereo3dFromFilename('Movie.2020.3D.SBS.mkv');
      expect(d.layout, Stereo3dLayout.sbs);
      expect(d.packing, Stereo3dPacking.half);
    });

    test('H-SBS and Half-SBS are half SBS', () {
      expect(detectStereo3dFromFilename('A.H-SBS.mkv').packing, Stereo3dPacking.half);
      expect(detectStereo3dFromFilename('A.Half-SBS.mkv').packing, Stereo3dPacking.half);
      expect(detectStereo3dFromFilename('A.Half-SBS.mkv').layout, Stereo3dLayout.sbs);
    });

    test('OU tag is half over-under', () {
      final d = detectStereo3dFromFilename('Film.3D.OU.mkv');
      expect(d.layout, Stereo3dLayout.ou);
      expect(d.packing, Stereo3dPacking.half);
    });

    test('HOU and HTAB are half over-under', () {
      expect(detectStereo3dFromFilename('A.3D.HOU.mkv').layout, Stereo3dLayout.ou);
      expect(detectStereo3dFromFilename('A.3D.HTAB.mkv').layout, Stereo3dLayout.ou);
      expect(detectStereo3dFromFilename('A.3D.HOU.mkv').packing, Stereo3dPacking.half);
    });

    test('FTAB is full over-under', () {
      final d = detectStereo3dFromFilename('A.FTAB.mkv');
      expect(d.layout, Stereo3dLayout.ou);
      expect(d.packing, Stereo3dPacking.full);
    });

    test('TB token is over-under', () {
      expect(detectStereo3dFromFilename('A.3D.TB.mkv').layout, Stereo3dLayout.ou);
    });

    test('LR token is SBS', () {
      expect(detectStereo3dFromFilename('A._LR.mkv').layout, Stereo3dLayout.sbs);
    });

    test('_LRF_Full_SBS is full SBS', () {
      final d = detectStereo3dFromFilename('A_LRF_Full_SBS.mkv');
      expect(d.layout, Stereo3dLayout.sbs);
      expect(d.packing, Stereo3dPacking.full);
    });

    test('no tag is 2D', () {
      final d = detectStereo3dFromFilename('Avatar.2009.mkv');
      expect(d.layout, Stereo3dLayout.twoD);
      expect(d.is3d, isFalse);
    });

    test('null and empty file is 2D', () {
      expect(detectStereo3dFromFilename(null).layout, Stereo3dLayout.twoD);
      expect(detectStereo3dFromFilename('').layout, Stereo3dLayout.twoD);
    });

    test('a 1920x1080 file with no tag is 2D (never declare on size alone)', () {
      expect(detectStereo3dFromFilename('Movie.2020.1080p.mkv').layout, Stereo3dLayout.twoD);
    });

    test('detection is case-insensitive', () {
      expect(detectStereo3dFromFilename('A.3d.hsbs.mkv').layout, Stereo3dLayout.sbs);
      expect(detectStereo3dFromFilename('A.3D.Ou.MKV').layout, Stereo3dLayout.ou);
    });

    test('VR180 tag is vr180 layout', () {
      final d = detectStereo3dFromFilename('Clip_180_sbs.mp4');
      expect(d.layout, Stereo3dLayout.vr180);
      expect(d.is3d, isTrue);
    });

    test('VR360 tag is vr360 layout', () {
      final d = detectStereo3dFromFilename('Clip_360.mp4');
      expect(d.layout, Stereo3dLayout.vr360);
      expect(d.is3d, isTrue);
    });
  });

  group('detectStereo3dFromResolution', () {
    test('3840x1080 is full SBS', () {
      final d = detectStereo3dFromResolution(3840, 1080);
      expect(d.layout, Stereo3dLayout.sbs);
      expect(d.packing, Stereo3dPacking.full);
      expect(d.source, Stereo3dSource.resolution);
    });

    test('1920x2160 is full over-under', () {
      final d = detectStereo3dFromResolution(1920, 2160);
      expect(d.layout, Stereo3dLayout.ou);
      expect(d.packing, Stereo3dPacking.full);
    });

    test('1920x1080 is never 3D on size alone', () {
      expect(detectStereo3dFromResolution(1920, 1080).layout, Stereo3dLayout.twoD);
    });

    test('1280x720 is 2D', () {
      expect(detectStereo3dFromResolution(1280, 720).layout, Stereo3dLayout.twoD);
    });
  });

  group('detectStereo3dFromMpvStereoMode', () {
    test('left_right is SBS', () {
      expect(detectStereo3dFromMpvStereoMode('left_right').layout, Stereo3dLayout.sbs);
    });

    test('top_bottom is over-under', () {
      expect(detectStereo3dFromMpvStereoMode('top_bottom').layout, Stereo3dLayout.ou);
    });

    test('mono is 2D', () {
      expect(detectStereo3dFromMpvStereoMode('mono').layout, Stereo3dLayout.twoD);
    });

    test('null and unknown are 2D', () {
      expect(detectStereo3dFromMpvStereoMode(null).layout, Stereo3dLayout.twoD);
      expect(detectStereo3dFromMpvStereoMode('something-else').layout, Stereo3dLayout.twoD);
    });
  });

  group('resolveStereo3d precedence', () {
    test('manual beats filename', () {
      final d = resolveStereo3d(
        manual: const Stereo3dDetection(layout: Stereo3dLayout.twoD, packing: Stereo3dPacking.half, source: Stereo3dSource.manual),
        filename: 'A.3D.HSBS.mkv',
      );
      expect(d.layout, Stereo3dLayout.twoD);
      expect(d.source, Stereo3dSource.manual);
    });

    test('filename beats container', () {
      final d = resolveStereo3d(
        filename: 'A.3D.OU.mkv',
        container: detectStereo3dFromMpvStereoMode('left_right'),
      );
      expect(d.layout, Stereo3dLayout.ou);
      expect(d.source, Stereo3dSource.filename);
    });

    test('container beats resolution', () {
      final d = resolveStereo3d(
        container: detectStereo3dFromMpvStereoMode('top_bottom'),
        width: 3840,
        height: 1080,
      );
      expect(d.layout, Stereo3dLayout.ou);
      expect(d.source, Stereo3dSource.container);
    });

    test('resolution beats the 2D default', () {
      final d = resolveStereo3d(width: 3840, height: 1080);
      expect(d.layout, Stereo3dLayout.sbs);
      expect(d.source, Stereo3dSource.resolution);
    });

    test('no signal is 2D', () {
      final d = resolveStereo3d(filename: 'A.mkv');
      expect(d.layout, Stereo3dLayout.twoD);
      expect(d.is3d, isFalse);
    });
  });

  group('flatPlaybackStereo3dFilter (FLAT decision, §1.9)', () {
    test('a detected 3D title plays flat with no stereo3d filter', () {
      final d = detectStereo3dFromFilename('A.3D.HSBS.mkv');
      expect(d.is3d, isTrue);
      // Both eyes stay visible on phone/TV — the diagnostic that it is
      // a 3D file and that it is loading correctly.
      expect(flatPlaybackStereo3dFilter(d), isNull);
    });

    test('a 2D title also gets no filter', () {
      expect(flatPlaybackStereo3dFilter(const Stereo3dDetection.twoD()), isNull);
    });
  });

  group('Stereo3dTitleRecord', () {
    test('round-trips through JSON', () {
      const record = Stereo3dTitleRecord(
        layout: Stereo3dLayout.sbs,
        packing: Stereo3dPacking.full,
        swapEyes: true,
        screenPreset: 'cinema',
        subtitleDepth: 'below',
      );
      final decoded = Stereo3dTitleRecord.fromJson(record.toJson());
      expect(decoded.layout, Stereo3dLayout.sbs);
      expect(decoded.packing, Stereo3dPacking.full);
      expect(decoded.swapEyes, isTrue);
      expect(decoded.screenPreset, 'cinema');
      expect(decoded.subtitleDepth, 'below');
    });

    test('defaults are auto layout, half packing, no swap', () {
      const record = Stereo3dTitleRecord();
      expect(record.layout, Stereo3dLayout.auto);
      expect(record.packing, Stereo3dPacking.half);
      expect(record.swapEyes, isFalse);
    });

    test('toDetection reports the manual source', () {
      const record = Stereo3dTitleRecord(layout: Stereo3dLayout.ou, packing: Stereo3dPacking.half);
      final d = record.toDetection();
      expect(d.source, Stereo3dSource.manual);
      expect(d.layout, Stereo3dLayout.ou);
    });
  });

  group('Stereo3dTitleStore', () {
    test('a manual choice sticks and is read back by key', () {
      final backend = _MemoryTitleBackend();
      final store = Stereo3dTitleStore(backend);
      const record = Stereo3dTitleRecord(layout: Stereo3dLayout.sbs, packing: Stereo3dPacking.half);
      store.save('rating-1', 'part-1', record);
      expect(store.load('rating-1', 'part-1')?.layout, Stereo3dLayout.sbs);
      expect(store.load('rating-1', 'part-2'), isNull);
      expect(store.load('rating-2', 'part-1'), isNull);
    });

    test('clearing a title forgets it', () {
      final backend = _MemoryTitleBackend();
      final store = Stereo3dTitleStore(backend);
      store.save('r', 'p', const Stereo3dTitleRecord(layout: Stereo3dLayout.ou));
      store.clear('r', 'p');
      expect(store.load('r', 'p'), isNull);
    });
  });

  group('shouldShowStereo3dButton', () {
    const detected = Stereo3dDetection(
      layout: Stereo3dLayout.sbs,
      packing: Stereo3dPacking.half,
      source: Stereo3dSource.filename,
    );
    const flat = Stereo3dDetection.twoD();

    test('shows on Quest when a 3D file was detected', () {
      expect(
        shouldShowStereo3dButton(
            isQuest: true, debugToggle: false, detection: detected),
        true,
      );
    });

    test('hides on Quest when nothing 3D was detected', () {
      expect(
        shouldShowStereo3dButton(
            isQuest: true, debugToggle: false, detection: flat),
        false,
      );
    });

    test('hides on phone/TV even when a 3D file was detected', () {
      expect(
        shouldShowStereo3dButton(
            isQuest: false, debugToggle: false, detection: detected),
        false,
      );
    });

    test('debug toggle forces the button on any device, even flat', () {
      expect(
        shouldShowStereo3dButton(
            isQuest: false, debugToggle: true, detection: flat),
        true,
      );
      expect(
        shouldShowStereo3dButton(
            isQuest: true, debugToggle: true, detection: flat),
        true,
      );
    });
  });
}

class _MemoryTitleBackend implements Stereo3dTitleStoreBackend {
  String? _stored;
  @override
  String? read() => _stored;
  @override
  void write(String value) => _stored = value;
}
