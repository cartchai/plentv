import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/iptv_artwork_stages.dart';

/// 1.2.19 L-30: the progressive-artwork stage order — pure decision, no
/// widget needed. The widget test proves the stages actually render in
/// that order; this test pins the order itself.
void main() {
  group('IptvArtworkStages.resolve', () {
    test('non-IPTV artwork is one full stage, unchanged', () {
      final stages = IptvArtworkStages.resolve(
        isIptv: false,
        thumbnailOnly: false,
        fullMemWidth: 400,
        fullMemHeight: 600,
      );
      expect(stages, hasLength(1));
      expect(stages.single.memWidth, 400);
      expect(stages.single.memHeight, 600);
    });

    test('IPTV on the full tier is thumbnail first, full after', () {
      final stages = IptvArtworkStages.resolve(
        isIptv: true,
        thumbnailOnly: false,
        fullMemWidth: 400,
        fullMemHeight: 600,
      );
      expect(stages, hasLength(2));
      expect(stages.first.memWidth, IptvArtworkStages.thumbnailWidth);
      expect(stages.first.memWidth, 160);
      expect(stages.last.memWidth, 400);
      expect(stages.last.memHeight, 600);
    });

    test('IPTV capped (reduced tier or metered) is thumbnail only', () {
      final stages = IptvArtworkStages.resolve(
        isIptv: true,
        thumbnailOnly: true,
        fullMemWidth: 400,
        fullMemHeight: 600,
      );
      expect(stages, hasLength(1));
      expect(stages.single.memWidth, IptvArtworkStages.thumbnailWidth);
    });

    test('the cap never applies to non-IPTV artwork', () {
      final stages = IptvArtworkStages.resolve(
        isIptv: false,
        thumbnailOnly: true,
        fullMemWidth: 400,
        fullMemHeight: 600,
      );
      expect(stages, hasLength(1));
      expect(stages.single.memWidth, 400);
    });
  });
}
