// PlenTV 1.6 (D4) — scheme dual-accept.
//
// Failing-first: on the 1.5.3 base every `plentv://` parse returns null
// and generated links use `plezy://`. After the fix: `plentv://` parses,
// `plezy://` still parses, and everything generated uses `plentv://` —
// including shelf content IDs, which accept both prefixes.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player/live_tv_session_args.dart';
import 'package:plezy/services/deep_links/deep_link.dart';
import 'package:plezy/services/system_shelf_service.dart';

void main() {
  group('1.6 scheme dual-accept', () {
    test('plentv://open parses', () {
      expect(DeepLink.tryParse('plentv://open'), isA<OpenLink>());
    });

    test('plezy://open still parses (legacy)', () {
      expect(DeepLink.tryParse('plezy://open'), isA<OpenLink>());
    });

    test('plentv://play parses with server + id', () {
      final link = DeepLink.tryParse('plentv://play?server=abc123&id=42&mode=shuffle') as PlayLink;
      expect((link.target as ItemPlayTarget).serverId, 'abc123');
      expect((link.target as ItemPlayTarget).itemId, '42');
      expect(link.mode, PlayMode.shuffle);
    });

    test('plezy://play still parses (legacy)', () {
      final link = DeepLink.tryParse('plezy://play?server=abc123&id=42') as PlayLink;
      expect((link.target as ItemPlayTarget).itemId, '42');
    });

    test('plentv://live parses', () {
      final link = DeepLink.tryParse('plentv://live?channel=4.1&start=live') as LiveLink;
      expect(link.channel, '4.1');
      expect(link.startPosition, LiveTvStartPosition.live);
    });

    test('generated links use plentv://', () {
      expect(const OpenLink().toUri().toString(), 'plentv://open');
      final play = DeepLink.tryParse('plezy://play?server=abc123&id=42') as PlayLink;
      expect(play.toUri().toString(), contains('plentv://play'));
      expect(play.toUri().toString(), isNot(contains('plezy://')));
    });

    test('an unknown scheme still parses to null', () {
      expect(DeepLink.tryParse('https://example.com/open'), isNull);
      expect(DeepLink.tryParse('plez://open'), isNull);
    });
  });

  group('1.6 shelf content IDs', () {
    test('plentv_ prefix parses', () {
      final parsed = SystemShelfService.parseContentId('plentv_srv-1_42');
      expect(parsed, isNotNull);
      expect(parsed!.$1, 'srv-1');
      expect(parsed.$2, '42');
    });

    test('plezy_ prefix still parses (pre-1.6 shelf rows)', () {
      final parsed = SystemShelfService.parseContentId('plezy_srv-1_42');
      expect(parsed, isNotNull);
      expect(parsed!.$1, 'srv-1');
      expect(parsed.$2, '42');
    });

    test('a rating key containing underscores survives both prefixes', () {
      for (final prefix in ['plentv_', 'plezy_']) {
        final parsed = SystemShelfService.parseContentId('${prefix}srv-1_a_b_c');
        expect(parsed!.$2, 'a_b_c');
      }
    });

    test('anything else parses to null', () {
      expect(SystemShelfService.parseContentId('other_srv-1_42'), isNull);
      expect(SystemShelfService.parseContentId('plentv_42'), isNull);
    });

    test('a content_id in a plentv:// link resolves through the legacy prefix too', () {
      final link = DeepLink.tryParse('plentv://play?content_id=plezy_abc123_42') as PlayLink;
      expect((link.target as ItemPlayTarget).itemId, '42');
      final fresh = DeepLink.tryParse('plentv://play?content_id=plentv_abc123_42') as PlayLink;
      expect((fresh.target as ItemPlayTarget).itemId, '42');
    });
  });
}
