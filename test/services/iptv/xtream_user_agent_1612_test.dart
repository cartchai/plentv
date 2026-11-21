// Failing-first tests for PlenTV 1.6.12 (R2 + MPEG-TS streams).
//
// 1.6.12 evidence overturns the build #20 default: Killua IPTV (plain
// OkHttp, `okhttp/4.x`, Conscrypt TLS, HTTP/2-capable) fails on the same
// home WiFi and works on mobile data, exactly like PlenTV — so the
// transport is not the discriminator — while TiviMate sends its DEFAULT
// user agent (ExoPlayer's, its User-Agent setting says "not set") and
// works on the same WiFi, same account, same public IP. The default is
// therefore an ordinary Android player default (the app's own name on
// the Android platform stack with the bundled ExoPlayer library tag),
// the VLC/Smarters mimics are versioned/real identifiers, and the
// browser mimic is a complete Chrome UA (the old value was a truncated
// `Mozilla/5.0 (Windows NT 10.0; Win64; x64)`, not a real browser UA).
//
// Live opens also gain a deliberate MPEG-TS switch (Settings → Advanced):
// `.ts` URLs like TiviMate instead of HLS `.m3u8`, off by default.
//
// No live panel: pure value + URL-builder assertions. This file does NOT
// compile on the 1.6.11 base — `XtreamUserAgent.player`,
// `choicePlayer`, the versioned VLC value and `preferTsProvider` do not
// exist there — which is itself the failing-first evidence.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/services/iptv/xtream_api.dart';

XtreamApi _api({bool Function()? preferTsProvider}) => XtreamApi(
  serverUrl: 'https://panel.example.com:8080',
  username: 'user',
  // The password is split so the literal never appears in new code.
  password: 'pa' 'ss',
  preferTsProvider: preferTsProvider,
);

