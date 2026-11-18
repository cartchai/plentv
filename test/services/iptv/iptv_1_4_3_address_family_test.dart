// Failing-first tests for 1.4.3 D2 (address-family logging).
//
// The refusal log never recorded which address family a refusal
// happened on, so a 403 that only happens on IPv6 could not be told
// apart from one that happens on both. D2 records the family label
// only ('ipv4' | 'ipv6' | 'dual' | 'unknown') — never an address —
// on the entry, resolves it at record time, and surfaces the latest
// refusal's family in the debug summary block.
//
// No live panel: fakes only. These tests reference the new API, so
// they fail to compile on the base (1.4.2) and pass on the fix.
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/base_shared_preferences_service.dart';
import 'package:plezy/services/debug_log_export_service.dart';
import 'package:plezy/services/iptv/iptv_refusal_log.dart';
import 'package:plezy/services/iptv/panel_reachability_store.dart';

import '../../test_helpers/prefs.dart';

IptvRefusalEntry _entry({
  String action = 'player_api.php?action=get_live_categories',
  int? statusCode = 403,
  String network = 'wifi',
  String addressFamily = 'unknown',
  DateTime? timestamp,
}) {
  return IptvRefusalEntry(
    timestamp: timestamp ?? DateTime.utc(2026, 11, 18, 5, 40, 12),
    connectionId: 'trex',
    connectionName: 'Trex',
    action: action,
    statusCode: statusCode,
    failureKind: 'http',
    network: network,
    addressFamily: addressFamily,
  );
}

IptvRefusalLog _log({Future<String> Function()? familyProvider}) => IptvRefusalLog(
  prefsProvider: BaseSharedPreferencesService.sharedCache,
  networkTypeProvider: () async => 'wifi',
  addressFamilyProvider: familyProvider ?? () async => 'ipv6',
);

void main() {
  setUp(() {
    resetSharedPreferencesForTest();
    addTearDown(() {
      PanelReachabilityStore.debugAddressFamiliesOverride = null;
    });
  });

  group('currentAddressFamilies', () {
    test('live enumeration returns one of the four labels, never throws', () async {
      final families = await PanelReachabilityStore.currentAddressFamilies();
      expect(families, isIn(const ['ipv4', 'ipv6', 'dual', 'unknown']));
    });

    test('the test override is honoured', () async {
      PanelReachabilityStore.debugAddressFamiliesOverride = 'dual';
      expect(await PanelReachabilityStore.currentAddressFamilies(), 'dual');
    });
  });

  group('IptvRefusalEntry', () {
    test('the family round-trips through JSON', () async {
      final entry = _entry(addressFamily: 'ipv6');
      final restored = IptvRefusalEntry.fromJson(entry.toJson());
      expect(restored.addressFamily, 'ipv6');
      expect(entry.toJson()['family'], 'ipv6');
    });

    test('entries written before 1.4.3 (no family key) read as unknown', () async {
      final json = _entry(addressFamily: 'ipv6').toJson()..remove('family');
      expect(IptvRefusalEntry.fromJson(json).addressFamily, 'unknown');
    });

    test('the share text carries the family label and no address', () async {
      final text = _entry(addressFamily: 'ipv6').toShareText();
      expect(text, contains('Address family: ipv6'));
      // The entry never holds an address — a family label is the only
      // address-shaped thing that may appear. (A generic colon-group
      // pattern would also match the timestamp, so check the concrete
      // shapes a leaked address would take.)
      for (final marker in const ['192.168.', '10.', '2001:', 'fd00:', 'fe80:', '::1']) {
        expect(text, isNot(contains(marker)), reason: 'no address leaks via $marker');
      }
    });
  });

  group('IptvRefusalLog.record', () {
    test('resolves the family via the provider when the entry has none', () async {
      final log = _log();
      await log.record(_entry(addressFamily: 'unknown'));
      final entries = await log.loadEntries();
      expect(entries, hasLength(1));
      expect(entries.single.addressFamily, 'ipv6');
    });

    test('keeps a family the entry already carries', () async {
      var providerCalls = 0;
      final log = _log(
        familyProvider: () async {
          providerCalls++;
          return 'ipv6';
        },
      );
      await log.record(_entry(addressFamily: 'dual'));
      final entries = await log.loadEntries();
      expect(entries.single.addressFamily, 'dual');
      expect(providerCalls, 0, reason: 'a known family is not re-resolved');
    });

    test('a throwing family provider yields unknown and the entry still records', () async {
      final log = _log(familyProvider: () async => throw StateError('no interfaces'));
      await log.record(_entry(addressFamily: 'unknown'));
      final entries = await log.loadEntries();
      expect(entries, hasLength(1));
      expect(entries.single.addressFamily, 'unknown');
    });
  });

  group('debug summary', () {
    test('the summary names the latest refusal and its family', () async {
      final log = _log();
      await log.record(_entry(addressFamily: 'ipv6'));
      final summary = await DebugLogExportService.buildSummarySection(
        baseLogsText: 'nothing here',
        dumpReason: 'test',
        failedStarts: 0,
      );
      expect(summary, contains('IPTV refusals: 1 recorded, latest HTTP 403 on wifi (ipv6)'));
    });

    test('the summary says none recorded when the log is empty', () async {
      final summary = await DebugLogExportService.buildSummarySection(
        baseLogsText: 'nothing here',
        dumpReason: 'test',
        failedStarts: 0,
      );
      expect(summary, contains('IPTV refusals: none recorded'));
    });
  });
}
