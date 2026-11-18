// 1.3.30 — bug 3 unit tests for `xmltvPrefixLooksValid` (the shape
// check that replaced the strict DOM parse of the truncated
// validation prefix). This file references new API, so it must not
// compile on the 1.3.29 base — that is its failing-first proof (the
// same pattern as the 1.3.28 preset test).
//
// The phone's case: the validator's 256 KB cut lands mid-`<desc>`
// in the public US2 guide, and the old strict parse threw
// `XmlTagException: Missing closing tag </desc>`. The shape check
// accepts any prefix that already shows a `<tv>` root and a first
// `<channel>` — both sit in the first kilobytes of any real guide —
// whatever the cut lands on.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/iptv_live_tv.dart';

/// A valid XMLTV doc cut at [cut] bytes — the exact truncation the
/// validator sees (the first 256 KB of a bigger file).
List<int> _cutDoc(String doc, int cut) => utf8.encode(doc.substring(0, cut));

void main() {
  const head =
      '<?xml version="1.0" encoding="UTF-8"?><tv>'
      '<channel id="cnn.us"><display-name>CNN</display-name></channel>';
  const programmeHead =
      '<programme start="20261117000000 +0000" stop="20261117020000 +0000" channel="cnn.us">'
      '<title>News</title><desc>';

  group('xmltvPrefixLooksValid (1.3.30 bug 3)', () {
    test('a prefix cut mid-<desc> is valid', () {
      final doc = '$head$programmeHead${'x' * 5000}</desc></programme></tv>';
      // Cut 2000 bytes into the desc text — the prefix ends mid-element.
      final cut = utf8.encode(head + programmeHead).length + 2000;
      expect(IptvLiveTvSupport.xmltvPrefixLooksValid(_cutDoc(doc, cut)), isTrue);
    });

    test('a prefix cut mid-tag-name is valid', () {
      // The other truncation shape the research found: the cut lands
      // inside a tag name, which a strict parse rejects with
      // `">" expected`.
      final prefix = '$head<prog';
      expect(IptvLiveTvSupport.xmltvPrefixLooksValid(utf8.encode(prefix)), isTrue);
    });

    test('a complete small file is valid', () {
      const doc =
          '<?xml version="1.0" encoding="UTF-8"?><tv>'
          '<channel id="cnn.us"><display-name>CNN</display-name></channel>'
          '<programme start="20261117000000 +0000" stop="20261117010000 +0000" channel="cnn.us">'
          '<title>News</title></programme></tv>';
      expect(IptvLiveTvSupport.xmltvPrefixLooksValid(utf8.encode(doc)), isTrue);
    });

    test('a gzipped prefix cut mid-<desc> is valid', () {
      // The phone's actual case: a .xml.gz whose 256 KB of compressed
      // bytes decompress to a prefix cut mid-<desc>. The desc text is
      // varied (counter-based) so the gzip output is genuinely larger
      // than the 256 KB cap — a repeating 'x' would compress to almost
      // nothing and never be truncated.
      final varied = StringBuffer();
      for (var i = 0; i < 60000; i++) {
        varied.write('Programme $i description with varied words ${(i * 2654435761) % 100000}. ');
      }
      final doc = '$head$programmeHead$varied</desc></programme></tv>';
      final gzipped = GZipCodec().encode(utf8.encode(doc));
      expect(gzipped.length, greaterThan(262144), reason: 'the fixture must actually exceed the 256 KB cap');
      final prefix = gzipped.sublist(0, 262144);
      expect(IptvLiveTvSupport.xmltvPrefixLooksValid(prefix), isTrue);
    });

    test('a non-XMLTV payload is invalid', () {
      expect(IptvLiveTvSupport.xmltvPrefixLooksValid(utf8.encode('this is not xml at all')), isFalse);
    });

    test('a <tv> root with no <channel> is invalid', () {
      const doc = '<?xml version="1.0" encoding="UTF-8"?><tv></tv>';
      expect(IptvLiveTvSupport.xmltvPrefixLooksValid(utf8.encode(doc)), isFalse);
    });
  });
}
