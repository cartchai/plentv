import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/decoder_failure_memo.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_helpers/prefs.dart';

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    DecoderFailureMemo.debugResetForTesting();
  });

  Future<DecoderFailureMemo> freshMemo() => DecoderFailureMemo.getInstance();

  test('one rejection does not memo, two do (1.2.18 C-10)', () async {
    final memo = await freshMemo();
    expect(memo.shouldStartOnGlVo('chan-a'), isFalse);
    await memo.recordRejection('chan-a');
    expect(memo.shouldStartOnGlVo('chan-a'), isFalse);
    expect(memo.debugFailuresFor('chan-a'), 1);
    await memo.recordRejection('chan-a');
    expect(memo.shouldStartOnGlVo('chan-a'), isTrue);
    expect(memo.debugFailuresFor('chan-a'), 2);
  });

  test('a clean hardware decode clears the count (1.2.18 C-10)', () async {
    final memo = await freshMemo();
    await memo.recordRejection('chan-a');
    await memo.recordRejection('chan-a');
    expect(memo.shouldStartOnGlVo('chan-a'), isTrue);
    await memo.recordSuccess('chan-a');
    expect(memo.shouldStartOnGlVo('chan-a'), isFalse);
    expect(memo.debugFailuresFor('chan-a'), 0);
  });

  test('entries survive a restart through prefs (1.2.18 C-10)', () async {
    final first = await freshMemo();
    await first.recordRejection('chan-a');
    await first.recordRejection('chan-a');
    expect(first.shouldStartOnGlVo('chan-a'), isTrue);

    // A fresh instance (as after an app restart) re-reads the blob.
    DecoderFailureMemo.debugResetForTesting();
    final second = await DecoderFailureMemo.getInstance();
    expect(second.shouldStartOnGlVo('chan-a'), isTrue);
  });

  test('entries older than 7 days expire on load (1.2.18 C-10)', () async {
    final staleMs = DateTime.now().subtract(const Duration(days: 8)).millisecondsSinceEpoch;
    await SharedPreferencesAsync().setString(
      'decoder_failure_memo_v1',
      jsonEncode({
        'chan-a': {'failures': 2, 'lastRejectedAtMs': staleMs},
      }),
    );
    final memo = await freshMemo();
    expect(memo.shouldStartOnGlVo('chan-a'), isFalse);
    expect(memo.debugFailuresFor('chan-a'), 0);
  });

  test('clearAll forgets every channel (1.2.18 C-10)', () async {
    final memo = await freshMemo();
    await memo.recordRejection('chan-a');
    await memo.recordRejection('chan-a');
    await memo.recordRejection('chan-b');
    await memo.recordRejection('chan-b');
    expect(memo.shouldStartOnGlVo('chan-a'), isTrue);
    expect(memo.shouldStartOnGlVo('chan-b'), isTrue);
    await memo.clearAll();
    expect(memo.shouldStartOnGlVo('chan-a'), isFalse);
    expect(memo.shouldStartOnGlVo('chan-b'), isFalse);
  });

  test('a corrupt blob starts empty instead of throwing (1.2.18 C-10)', () async {
    await SharedPreferencesAsync().setString('decoder_failure_memo_v1', '{not json');
    final memo = await freshMemo();
    expect(memo.shouldStartOnGlVo('chan-a'), isFalse);
    await memo.recordRejection('chan-a');
    expect(memo.debugFailuresFor('chan-a'), 1);
  });
}
