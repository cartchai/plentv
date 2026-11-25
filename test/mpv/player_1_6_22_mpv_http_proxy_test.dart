// Failing-first tests for 1.6.22 (player through the tunnel proxy).
//
// 1.6.21 phone log: a series episode 403'd direct while the tunnel beside
// it carried the API calls — the default MPV path has no proxy wiring at
// all. This build sets mpv's `http-proxy` property before the `loadfile`
// for IPTV opens while the tunnel is on, and explicitly resets it (`del`)
// on every other open, mirroring the 1.4.3 A1 user-agent block in the same
// function (set + read-back + reset, a refused write degrades to a warning
// and never aborts the open).
//
// The mock core records every channel call; no real mpv runs. The tests
// reference the new behaviour (`isIptv` on `open`, the tunnel test hook),
// so they fail on the 1.6.21 base and pass on the fix.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/services/iptv/warp_tunnel_service.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

class _MpvCoreMock {
  final calls = <MethodCall>[];
  bool failHttpProxyWrite = false;

  /// When set, `getProperty('http-proxy')` returns this instead of the
  /// stored value — a read-back mismatch, like a write mpv refused
  /// without throwing.
  String? spoofProxyReadBack;

  /// The `http-proxy` property value as mpv would hold it: the last set
  /// value, null after a `del` (mpv's default is unset), null when never set.
  String? _proxyValue;

  static Map<Object?, Object?> _args(MethodCall call) => Map<Object?, Object?>.from(call.arguments as Map);

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'initialize':
        return true;
      case 'setProperty':
        if (failHttpProxyWrite && _args(call)['name'] == 'http-proxy') {
          throw PlatformException(code: 'SET_PROPERTY_FAILED', message: 'refused');
        }
        if (_args(call)['name'] == 'http-proxy') _proxyValue = _args(call)['value'] as String?;
        return null;
      case 'getProperty':
        if (_args(call)['name'] == 'playlist-pos') return '0';
        if (_args(call)['name'] == 'http-proxy') return spoofProxyReadBack ?? _proxyValue;
        return null;
      case 'command':
        final args = (_args(call)['args'] as List).cast<Object?>();
        if (args.length == 2 && args.first == 'del' && args[1] == 'http-proxy') _proxyValue = null;
        if (args.isNotEmpty && args.first == 'loadfile') {
          return {'playlistEntryId': 1};
        }
        return null;
      default:
        return null;
    }
  }

  /// The value of the first `setProperty` write for [name], or null.
  String? setPropertyValue(String name) {
    for (final call in calls) {
      if (call.method != 'setProperty') continue;
      final args = _args(call);
      if (args['name'] == name) return args['value'] as String?;
    }
    return null;
  }

  /// All `setProperty` writes for [name], in call order.
  List<String?> setPropertyValues(String name) {
    final values = <String?>[];
    for (final call in calls) {
      if (call.method != 'setProperty') continue;
      final args = _args(call);
      if (args['name'] == name) values.add(args['value'] as String?);
    }
    return values;
  }

  bool hasCommand(List<Object?> args) => calls.any(
    (c) => c.method == 'command' && (_args(c)['args'] as List).cast<Object?>().toList().toString() == args.toString(),
  );

  int indexOfSetProperty(String name) => calls.indexWhere((c) => c.method == 'setProperty' && _args(c)['name'] == name);

  int indexOfGetProperty(String name) => calls.indexWhere((c) => c.method == 'getProperty' && _args(c)['name'] == name);

  int indexOfCommand(List<Object?> args) => calls.indexWhere(
    (c) => c.method == 'command' && (_args(c)['args'] as List).cast<Object?>().toList().toString() == args.toString(),
  );

  int indexOfLoadfile() => calls.indexWhere(
    (c) =>
        c.method == 'command' &&
        (_args(c)['args'] as List).cast<Object?>().isNotEmpty &&
        (_args(c)['args'] as List).cast<Object?>().first == 'loadfile',
  );

  /// Indices of every `loadfile` command, in call order.
  List<int> loadfileIndices() {
    final indices = <int>[];
    for (var i = 0; i < calls.length; i++) {
      final c = calls[i];
      if (c.method != 'command') continue;
      final args = (_args(c)['args'] as List).cast<Object?>();
      if (args.isNotEmpty && args.first == 'loadfile') indices.add(i);
    }
    return indices;
  }

  /// The http-proxy decisions in call order: `set:<value>` or `del`.
  List<String> httpProxyEvents() {
    final events = <String>[];
    for (final call in calls) {
      if (call.method == 'setProperty' && _args(call)['name'] == 'http-proxy') {
        events.add('set:${_args(call)['value']}');
      }
      if (call.method == 'command') {
        final args = (_args(call)['args'] as List).cast<Object?>();
        if (args.length == 2 && args.first == 'del' && args[1] == 'http-proxy') {
          events.add('del');
        }
      }
    }
    return events;
  }
}

