// Failing-first tests for 1.4.3 A1 (mpv user-agent) + 1.6.12 R4 (read-back).
//
// mpv never sent the configured Xtream User-Agent: `user-agent` is a
// property of its own, not one of the http-header-fields, so an IPTV
// stream opened here carried mpv's default UA even though
// media.headers carries the configured one. A1 sets the property
// from the headers on open — and resets it (`del`, mpv's default)
// when the headers carry no UA, because the property is global and
// a stale IPTV UA would otherwise leak into a later header-less
// open (a Plex file, whose headers carry no User-Agent).
//
// 1.6.12 R4: a refused write used to fail silently (the 1.6.10 phone log
// showed the `del` failing with error -12), after which mpv sent its
// default `libmpv` UA. The open now reads the property back and logs
// whether the write landed. The mock core tracks the property value
// like mpv would, so the read-back can be asserted by call order.
//
// The mock core records every channel call; no real mpv runs. The R4
// tests reference the new behaviour, so they fail on the base
// (1.6.11: no read-back at all) and pass on the fix.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/services/settings_service.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

class _MpvCoreMock {
  final calls = <MethodCall>[];
  bool failUserAgentWrite = false;

  /// When set, `getProperty('user-agent')` returns this instead of the
  /// stored value — a read-back mismatch, like a write mpv refused
  /// without throwing.
  String? spoofReadBack;

  /// The `user-agent` property value as mpv would hold it: the last set
  /// value, mpv's default after a `del`, null when never set.
  String? _uaValue;

  static Map<Object?, Object?> _args(MethodCall call) =>
      Map<Object?, Object?>.from(call.arguments as Map);

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'initialize':
        return true;
      case 'setProperty':
        if (failUserAgentWrite && _args(call)['name'] == 'user-agent') {
          throw PlatformException(code: 'SET_PROPERTY_FAILED', message: 'refused');
        }
        if (_args(call)['name'] == 'user-agent') _uaValue = _args(call)['value'] as String?;
        return null;
      case 'getProperty':
        if (_args(call)['name'] == 'playlist-pos') return '0';
        if (_args(call)['name'] == 'user-agent') return spoofReadBack ?? _uaValue;
        return null;
      case 'command':
        final args = (_args(call)['args'] as List).cast<Object?>();
        if (args.length == 2 && args.first == 'del' && args[1] == 'user-agent') _uaValue = 'libmpv';
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

  bool hasCommand(List<Object?> args) => calls.any(
    (c) =>
        c.method == 'command' &&
        (_args(c)['args'] as List).cast<Object?>().toList().toString() == args.toString(),
  );

  int indexOfSetProperty(String name) => calls.indexWhere(
    (c) => c.method == 'setProperty' && _args(c)['name'] == name,
  );

  int indexOfGetProperty(String name) => calls.indexWhere(
    (c) => c.method == 'getProperty' && _args(c)['name'] == name,
  );

  int indexOfLoadfile() => calls.indexWhere(
    (c) =>
        c.method == 'command' &&
        (_args(c)['args'] as List).cast<Object?>().isNotEmpty &&
        (_args(c)['args'] as List).cast<Object?>().first == 'loadfile',
  );
}

