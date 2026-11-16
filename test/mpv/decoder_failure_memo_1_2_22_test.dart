// 1.2.22 §63.3 — the MPV hardware-decode path.
//
// 3a: the decoder-failure memo extends to VOD (keyed by content id —
// `vod:<serverId>:<itemId>`, same 2-rejection / 7-day rules as live),
// and the rejection event attributes to the VOD key when the screen
// set it at open.
// 3b: a file whose format was rejected and still shows no frame 3 s
// later carries the plain-words note in PlayerState (and emits it).
// A slow start with no rejection never gets the note.
// 3c: the note clears when a frame renders or a new file begins.
// 3d: `frame_rate` still rides along on `vd-lavc-o` — it IS a real
// AVOption in the bundled ffmpeg (patch 0111 registers it and feeds
// MediaFormat "frame-rate"). The dump's rejection fired on the native
// h264 decoder, where the key does not exist — that explains the dump,
// not the option. (1.2.22 §63.3 fix round: the prune was wrong and was
// reverted.)
//
// Device-only: the decoder failure itself cannot be reproduced in the
// VM (no mediacodec) — these tests target event handling only, driving
// the same `handlePlayerEvent` / `handlePropertyChange` seams the
// native bridge feeds. No decoder is faked.
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/player/player_base.dart';
import 'package:plezy/mpv/player/player_native.dart';
import 'package:plezy/services/decoder_failure_memo.dart';

import '../test_helpers/mock_player_channels.dart';
import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    DecoderFailureMemo.debugResetForTesting();
    await DecoderFailureMemo.getInstance();
  });

  tearDown(() {
    DecoderFailureMemo.debugResetForTesting();
  });

  Future<void> withPlayer(Future<void> Function(PlayerNative player) body) {
    return withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      methodHandler: (_) => Future.value(null),
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

  group('3a VOD memo (1.2.22 §63.3)', () {
    test('a VOD key memos after two rejections, like a live channel', () async {
      final memo = await DecoderFailureMemo.getInstance();
      const key = 'vod:trex:movie-1';
      expect(memo.shouldStartOnGlVo(key), isFalse);
      await memo.recordRejection(key);
      expect(memo.shouldStartOnGlVo(key), isFalse);
      await memo.recordRejection(key);
      expect(memo.shouldStartOnGlVo(key), isTrue);
      // A different item never inherits it.
      expect(memo.shouldStartOnGlVo('vod:trex:movie-2'), isFalse);
    });

    test('the rejection event attributes to the VOD key the screen set', () async {
      await withPlayer((player) async {
        const key = 'vod:trex:movie-1';
        DecoderFailureMemo.currentChannelKey = key;
        final memo = await DecoderFailureMemo.getInstance();
        player.handlePlayerEvent('vo-format-rejected', {'sourceId': 1});
        expect(memo.shouldStartOnGlVo(key), isFalse, reason: 'one rejection does not memo');
        player.handlePlayerEvent('vo-format-rejected', {'sourceId': 1});
        expect(memo.shouldStartOnGlVo(key), isTrue, reason: 'two rejections memo the VOD item');
      });
    });

    test('a clean hardware decode clears the VOD key', () async {
      await withPlayer((player) async {
        const key = 'vod:trex:movie-1';
        final memo = await DecoderFailureMemo.getInstance();
        await memo.recordRejection(key);
        await memo.recordRejection(key);
        expect(memo.shouldStartOnGlVo(key), isTrue);
        DecoderFailureMemo.currentChannelKey = key;
        player.handlePropertyChange('hwdec-current', 'mediacodec');
        expect(memo.shouldStartOnGlVo(key), isFalse);
      });
    });

    test('a rejection with no key set records nothing and throws nothing', () async {
      await withPlayer((player) async {
        DecoderFailureMemo.currentChannelKey = null;
        player.handlePlayerEvent('vo-format-rejected', {'sourceId': 1});
        final memo = await DecoderFailureMemo.getInstance();
        expect(memo.shouldStartOnGlVo('vod:trex:movie-1'), isFalse);
      });
    });
  });

  group('3b black-frame note (1.2.22 §63.3)', () {
    test('a rejected file with no frame in 3 s carries the note', () async {
      await withPlayer((player) async {
        final notes = <String>[];
        player.streams.decoderFallbackNote.listen(notes.add);
        fakeAsync((async) {
          player.handlePlayerEvent('start-file', {'sourceId': 1});
          player.handlePlayerEvent('vo-format-rejected', {'sourceId': 1});
          expect(player.state.decoderFallbackNote, isNull);
          async.elapse(const Duration(seconds: 3));
          async.flushMicrotasks();
          expect(player.state.decoderFallbackNote, PlayerBase.decoderFallbackNoteText);
          expect(notes, [PlayerBase.decoderFallbackNoteText]);
        });
      });
    });

    test('a slow start with no rejection never gets the note', () async {
      await withPlayer((player) async {
        fakeAsync((async) {
          player.handlePlayerEvent('start-file', {'sourceId': 1});
          async.elapse(const Duration(seconds: 3));
          async.flushMicrotasks();
          expect(player.state.decoderFallbackNote, isNull, reason: 'buffering is not a decoder fallback');
        });
      });
    });
  });

  group('3c note clears (1.2.22 §63.3)', () {
    test('a frame rendering inside the window clears the note', () async {
      await withPlayer((player) async {
        fakeAsync((async) {
          player.handlePlayerEvent('start-file', {'sourceId': 1});
          player.handlePlayerEvent('vo-format-rejected', {'sourceId': 1});
          async.elapse(const Duration(seconds: 1));
          player.handlePlayerEvent('playback-restart', {'sourceId': 1, 'positionSeconds': 0.0});
          expect(player.state.hasRenderedFrame, isTrue);
          async.elapse(const Duration(seconds: 3));
          async.flushMicrotasks();
          expect(player.state.decoderFallbackNote, isNull);
        });
      });
    });

    test('a new file clears a set note at once', () async {
      await withPlayer((player) async {
        fakeAsync((async) {
          player.handlePlayerEvent('start-file', {'sourceId': 1});
          player.handlePlayerEvent('vo-format-rejected', {'sourceId': 1});
          async.elapse(const Duration(seconds: 3));
          expect(player.state.decoderFallbackNote, isNotNull);
          player.handlePlayerEvent('start-file', {'sourceId': 2});
          expect(player.state.decoderFallbackNote, isNull, reason: 'a new file starts with no note');
          expect(player.state.hasRenderedFrame, isFalse);
        });
      });
    });
  });

  test('3d frame_rate is still written into the native decoder options (1.2.22 §63.3 fix round)', () {
    // Source-level guard: the decoder itself cannot run in the VM, so
    // the write is pinned here — the production file must keep naming
    // the key. (The DecoderOptions composition tests still use the
    // key as an arbitrary helper key; this is about the native file.)
    final content = File(
      'android/app/src/main/kotlin/com/pleztv/app/mpv/MpvPlayerCore.kt',
    ).readAsStringSync();
    expect(
      content.contains('decoderOptions.put("frame_rate"'),
      isTrue,
      reason: 'frame_rate is a real AVOption in the bundled ffmpeg (patch 0111)',
    );
  });
}
