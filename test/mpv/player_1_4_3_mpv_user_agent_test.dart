// Failing-first tests for 1.4.3 A1 (mpv user-agent).
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
// The mock core records every channel call; no real mpv runs. These
// tests reference the new behaviour, so they fail on the base
// (1.4.2: no user-agent write at all) and pass on the fix.
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
        return null;
      case 'getProperty':
        if (_args(call)['name'] == 'playlist-pos') return '0';
        return null;
      case 'command':
        final args = (_args(call)['args'] as List).cast<Object?>();
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
}
