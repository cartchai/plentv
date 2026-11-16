import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/livetv_channel.dart';

/// 1.2.19 L-47: the guide only offers catch-up for programmes inside the
/// channel's archive window (`tv_archive_duration`). A programme older than
/// the window has no recording to fetch — offering catch-up for it only
/// produces a 404 that looks like a missing recording (or silently plays a
/// newer programme after the player's offset clamp).
void main() {
  const nowEpoch = 1_800_000_000;

  LiveTvChannel channel({bool hasCatchUp = true, int? archiveSeconds}) => LiveTvChannel(
    key: '100',
    title: 'Trex News',
    hasCatchUp: hasCatchUp,
    catchUpArchiveDurationSeconds: archiveSeconds,
  );

  test('a programme from an hour ago inside a 24h archive is offered', () {
    expect(channel(archiveSeconds: 86400).offersCatchUpForProgramStart(nowEpoch - 3600, nowEpoch: nowEpoch), isTrue);
  });

  test('a programme from 2 days ago on a 24h archive is not offered', () {
    expect(
      channel(archiveSeconds: 86400).offersCatchUpForProgramStart(nowEpoch - 2 * 86400, nowEpoch: nowEpoch),
      isFalse,
    );
  });

  test('a programme exactly at the archive edge is offered', () {
    expect(
      channel(archiveSeconds: 86400).offersCatchUpForProgramStart(nowEpoch - 86400, nowEpoch: nowEpoch),
      isTrue,
    );
  });

  test('a programme one second past the archive edge is not offered', () {
    expect(
      channel(archiveSeconds: 86400).offersCatchUpForProgramStart(nowEpoch - 86401, nowEpoch: nowEpoch),
      isFalse,
    );
  });

  test('a future programme is never offered', () {
    expect(channel(archiveSeconds: 86400).offersCatchUpForProgramStart(nowEpoch + 600, nowEpoch: nowEpoch), isFalse);
  });

  test('a channel without catch-up never offers it', () {
    expect(
      channel(hasCatchUp: false, archiveSeconds: 86400).offersCatchUpForProgramStart(nowEpoch - 3600, nowEpoch: nowEpoch),
      isFalse,
    );
  });

  test('an unknown archive duration fails open (the player still clamps the offset)', () {
    expect(channel(archiveSeconds: null).offersCatchUpForProgramStart(nowEpoch - 30 * 86400, nowEpoch: nowEpoch), isTrue);
  });

  test('a zero-second archive offers nothing already started', () {
    expect(channel(archiveSeconds: 0).offersCatchUpForProgramStart(nowEpoch - 60, nowEpoch: nowEpoch), isFalse);
  });
}
