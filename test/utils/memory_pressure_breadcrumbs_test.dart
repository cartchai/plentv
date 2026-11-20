import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/services/playback_coordinator.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/memory_pressure_breadcrumbs.dart';

/// The production binding's memory-pressure hook over the standard test
/// binding, so a `memoryPressure` system message takes the engine's path.
class _MemoryPressureTestBinding extends AutomatedTestWidgetsFlutterBinding with MemoryPressureLog {
  /// The engine message runs in the zone that registered the channel handler,
  /// out of reach of `withClock`; timing cases enter the handler directly.
  void warnInCurrentZone() => handleMemoryPressure();
}

/// Evicts the way `_MainAppState.didHaveMemoryPressure` does, and records what
/// an observer gets to see of the cache.
class _EvictingObserver with WidgetsBindingObserver {
  int? keepAliveBytesSeen;

  @override
  void didHaveMemoryPressure() {
    final cache = PaintingBinding.instance.imageCache;
    keepAliveBytesSeen = cache.currentSizeBytes;
    cache
      ..clear()
      ..clearLiveImages();
  }
}

class _LoadedImageCompleter extends ImageStreamCompleter {
  _LoadedImageCompleter(ui.Image image) {
    setImage(ImageInfo(image: image));
  }
}

void main() {
  final binding = _MemoryPressureTestBinding();

  setUp(() {
    binding.debugResetMemoryPressureLog();
    MemoryLogOutput.clearLogs();
  });

  tearDown(() {
    binding.imageCache
      ..clear()
      ..clearLiveImages();
  });

  void registerVideoSession(PlayerState? Function() playerState) {
    Future<void> owner() async {}
    PlaybackCoordinator.instance.registerVideoSession(shutdown: owner, playerState: playerState);
    addTearDown(() => PlaybackCoordinator.instance.unregisterVideoSession(owner));
  }

  void warnAt(DateTime at) => withClock(Clock.fixed(at), binding.warnInCurrentZone);

  Object parsePressureValue(String s) {
    final asInt = int.tryParse(s);
    if (asInt != null) return asInt;
    if (s == 'true') return true;
    if (s == 'false') return false;
    return s;
  }

  /// The `Memory pressure: k=v ...` lines this test's warnings wrote, newest
  /// first. (1.6: the Sentry breadcrumb this used to capture is cut — the
  /// data lives only in the local log line now, so the test parses it back.)
  List<Map<String, Object>> pressureLines() {
    return MemoryLogOutput.getLogs()
        .map((e) => e.message)
        .where((m) => m.startsWith('Memory pressure: '))
        .map((m) {
          final data = <String, Object>{};
          for (final pair in m.substring('Memory pressure: '.length).split(' ')) {
            final eq = pair.indexOf('=');
            data[pair.substring(0, eq)] = parsePressureValue(pair.substring(eq + 1));
          }
          return data;
        })
        .toList();
  }

  test('records the image cache from before the framework cleared it and after the app evicted', () async {
    final cache = binding.imageCache;
    final keepAliveImage = await createTestImage(width: 1024, height: 1024); // 4 MB
    final shownImage = await createTestImage(width: 1024, height: 512); // 2 MB
    cache.putIfAbsent('keep-alive', () => _LoadedImageCompleter(keepAliveImage));
    final shownListener = ImageStreamListener((info, _) => info.dispose());
    final shown = cache.putIfAbsent('shown', () => _LoadedImageCompleter(shownImage)..addListener(shownListener))!;
    addTearDown(() => shown.removeListener(shownListener));
    expect((cache.currentSize, cache.liveImageCount), (2, 1));

    final observer = _EvictingObserver();
    binding.addObserver(observer);
    addTearDown(() => binding.removeObserver(observer));
    registerVideoSession(
      () => const PlayerState(playing: true, position: Duration(minutes: 1), buffer: Duration(seconds: 95)),
    );

    await binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.system.name,
      SystemChannels.system.codec.encodeMessage(<String, Object?>{'type': 'memoryPressure'}),
      (_) {},
    );

    expect(observer.keepAliveBytesSeen, 0, reason: 'the framework empties the cache before observers run');
    final data = pressureLines().single;
    final rssMb = data.remove('rssMb') as int;
    final maxRssMb = data.remove('maxRssMb') as int;
    final rssMbAfter = data.remove('rssMbAfter') as int;
    // currentRss and maxRss read separate OS counters, and the peak can trail
    // the current value: CI's Linux runner reported rssMb=386, maxRssMb=385.
    expect(rssMb, greaterThan(0));
    expect(maxRssMb, greaterThan(0));
    expect(rssMbAfter, greaterThan(0));
    expect(data, {
      'imageCacheMb': 6,
      'imageCacheImages': 2,
      'liveImages': 1,
      'videoSession': true,
      'playbackActive': true,
      'bufferAheadMs': 35000,
      'imageCacheMbAfter': 0,
      'imageCacheImagesAfter': 0,
      'liveImagesAfter': 0,
    });
  });

  test('a burst records once and the next line counts the warnings it absorbed', () {
    // The shape of the #445 reports: warnings bunched within seconds, then a
    // straggler just inside the interval.
    final start = DateTime.utc(2026, 10, 20, 16, 36, 39);
    warnAt(start);
    warnAt(start.add(const Duration(milliseconds: 200)));
    warnAt(start.add(const Duration(seconds: 2)));
    warnAt(start.add(const Duration(seconds: 29)));
    expect(pressureLines(), hasLength(1));
    expect(pressureLines().single, isNot(contains('suppressed')));

    warnAt(start.add(MemoryPressureLog.logInterval));
    expect(pressureLines(), hasLength(2));
    expect(pressureLines().first, containsPair('suppressed', 3));

    warnAt(start.add(MemoryPressureLog.logInterval * 2));
    expect(pressureLines(), hasLength(3));
    expect(pressureLines().first, isNot(contains('suppressed')));
  });

  test('reports player fields only for a built player and never a negative buffer', () {
    final start = DateTime.utc(2026, 10, 20);
    warnAt(start);
    expect(pressureLines().first, containsPair('videoSession', false));
    expect(pressureLines().first, isNot(contains('playbackActive')));

    PlayerState? playerState;
    registerVideoSession(() => playerState);
    warnAt(start.add(MemoryPressureLog.logInterval));
    expect(pressureLines().first, containsPair('videoSession', true));
    expect(pressureLines().first, isNot(contains('bufferAheadMs')));

    // A forward seek past the cached range leaves the playhead ahead of the
    // cache end until the demuxer refills.
    playerState = const PlayerState(position: Duration(minutes: 5), buffer: Duration(minutes: 2));
    warnAt(start.add(MemoryPressureLog.logInterval * 2));
    expect(pressureLines().first, containsPair('playbackActive', false));
    expect(pressureLines().first, containsPair('bufferAheadMs', 0));
  });
}
