import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/main.dart';
import 'package:plezy/services/sensitive_prefs.dart';
import 'package:plezy/services/startup_diagnostics.dart';
import 'package:plezy/utils/log_redaction_manager.dart';

StartupFailureRecord _record({
  StartupPhase? phase = StartupPhase.database,
  Object error = const FormatException('boom'),
  StackTrace? stackTrace,
  bool repairable = false,
}) => StartupFailureRecord.fromError(
  phase: phase,
  error: error,
  stackTrace: stackTrace,
  appVersion: '2.11.0+124',
  platform: 'windows 11',
  repairable: repairable,
);

void main() {
  late Directory tempDir;

  setUp(() async {
    LogRedactionManager.clearTrackedValues();
    StartupDiagnosticsStore.resetForTesting();
    tempDir = await Directory.systemTemp.createTemp('plezy-startup-diagnostics');
    StartupDiagnosticsStore.debugDirectoryOverride = tempDir;
  });

  tearDown(() async {
    StartupDiagnosticsStore.resetForTesting();
    LogRedactionManager.clearTrackedValues();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('StartupPhaseException', () {
    test('unwraps to the real cause and reports the phase', () {
      const inner = FormatException('inner');
      const wrapped = StartupPhaseException(StartupPhase.storage, inner);

      expect(StartupPhaseException.unwrap(wrapped), same(inner));
      expect(StartupPhaseException.phaseOf(wrapped), StartupPhase.storage);
      expect(StartupPhaseException.unwrap(inner), same(inner));
    });

    test('a record built from a wrapper describes the cause, not the wrapper', () {
      final record = StartupFailureRecord.fromError(
        error: const StartupPhaseException(StartupPhase.database, FormatException('inner')),
        stackTrace: StackTrace.empty,
        appVersion: 'v',
        platform: 'p',
      );

      expect(record.phase, StartupPhase.database);
      expect(record.errorType, 'FormatException');
    });
  });

  group('describeErrorSafely', () {
    test('drops the source excerpt a FormatException carries', () {
      final key = base64Encode(List<int>.generate(32, (i) => i));
      final source = '{"$credentialVaultKeyPref":"$key","truncated';
      late final FormatException raw;
      try {
        jsonDecode(source);
        fail('expected a FormatException');
      } on FormatException catch (error) {
        raw = error;
      }
      expect(raw.toString(), contains(key), reason: 'precondition: the raw error does leak the key');

      final described = StartupFailureRecord.describeErrorSafely(raw);

      expect(described, isNot(contains(key)));
      expect(described, contains('offset'));
    });

    test('a record never persists the leaked excerpt', () async {
      final key = base64Encode(List<int>.generate(32, (i) => i));
      late final FormatException raw;
      try {
        jsonDecode('{"$credentialVaultKeyPref":"$key","truncated');
        fail('expected a FormatException');
      } on FormatException catch (error) {
        raw = error;
      }

      final record = _record(error: raw);
      await StartupDiagnosticsStore.record(record);

      final onDisk = await File('${tempDir.path}/${StartupDiagnosticsStore.fileName}').readAsString();
      expect(record.describe(), isNot(contains(key)));
      expect(onDisk, isNot(contains(key)));
    });

    test('leaves other error types alone', () {
      expect(StartupFailureRecord.describeErrorSafely(StateError('plain')), contains('plain'));
    });
  });

  group('record contents', () {
    test('redacts registered secrets out of the message', () {
      LogRedactionManager.registerToken('super-secret-token');

      final record = _record(error: StateError('failed with super-secret-token'));

      expect(record.message, isNot(contains('super-secret-token')));
    });

    test('describe() carries the phase, type and build for a bug report', () {
      final text = _record(error: StateError('nope')).describe();

      expect(text, contains('Phase: database'));
      expect(text, contains('Error: StateError'));
      expect(text, contains('2.11.0+124'));
      expect(text, contains('windows 11'));
    });

    test('describe() states whether a repair was on offer', () {
      // An uploaded record is usually the only artefact a maintainer gets. On
      // #1732 it could not distinguish "the screen offered no way forward"
      // from "a repair was offered and not taken", and the thread stalled.
      expect(_record(repairable: true).describe(), contains('Repair offered: yes'));
      expect(_record().describe(), contains('Repair offered: no'));
    });

    test('headline stays one line', () {
      expect(_record().headline, startsWith('[database] FormatException'));
    });
  });

  group('persistence', () {
    test('round-trips a record through disk', () async {
      final original = _record(error: StateError('disk failure'), stackTrace: StackTrace.fromString('#0 frame'));
      await StartupDiagnosticsStore.record(original);
      StartupDiagnosticsStore.resetForTesting();
      StartupDiagnosticsStore.debugDirectoryOverride = tempDir;

      final restored = await StartupDiagnosticsStore.consumePrevious();

      expect(restored, isNotNull);
      expect(restored!.phase, StartupPhase.database);
      expect(restored.errorType, 'StateError');
      expect(restored.message, contains('disk failure'));
      expect(restored.stackTrace, contains('#0 frame'));
    });

    test('consuming a reported record deletes it but keeps it in-session', () async {
      final record = _record();
      await StartupDiagnosticsStore.record(record);
      await StartupDiagnosticsStore.markReported(record);
      StartupDiagnosticsStore.resetForTesting();
      StartupDiagnosticsStore.debugDirectoryOverride = tempDir;

      await StartupDiagnosticsStore.consumePrevious();

      expect(await File('${tempDir.path}/${StartupDiagnosticsStore.fileName}').exists(), isFalse);
      expect(StartupDiagnosticsStore.pending, isNotNull);
    });

    test('consuming an unreported record keeps it on disk for the next launch', () async {
      // The crash reporter may have been offline, opted out, or backed by a
      // no-op hub. Deleting here would silently end the only retry there is.
      await StartupDiagnosticsStore.record(_record());
      StartupDiagnosticsStore.resetForTesting();
      StartupDiagnosticsStore.debugDirectoryOverride = tempDir;

      final consumed = await StartupDiagnosticsStore.consumePrevious();

      expect(consumed, isNotNull);
      expect(await File('${tempDir.path}/${StartupDiagnosticsStore.fileName}').exists(), isTrue);
      expect(StartupDiagnosticsStore.pending, isNotNull);
    });

    test('consuming nothing yields null', () async {
      expect(await StartupDiagnosticsStore.consumePrevious(), isNull);
      expect(StartupDiagnosticsStore.pending, isNull);
    });

    test('a malformed record is ignored rather than thrown', () async {
      await File('${tempDir.path}/${StartupDiagnosticsStore.fileName}').writeAsString('not json');

      expect(await StartupDiagnosticsStore.consumePrevious(), isNull);
    });

    test('clear removes both the file and the pending record', () async {
      await StartupDiagnosticsStore.record(_record());

      await StartupDiagnosticsStore.clear();

      expect(await File('${tempDir.path}/${StartupDiagnosticsStore.fileName}').exists(), isFalse);
      expect(StartupDiagnosticsStore.pending, isNull);
    });

    test('an unwritable location degrades instead of failing the failure path', () async {
      StartupDiagnosticsStore.debugDirectoryOverride = Directory('${tempDir.path}/missing/deeper');

      await expectLater(StartupDiagnosticsStore.record(_record()), completes);
      // Still exposed in-session even when it could not be written.
      expect(StartupDiagnosticsStore.pending, isNotNull);
    });
  });

  group('phase ids', () {
    test('round-trip through their stable wire form', () {
      for (final phase in StartupPhase.values) {
        expect(StartupPhase.fromId(phase.id), phase, reason: phase.name);
      }
      expect(StartupPhase.fromId('nonexistent'), isNull);
      expect(StartupPhase.fromId(null), isNull);
    });
  });

  group('persisted startup failure acknowledgement', () {
    // 1.2.22 §66 (U4): there is no crash reporter any more (Sentry is
    // cut — its DSN was dead in shipped builds), so nothing is ever sent.
    // The persisted record is acknowledged locally instead: marked
    // reported so the success path can consume the file instead of
    // carrying it forever, while the record itself stays visible for the
    // session in Settings › Logs, where the user can submit it to our
    // GitHub repo. The send / opted-out / empty-id tests die with the
    // reporter — there is no send to fail, no opt-out to honour, and no
    // id that could prove delivery.

    test('acknowledges a persisted record once and marks it reported', () async {
      await StartupDiagnosticsStore.record(_record(phase: StartupPhase.preferences));

      await acknowledgePersistedStartupFailure();

      expect((await StartupDiagnosticsStore.peekPersisted())!.reported, isTrue);

      // A later launch must not change it.
      await acknowledgePersistedStartupFailure();
      expect((await StartupDiagnosticsStore.peekPersisted())!.reported, isTrue);
      expect((await StartupDiagnosticsStore.peekPersisted())!.phase, StartupPhase.preferences);
    });

    test('does nothing when no launch has failed', () async {
      await acknowledgePersistedStartupFailure();

      expect(await StartupDiagnosticsStore.peekPersisted(), isNull);
    });

    test('consumption waits for a registered acknowledgement', () async {
      await StartupDiagnosticsStore.record(_record());
      final reading = Completer<void>();
      final release = Completer<void>();
      StartupDiagnosticsStore.debugAfterReportedRead = () {
        if (!reading.isCompleted) reading.complete();
        return release.future;
      };
      addTearDown(() => StartupDiagnosticsStore.debugAfterReportedRead = null);

      StartupDiagnosticsStore.holdForFlush(acknowledgePersistedStartupFailure());
      await reading.future;

      // The success path would otherwise delete the file mid-acknowledgement.
      final consumed = StartupDiagnosticsStore.consumePrevious();
      var finished = false;
      unawaited(consumed.then((_) => finished = true));
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse, reason: 'consumption must not race the acknowledgement');

      release.complete();
      expect((await consumed)!.reported, isTrue);
    });

    // The slow-acknowledgement race (a retry recording a newer failure
    // while the acknowledgement is mid-flight) is covered by 'marking
    // reported never resurrects a record a retry superseded' below: the
    // acknowledgement is peek + markReported, and the compare-and-set
    // inside markReported is what protects the newer record. (Pausing
    // the acknowledgement inside markReported's queued write and then
    // recording the retry deadlocks by construction — the retry queues
    // behind the paused write — so the race is exercised at the
    // markReported level, not through the acknowledgement.)
    test('records are individually identifiable', () {
      expect(_record().id, isNot(_record().id));
      // copyWith preserves identity, or the compare-and-set above cannot work.
      final record = _record();
      expect(record.copyWith(reported: true).id, record.id);
    });

    test('a peek settles an unawaited write first', () async {
      // The failure path launches `record()` unawaited, so a fast retry can
      // reach the acknowledgement before the file exists.
      unawaited(StartupDiagnosticsStore.record(_record(phase: StartupPhase.preferences)));

      final peeked = await StartupDiagnosticsStore.peekPersisted();

      expect(peeked?.phase, StartupPhase.preferences);
    });

    test('a consume settles an unawaited write first', () async {
      final record = _record();
      unawaited(StartupDiagnosticsStore.record(record));
      await StartupDiagnosticsStore.markReported(record);

      expect(await StartupDiagnosticsStore.consumePrevious(), isNotNull);
      // No stale file left behind by a late write.
      expect(await StartupDiagnosticsStore.peekPersisted(), isNull);
    });

    test('concurrent writes land in record order', () async {
      // Two unawaited writes to one file: without a queue the older one can
      // finish last and overwrite the newer failure.
      final first = _record(phase: StartupPhase.preferences);
      final second = _record(phase: StartupPhase.database);
      unawaited(StartupDiagnosticsStore.record(first));
      unawaited(StartupDiagnosticsStore.record(second));

      expect((await StartupDiagnosticsStore.peekPersisted())!.id, second.id);
    });

    test('marking reported never resurrects a record a retry superseded', () async {
      // Deterministic interleave: pause the compare-and-set between its read
      // and its write, let a retry record a newer failure, then release it.
      // Outside the write queue the mark would land last and overwrite B.
      final first = _record(phase: StartupPhase.preferences);
      await StartupDiagnosticsStore.record(first);

      final reading = Completer<void>();
      final release = Completer<void>();
      StartupDiagnosticsStore.debugAfterReportedRead = () {
        if (!reading.isCompleted) reading.complete();
        return release.future;
      };
      addTearDown(() => StartupDiagnosticsStore.debugAfterReportedRead = null);

      final marking = StartupDiagnosticsStore.markReported(first);
      await reading.future;

      final second = _record(phase: StartupPhase.database);
      final writingSecond = StartupDiagnosticsStore.record(second);

      release.complete();
      await marking;
      await writingSecond;

      final persisted = await StartupDiagnosticsStore.peekPersisted();
      expect(persisted!.id, second.id, reason: 'the newer failure must survive');
      expect(persisted.reported, isFalse, reason: 'the newer failure was never acknowledged');
    });

    test('an acknowledged record is consumed by the success path and never reappears', () async {
      // End to end: the record is acknowledged on the next launch, the
      // success path consumes it, and no stale file is left behind.
      await StartupDiagnosticsStore.record(_record());
      await acknowledgePersistedStartupFailure();
      await StartupDiagnosticsStore.consumePrevious();

      expect(await StartupDiagnosticsStore.peekPersisted(), isNull);
    });

    test('peeking leaves the record on disk for the display path', () async {
      await StartupDiagnosticsStore.record(_record());

      await StartupDiagnosticsStore.peekPersisted();

      expect(await StartupDiagnosticsStore.consumePrevious(), isNotNull);
    });
  });
}