Future<void> _run(_MpvCoreMock core, Future<void> Function(PlayerNative player) body) {
  return withMockPlayerChannels(
    methodChannelName: 'com.plezy/mpv_player',
    eventChannelName: 'com.plezy/mpv_player/events',
    methodHandler: core.handle,
    testBody: () async {
      final player = PlayerNative();
      try {
        await body(player);
      } finally {
        await player.dispose();
      }
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    PlayerNative.debugUseAppleAudioOutput = false;
    WarpTunnelService.instance.debugSetTunnelForTest(on: false);
  });

  tearDown(() {
    PlayerNative.debugUseAppleAudioOutput = null;
    WarpTunnelService.instance.debugSetTunnelForTest(on: false);
  });

  test('tunnel on + IPTV open applies the proxy before loadfile', () async {
    final core = _MpvCoreMock();
    WarpTunnelService.instance.debugSetTunnelForTest(on: true, proxyPort: 18081);
    await _run(core, (player) async {
      final entryId = await player.open(
        Media('https://example.test/live.m3u8', headers: const {'Accept-Language': 'en', 'User-Agent': 'VLC'}),
        isLive: true,
        isIptv: true,
      );

      expect(entryId, 1);
      expect(core.setPropertyValue('http-proxy'), 'http://127.0.0.1:18081');
      expect(
        core.indexOfSetProperty('http-proxy'),
        lessThan(core.indexOfLoadfile()),
        reason: 'the proxy is set before the file loads',
      );
      expect(core.indexOfGetProperty('http-proxy'), greaterThan(core.indexOfSetProperty('http-proxy')));
      expect(
        core.indexOfGetProperty('http-proxy'),
        lessThan(core.indexOfLoadfile()),
        reason: 'the read-back happens before the file loads',
      );
      expect(player.lastOpenUsedProxy, isTrue);
    });
  });

  test('tunnel on + non-IPTV open resets the proxy', () async {
    final core = _MpvCoreMock();
    WarpTunnelService.instance.debugSetTunnelForTest(on: true, proxyPort: 18081);
    await _run(core, (player) async {
      await player.open(Media('https://example.test/next.mkv', headers: const {'Accept-Language': 'en'}));

      expect(core.setPropertyValue('http-proxy'), isNull);
      expect(core.hasCommand(['del', 'http-proxy']), isTrue);
      expect(
        core.indexOfCommand(['del', 'http-proxy']),
        lessThan(core.indexOfLoadfile()),
        reason: 'the reset happens before the file loads',
      );
      expect(player.lastOpenUsedProxy, isFalse);
    });
  });

  test('tunnel off + IPTV open goes direct', () async {
    final core = _MpvCoreMock();
    await _run(core, (player) async {
      await player.open(
        Media('https://example.test/live.m3u8', headers: const {'Accept-Language': 'en'}),
        isLive: true,
        isIptv: true,
      );

      expect(core.setPropertyValue('http-proxy'), isNull);
      expect(core.hasCommand(['del', 'http-proxy']), isTrue);
      expect(player.lastOpenUsedProxy, isFalse);
    });
  });

  test('tunnel on but no proxy port goes direct', () async {
    final core = _MpvCoreMock();
    WarpTunnelService.instance.debugSetTunnelForTest(on: true);
    await _run(core, (player) async {
      await player.open(
        Media('https://example.test/live.m3u8', headers: const {'Accept-Language': 'en'}),
        isLive: true,
        isIptv: true,
      );

      expect(core.setPropertyValue('http-proxy'), isNull);
      expect(core.hasCommand(['del', 'http-proxy']), isTrue);
      expect(player.lastOpenUsedProxy, isFalse);
    });
  });

  test('no leak: IPTV open then Plex open on the same player resets the proxy', () async {
    final core = _MpvCoreMock();
    WarpTunnelService.instance.debugSetTunnelForTest(on: true, proxyPort: 18081);
    await _run(core, (player) async {
      await player.open(
        Media('https://example.test/live.m3u8', headers: const {'Accept-Language': 'en'}),
        isLive: true,
        isIptv: true,
      );
      expect(player.lastOpenUsedProxy, isTrue);

      await player.open(Media('https://example.test/next.mkv', headers: const {'Accept-Language': 'en'}));

      final loads = core.loadfileIndices();
      expect(loads, hasLength(2));
      final delIndex = core.indexOfCommand(['del', 'http-proxy']);
      expect(delIndex, greaterThan(loads[0]), reason: 'the reset comes after the IPTV load');
      expect(delIndex, lessThan(loads[1]), reason: 'the reset comes before the Plex load');
      expect(player.lastOpenUsedProxy, isFalse);
    });
  });

  test('two instances: a mini-player open does not affect the fullscreen instance', () async {
    // The native core is single-owner: a second PlayerNative cannot
    // initialize while the first still owns it (its invoke waits on the
    // ownership gate), so the instances are handed off in sequence —
    // exactly how production does it, where the mini-player's player is
    // disposed when fullscreen takes over. Each open still decides its
    // own proxy state: set, del, set — never a leak from one instance
    // into the next.
    final core = _MpvCoreMock();
    WarpTunnelService.instance.debugSetTunnelForTest(on: true, proxyPort: 18081);
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: core.handle,
      testBody: () async {
        final fullscreen = PlayerNative();
        await fullscreen.open(
          Media('https://example.test/live.m3u8', headers: const {'Accept-Language': 'en'}),
          isLive: true,
          isIptv: true,
        );
        final fullscreenUsedProxy = fullscreen.lastOpenUsedProxy;
        await fullscreen.dispose();

        final miniPlayer = PlayerNative();
        await miniPlayer.open(Media('https://example.test/next.mkv'));
        final miniPlayerUsedProxy = miniPlayer.lastOpenUsedProxy;
        await miniPlayer.dispose();

        final fullscreenAgain = PlayerNative();
        await fullscreenAgain.open(
          Media('https://example.test/live2.m3u8', headers: const {'Accept-Language': 'en'}),
          isLive: true,
          isIptv: true,
        );
        final fullscreenAgainUsedProxy = fullscreenAgain.lastOpenUsedProxy;
        await fullscreenAgain.dispose();

        expect(core.httpProxyEvents(), ['set:http://127.0.0.1:18081', 'del', 'set:http://127.0.0.1:18081']);
        expect(fullscreenUsedProxy, isTrue);
        expect(miniPlayerUsedProxy, isFalse);
        expect(fullscreenAgainUsedProxy, isTrue);
      },
    );
  });

  test('a refused http-proxy write still opens the file', () async {
    final core = _MpvCoreMock()..failHttpProxyWrite = true;
    WarpTunnelService.instance.debugSetTunnelForTest(on: true, proxyPort: 18081);
    await _run(core, (player) async {
      final entryId = await player.open(
        Media('https://example.test/live.m3u8', headers: const {'Accept-Language': 'en'}),
        isLive: true,
        isIptv: true,
      );

      expect(entryId, 1, reason: 'the loadfile still runs when the proxy write is refused');
      expect(core.indexOfLoadfile(), greaterThanOrEqualTo(0));
      // The write never landed, so the failure view must not name the tunnel.
      expect(player.lastOpenUsedProxy, isFalse);
    });
  });

  test('a read-back mismatch still opens the file', () async {
    // mpv refused the write without throwing: the open must degrade to a
    // warning, never abort — and the latch stays false, since the proxy
    // is not actually in effect for this open.
    final core = _MpvCoreMock()..spoofProxyReadBack = 'http://127.0.0.1:18082';
    WarpTunnelService.instance.debugSetTunnelForTest(on: true, proxyPort: 18081);
    await _run(core, (player) async {
      final entryId = await player.open(
        Media('https://example.test/live.m3u8', headers: const {'Accept-Language': 'en'}),
        isLive: true,
        isIptv: true,
      );

      expect(entryId, 1, reason: 'a mismatched read-back never aborts the open');
      expect(core.indexOfGetProperty('http-proxy'), greaterThanOrEqualTo(0));
      expect(core.indexOfLoadfile(), greaterThanOrEqualTo(0));
      expect(player.lastOpenUsedProxy, isFalse);
    });
  });

  test('the proxy is set before the playlist loads and no reset intervenes', () async {
    // HLS playlist and segments share one mpv demux session, so the
    // proxy set before loadfile covers the segments too — but only if
    // nothing resets it between the set and the load.
    final core = _MpvCoreMock();
    WarpTunnelService.instance.debugSetTunnelForTest(on: true, proxyPort: 18081);
    await _run(core, (player) async {
      await player.open(
        Media('https://example.test/live.m3u8', headers: const {'Accept-Language': 'en'}),
        isLive: true,
        isIptv: true,
      );

      final setIndex = core.indexOfSetProperty('http-proxy');
      final loadIndex = core.indexOfLoadfile();
      expect(setIndex, greaterThanOrEqualTo(0));
      expect(setIndex, lessThan(loadIndex));
      expect(core.indexOfCommand(['del', 'http-proxy']), -1, reason: 'no reset between the proxy set and the load');
    });
  });

  test('the reset is read back before loadfile', () async {
    final core = _MpvCoreMock();
    WarpTunnelService.instance.debugSetTunnelForTest(on: true, proxyPort: 18081);
    await _run(core, (player) async {
      await player.open(Media('https://example.test/next.mkv'));

      expect(core.hasCommand(['del', 'http-proxy']), isTrue);
      expect(core.indexOfGetProperty('http-proxy'), greaterThanOrEqualTo(0));
      expect(
        core.indexOfGetProperty('http-proxy'),
        greaterThan(core.indexOfCommand(['del', 'http-proxy'])),
        reason: 'the read-back follows the reset',
      );
      expect(
        core.indexOfGetProperty('http-proxy'),
        lessThan(core.indexOfLoadfile()),
        reason: 'the read-back happens before the file loads',
      );
    });
  });
}