Future<void> _run(
  _MpvCoreMock core,
  Future<void> Function(PlayerNative player) body,
) {
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
  });

  tearDown(() => PlayerNative.debugUseAppleAudioOutput = null);

  test('open with a User-Agent header writes it to mpv before loadfile', () async {
    final core = _MpvCoreMock();
    await _run(core, (player) async {
      final entryId = await player.open(
        Media(
          'https://example.test/live.m3u8',
          headers: const {'Accept-Language': 'en', 'User-Agent': 'VLC'},
        ),
        isLive: true,
      );

      expect(entryId, 1);
      expect(core.setPropertyValue('user-agent'), 'VLC');
      expect(core.indexOfSetProperty('user-agent'), greaterThanOrEqualTo(0));
      expect(
        core.indexOfSetProperty('user-agent'),
        lessThan(core.indexOfLoadfile()),
        reason: 'the UA is set before the file loads',
      );
      expect(core.hasCommand(['del', 'user-agent']), isFalse);
    });
  });

  test('open without a User-Agent header resets mpv to its default', () async {
    final core = _MpvCoreMock();
    await _run(core, (player) async {
      await player.open(
        Media('https://example.test/next.mkv', headers: const {'Accept-Language': 'en'}),
      );

      expect(core.setPropertyValue('user-agent'), isNull);
      expect(core.hasCommand(['del', 'user-agent']), isTrue);
      expect(
        core.calls.indexWhere(
          (c) =>
              c.method == 'command' &&
              (_MpvCoreMock._args(c)['args'] as List).cast<Object?>().toString() ==
                  ['del', 'user-agent'].toString(),
        ),
        lessThan(core.indexOfLoadfile()),
        reason: 'the reset happens before the file loads',
      );
    });
  });

  test('open with no headers at all resets mpv to its default', () async {
    final core = _MpvCoreMock();
    await _run(core, (player) async {
      await player.open(Media('https://example.test/next.mkv'));

      expect(core.setPropertyValue('user-agent'), isNull);
      expect(core.hasCommand(['del', 'user-agent']), isTrue);
    });
  });

  test('a lowercase user-agent header key is honoured', () async {
    final core = _MpvCoreMock();
    await _run(core, (player) async {
      await player.open(
        Media(
          'https://example.test/live.m3u8',
          headers: const {'user-agent': 'VLC'},
        ),
        isLive: true,
      );

      expect(core.setPropertyValue('user-agent'), 'VLC');
    });
  });

  test('a refused user-agent write still opens the file', () async {
    final core = _MpvCoreMock()..failUserAgentWrite = true;
    await _run(core, (player) async {
      final entryId = await player.open(
        Media(
          'https://example.test/live.m3u8',
          headers: const {'User-Agent': 'VLC'},
        ),
        isLive: true,
      );

      expect(entryId, 1, reason: 'the loadfile still runs when the UA write is refused');
      expect(core.indexOfLoadfile(), greaterThanOrEqualTo(0));
    });
  });

  test('1.6.12 R4: a set user-agent is read back before loadfile', () async {
    final core = _MpvCoreMock();
    await _run(core, (player) async {
      await player.open(
        Media(
          'https://example.test/live.m3u8',
          headers: const {'User-Agent': 'VLC'},
        ),
        isLive: true,
      );

      expect(core.indexOfGetProperty('user-agent'), greaterThanOrEqualTo(0));
      expect(
        core.indexOfGetProperty('user-agent'),
        greaterThan(core.indexOfSetProperty('user-agent')),
        reason: 'the read-back follows the write',
      );
      expect(
        core.indexOfGetProperty('user-agent'),
        lessThan(core.indexOfLoadfile()),
        reason: 'the read-back happens before the file loads',
      );
    });
  });

  test('1.6.12 R4: a read-back mismatch still opens the file', () async {
    // mpv refused the write without throwing (the 1.6.10 phone log's
    // error -12 shape): the open must degrade to a warning, never abort.
    final core = _MpvCoreMock()..spoofReadBack = 'libmpv';
    await _run(core, (player) async {
      final entryId = await player.open(
        Media(
          'https://example.test/live.m3u8',
          headers: const {'User-Agent': 'VLC'},
        ),
        isLive: true,
      );

      expect(entryId, 1, reason: 'a mismatched read-back never aborts the open');
      expect(core.indexOfGetProperty('user-agent'), greaterThanOrEqualTo(0));
      expect(core.indexOfLoadfile(), greaterThanOrEqualTo(0));
    });
  });

  test('1.6.12 R4: the reset is read back before loadfile', () async {
    final core = _MpvCoreMock();
    await _run(core, (player) async {
      await player.open(
        Media('https://example.test/next.mkv', headers: const {'Accept-Language': 'en'}),
      );

      expect(core.hasCommand(['del', 'user-agent']), isTrue);
      expect(core.indexOfGetProperty('user-agent'), greaterThanOrEqualTo(0));
      expect(
        core.indexOfGetProperty('user-agent'),
        greaterThan(
          core.calls.indexWhere(
            (c) =>
                c.method == 'command' &&
                (_MpvCoreMock._args(c)['args'] as List).cast<Object?>().toString() ==
                    ['del', 'user-agent'].toString(),
          ),
        ),
        reason: 'the read-back follows the reset',
      );
      expect(
        core.indexOfGetProperty('user-agent'),
        lessThan(core.indexOfLoadfile()),
        reason: 'the read-back happens before the file loads',
      );
    });
  });
}