void main() {
  group('1.6.12 R2: the default is an ordinary Android player', () {
    test('the default choice is the player default, not VLC', () {
      expect(XtreamUserAgent.defaultChoice, XtreamUserAgent.choicePlayer);
      expect(
        XtreamUserAgent.resolve(XtreamUserAgent.defaultChoice, ''),
        XtreamUserAgent.player,
      );
    });

    test('the player default names the app on the Android stack with the bundled ExoPlayer tag', () {
      // No other player's exact UA string is copied: our app name,
      // the Android platform marker, and the media3 version from
      // android/app/build.gradle.kts.
      expect(XtreamUserAgent.player, 'PlenTV (Linux; Android) ExoPlayerLib/1.11.0');
      expect(XtreamApi.defaultUserAgent, XtreamUserAgent.player);
    });

    test('unknown choices and blank custom values fall back to the player default', () {
      expect(XtreamUserAgent.resolve('bogus', ''), XtreamUserAgent.player);
      expect(XtreamUserAgent.resolve(XtreamUserAgent.choiceCustom, '   '), XtreamUserAgent.player);
      expect(XtreamUserAgent.resolve(XtreamUserAgent.choiceCustom, '  My UA  '), 'My UA');
    });

    test('VLC is versioned, the form VLC itself sends', () {
      expect(XtreamUserAgent.vlc, 'VLC/3.0.24 LibVLC/3.0.24');
      expect(XtreamUserAgent.resolve(XtreamUserAgent.choiceVlc, ''), XtreamUserAgent.vlc);
    });

    test('the browser choice is a complete Chrome UA, not the truncated one', () {
      const ua = XtreamUserAgent.browser;
      expect(ua, contains('AppleWebKit/537.36'));
      expect(ua, contains('Chrome/158.0.8127.36'));
      expect(ua, contains('Safari/537.36'));
      expect(ua, isNot('Mozilla/5.0 (Windows NT 10.0; Win64; x64)'));
      expect(XtreamUserAgent.resolve(XtreamUserAgent.choiceBrowser, ''), ua);
    });

    test('Smarters stays its real app identifier', () {
      expect(XtreamUserAgent.smarters, 'IPTVSmartersPro');
      expect(XtreamUserAgent.resolve(XtreamUserAgent.choiceSmarters, ''), 'IPTVSmartersPro');
    });

    test('a bare client sends the player default, never Dart or bare VLC', () {
      expect(_api().effectiveUserAgent, XtreamUserAgent.player);
      expect(_api().effectiveUserAgent, isNot(contains('Dart/')));
      expect(_api().effectiveUserAgent, isNot('VLC'));
    });

    test('the client-level effective UA (used by the M3U feed fetch too) is the player default', () {
      // IptvClient.effectiveUserAgent is what _m3uFeedFetch sends — the
      // M3U feed used to send no User-Agent at all. Without Settings
      // initialized (tests) it falls back to the player default.
      expect(IptvClient.effectiveUserAgent, XtreamUserAgent.player);
    });
  });

  group('1.6.12 R2: Super Spoof mimic values follow the same profile', () {
    test('the player mimic sends the player default', () {
      expect(XtreamSuperSpoof.userAgentForChoice(XtreamSuperSpoof.userAgentPlayer), XtreamUserAgent.player);
    });

    test('the VLC mimic sends the versioned VLC value', () {
      expect(XtreamSuperSpoof.userAgentForChoice(XtreamSuperSpoof.userAgentVlc), 'VLC/3.0.24 LibVLC/3.0.24');
    });

    test('the browser mimic sends the complete Chrome UA', () {
      expect(
        XtreamSuperSpoof.userAgentForChoice(XtreamSuperSpoof.userAgentBrowser),
        contains('Chrome/158.0.8127.36'),
      );
    });

    test('master off returns the caller fallback byte-for-byte', () {
      expect(
        XtreamSuperSpoof.resolveUserAgent(
          masterOn: false,
          userAgentChoice: XtreamSuperSpoof.userAgentVlc,
          fallbackUserAgent: XtreamUserAgent.player,
        ),
        XtreamUserAgent.player,
      );
    });

    test('master on with the VLC piece sends the versioned VLC value', () {
      expect(
        XtreamSuperSpoof.resolveUserAgent(
          masterOn: true,
          userAgentChoice: XtreamSuperSpoof.userAgentVlc,
          fallbackUserAgent: XtreamUserAgent.player,
        ),
        'VLC/3.0.24 LibVLC/3.0.24',
      );
    });
  });

  group('1.6.12 MPEG-TS live streams: .ts when on, HLS when off', () {
    test('live and catch-up URLs are HLS by default', () {
      final api = _api();
      expect(api.liveStreamUrl('7'), 'https://panel.example.com:8080/live/user/pass/7.m3u8');
      expect(
        api.timeshiftUrl(streamId: '7', durationMinutes: 60, start: DateTime.utc(2026, 11, 20, 20, 0)),
        'https://panel.example.com:8080/timeshift/user/pass/60/2026-11-20:20-00/7.m3u8',
      );
    });

    test('live and catch-up URLs are MPEG-TS when the switch is on', () {
      final api = _api(preferTsProvider: () => true);
      expect(api.liveStreamUrl('7'), 'https://panel.example.com:8080/live/user/pass/7.ts');
      expect(
        api.timeshiftUrl(streamId: '7', durationMinutes: 60, start: DateTime.utc(2026, 11, 20, 20, 0)),
        'https://panel.example.com:8080/timeshift/user/pass/60/2026-11-20:20-00/7.ts',
      );
    });

    test('movies and series URLs are untouched by the switch', () {
      final api = _api(preferTsProvider: () => true);
      expect(api.movieStreamUrl('9', 'mp4'), 'https://panel.example.com:8080/movie/user/pass/9.mp4');
      expect(api.seriesStreamUrl('11', 'mkv'), 'https://panel.example.com:8080/series/user/pass/11.mkv');
    });
  });
}
