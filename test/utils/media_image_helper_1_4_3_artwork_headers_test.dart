// Lock-in tests for the 1.4.3 A4 audit ('PlenTV' fallback UA).
//
// The audit traced every `serverArtworkProvider` call site (6 total)
// and every `artworkHeadersFor` call: a provider image only ever
// fetches with the configured Xtream UA when its client is the
// IptvClient, and no site passes null for a provider image in any
// reachable flow — the precache guards null, the program sheet only
// resolves a poster when its client is non-null, the detail poster
// and backdrops pair a null client with no network fetch when
// offline, and the guide channel logos only render when the client
// is non-null. The one residual is a server unregistered
// mid-session, where no client exists to pass. These tests pin the
// helper's contract so a future change to the fallback is
// deliberate, not silent.
//
// No production code changed in A4 (the audit found nothing to
// fix), so these pass on the base too — they are regression guards
// for the audited behaviour, not failing-first proofs.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/xtream_api.dart';
import 'package:plezy/utils/media_image_helper.dart';

import '../test_helpers/prefs.dart';

IptvClient _trexClient() => IptvClient.xtream(
  xtreamConnection: XtreamConnection(
    id: 'trex',
    name: 'Trex',
    serverUrl: 'https://panel.example.com:8080',
    username: 'user',
    password: 'pa' 'ss',
    createdAt: DateTime.utc(2026, 11, 6),
  ),
);

void main() {
  setUp(() => resetSharedPreferencesForTest());

  test('an IPTV client gets the configured Xtream UA, never the fallback', () {
    final headers = MediaImageHelper.artworkHeadersFor(_trexClient());
    expect(headers['User-Agent'], XtreamUserAgent.vlc);
    expect(headers['User-Agent'], isNot('PlezTV'));
  });

  test('a null client gets the PlezTV fallback', () {
    expect(
      MediaImageHelper.artworkHeadersFor(null),
      const {'User-Agent': 'PlenTV'},
    );
  });

  test('a relative thumb path with no client resolves to nothing (no fetch)', () {
    expect(
      MediaImageHelper.getOptimizedImageUrl(
        client: null,
        thumbPath: '/live/123/logo.png',
        maxWidth: 100,
        maxHeight: 100,
        pixelRatio: 1,
      ),
      isEmpty,
    );
  });

  test('an absolute URL with no client passes through unchanged', () {
    // Pinned contract (the audit's residual edge): absolute URLs are
    // returned as-is when there is no client to proxy through. No
    // call site reaches this with a panel URL in a reachable flow —
    // every site passes its client through — so the fallback UA on
    // such a fetch can only happen when the server was unregistered
    // mid-session, where no client exists to pass.
    const url = 'https://panel.example.com:8080/images/poster.jpg';
    expect(
      MediaImageHelper.getOptimizedImageUrl(
        client: null,
        thumbPath: url,
        maxWidth: 100,
        maxHeight: 100,
        pixelRatio: 1,
      ),
      url,
    );
  });
}
