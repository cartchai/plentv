// Failing-first test for PlenTV 1.6.17 (WARP tunnel fail-fast).
//
// The 1.6.16 tunnel still failed to start on a real phone — with a
// NEW error, one step past the 1.6.16 address fix (the old
// `cannot unmarshal` error was gone, the config parsed):
//   PlatformException(START_FAILED, initialize network: invalid argument)
// — twice, each time burning all five proxy ports (18081–18085) with
// the identical error, ~50 ms apart.
//
// Root cause (research paper
// ~/workspace/tmp_work/plezy-tv-research-warp-initnet/
// RESEARCH_WARP_INITNET.md): PlenTV's own Go platform stub told
// sing-box to use the platform interface monitor, then handed it a
// monitor whose Start() unconditionally returns os.ErrInvalid.
// sing-box starts it during box.Start() and wraps the error. The Go
// fix is one line (UsePlatformDefaultInterfaceMonitor() -> false).
// This Dart test covers the Dart half only: the fail-fast must also
// recognise this error class, so a start failure with it tries
// exactly one port instead of five.
//
// A Dart test can never catch the Go stub defect itself — the defect
// is below Dart. The Go side is covered by
// android/warpbox/warpbox_test.go TestStartStopAndFailClosed, which
// calls the real Start() and must be run with
// -tags with_wireguard,with_gvisor before shipping.
//
// No live panel, no live Cloudflare API, no real sing-box (tests run
// on Linux, where the Kotlin channel does not exist): the platform
// channel is mocked. The real tunnel data path is phone-proof only.
// On the 1.6.16 base this test FAILS — the error is not in
// isConfigError, so the start retries all five ports.
//
// Fixtures use the fixed zero-key test private key (never a real
// credential) and Cloudflare's public shared WARP peer key.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/iptv/warp_tunnel_service.dart';
import 'package:plezy/services/settings_service.dart';

import '../../test_helpers/prefs.dart';

/// The fixed zero-key test private key (base64 of 32 zero bytes): a
/// fixture, never a real credential.
const _testPrivateKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

/// Cloudflare's public shared WARP peer key (the same key every WARP
/// client uses — public, not a secret).
const _warpPeerKey = 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=';

/// A stored registration in the 1.6.16 shape (prefixed addresses, as
/// the 1.6.16 fix stores them).
Map<String, dynamic> _storedRegistrationJson() => {
      'privateKey': _testPrivateKey,
      'addresses': ['172.16.0.2/32', '2606:4700:110:8000::2/128'],
      'peer': {
        'type': 'warp',
        'endpointHost': 'engage.cloudflareclient.com',
        'endpointPort': 2408,
        'publicKey': _warpPeerKey,
      },
      'token': 'test-token',
      'accountId': 'test-account-id',
      'clientId': 'test-client-id',
    };

/// The method calls the Dart side sent to the Kotlin warp channel.
class _ChannelCalls {
  final List<MethodCall> calls = [];
}

void _mockWarpChannel(_ChannelCalls calls, {Object? Function(MethodCall)? start}) {
  const channel = MethodChannel('com.plentv.app/warp_tunnel');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    calls.calls.add(call);
    if (call.method == 'start') {
      final result = start?.call(call);
      if (result != null) throw result;
      return 'ok';
    }
    if (call.method == 'stop') return 'ok';
    throw MissingPluginException('unknown method ${call.method}');
  });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );
}

Future<void> _acceptTermsAndEnable() async {
  await SettingsService.instance.write(SettingsService.iptvWarpTermsAccepted, true);
  await SettingsService.instance.write(SettingsService.iptvWarpVpn, true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetSharedPreferencesForTest);
  setUp(() async {
    await SettingsService.getInstance();
  });

  group('1.6.17 WARP: an init-time error fails fast', () {
    test('a start failing with "initialize network" tries exactly one port', () async {
      final service = WarpTunnelService();
      addTearDown(service.dispose);
      final calls = _ChannelCalls();
      // The exact error Matt's 1.6.16 phone log showed, twice — once
      // per attempt, five ports each time.
      _mockWarpChannel(
        calls,
        start: (_) => PlatformException(
          code: 'START_FAILED',
          message: 'initialize network: invalid argument',
        ),
      );
      await _acceptTermsAndEnable();
      await SettingsService.instance.write(
        SettingsService.iptvWarpRegistration,
        jsonEncode(_storedRegistrationJson()),
      );

      final started = await service.start();

      expect(started, isFalse);
      expect(service.state, WarpTunnelState.failed);
      expect(service.lastError, contains('initialize network'));
      // One attempt, not five: an init-time error fails on every
      // port by construction — the port loop exists only for bind
      // failures.
      expect(calls.calls.where((c) => c.method == 'start'), hasLength(1));
      expect(
        SettingsService.instance.read(SettingsService.iptvWarpVpn),
        isFalse,
      );
    });
  });
}
