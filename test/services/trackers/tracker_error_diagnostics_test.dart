import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/models/trackers/device_code.dart';
import 'package:plezy/services/trackers/mdblist/mdblist_auth_service.dart';
import 'package:plezy/services/trackers/mdblist/mdblist_client.dart';
import 'package:plezy/services/trackers/tracker_connect_runner.dart';
import 'package:plezy/services/trackers/tracker_exceptions.dart';
import 'package:plezy/services/trackers/tracker_constants.dart';
import 'package:plezy/services/trackers/tracker_session.dart';
import 'package:plezy/utils/app_logger.dart';
import 'package:plezy/utils/log_redaction_manager.dart';

const _canaries = <String>[
  'fint-access-Q7w9',
  'fint-refresh-R8x0',
  'fint-cookie-S9y1',
  'fint-code-T0z2',
  'fint-secret-U1a3',
  'fint-email-V2b4@example.invalid',
  'fint-identifier-W3c5',
  'fint-nested-X4d6',
  'fint-list-Y5e7',
  'fint-unregistered-Z6f8',
];

String get _rejectedBody => json.encode({
  'access_token': _canaries[0],
  'refresh_token': _canaries[1],
  'cookie': _canaries[2],
  'code': _canaries[3],
  'secret': _canaries[4],
  'email': _canaries[5],
  'identifier': _canaries[6],
  'nested': {
    'value': _canaries[7],
    'items': [_canaries[8]],
  },
  'unknown_provider_field': _canaries[9],
});

TrackerSession _session() {
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return TrackerSession(
    accessToken: 'local-access',
    refreshToken: 'local-refresh',
    expiresAt: now + 86400,
    createdAt: now,
    username: 'local-user',
  );
}

Future<bool> _runThroughConnect(Future<void> Function() operation, {required String label}) {
  return runConnectPipeline<Object>(
    logLabel: label,
    authorize: () async {
      await operation();
      return Object();
    },
    enrich: (value) async => value,
    save: (_) async {},
    assign: (_) {},
  );
}

String _retainedDiagnostics() {
  return MemoryLogOutput.getLogs().map((entry) => '${entry.message}\n${entry.error ?? ''}').join('\n');
}

void _expectNoCanaries({required Iterable<String> expectedText}) {
  final diagnostics = _retainedDiagnostics();
  for (final canary in _canaries) {
    expect(diagnostics, isNot(contains(canary)), reason: 'Retained remote response canary: $canary');
  }
  for (final text in expectedText) {
    expect(diagnostics, contains(text));
  }
}

const _deviceCode = DeviceCode(
  deviceCode: 'local-device-code',
  userCode: 'LOCAL-CODE',
  verificationUrl: 'https://example.invalid/activate',
  expiresIn: 600,
  interval: 5,
);

void main() {
  setUp(() {
    MemoryLogOutput.clearLogs();
    LogRedactionManager.clearTrackedValues();
  });

  tearDown(() {
    MemoryLogOutput.clearLogs();
    LogRedactionManager.clearTrackedValues();
  });

  group('tracker API diagnostics', () {
    test('rejected MDBList bodies never reach the real connect catch', () async {
      final client = MdblistClient(
        _session(),
        onSessionInvalidated: () {},
        httpClient: MockClient((_) async => http.Response(_rejectedBody, 503)),
      );
      addTearDown(client.dispose);

      expect(await _runThroughConnect(() async => client.getUser(), label: 'mdblist'), isFalse);
      _expectNoCanaries(
        expectedText: ['mdblist connect failed', 'TrackerApiException(mdblist, HTTP 503)'],
      );
    });

    test('MDBList rate-limit metadata remains typed and body-free', () async {
      final client = MdblistClient(
        _session(),
        onSessionInvalidated: () {},
        httpClient: MockClient((_) async => http.Response(_rejectedBody, 429, headers: {'retry-after': '23'})),
      );
      addTearDown(client.dispose);

      TrackerRateLimitException? thrown;
      try {
        await client.getUser();
      } on TrackerRateLimitException catch (error) {
        thrown = error;
      }
      expect(thrown, isNotNull);
      expect(thrown!.service, TrackerService.mdblist);
      expect(thrown.retryAfterSeconds, 23);

      MemoryLogOutput.clearLogs();
      expect(await _runThroughConnect(() async => client.getUser(), label: 'mdblist'), isFalse);
      _expectNoCanaries(expectedText: ['TrackerRateLimitException(mdblist, retry-after: 23 s)']);
    });
  });

  group('auth diagnostics', () {
    for (final status in [400, 503]) {
      test('MDBList refresh HTTP $status preserves classification without retaining its body', () async {
        final service = MdblistAuthService(
          httpClient: MockClient((_) async => http.Response(_rejectedBody, status)),
        );
        addTearDown(service.dispose);

        TrackerAuthException? thrown;
        try {
          await service.refresh(_session());
        } on TrackerAuthException catch (error) {
          thrown = error;
        }

        expect(thrown, isNotNull);
        expect(thrown!.statusCode, status);
        expect(thrown.isPermanent, status == 400);
        _expectNoCanaries(expectedText: ['MDBList: refresh failed (HTTP $status)']);
      });
    }

    test('MDBList code-creation errors retain only local operation and status', () async {
      final service = MdblistAuthService(
        httpClient: MockClient((_) async => http.Response(_rejectedBody, 502)),
      );
      addTearDown(service.dispose);

      expect(await _runThroughConnect(() async => service.createDeviceCode(), label: 'mdblist'), isFalse);

      _expectNoCanaries(
        expectedText: ['DeviceCodeAuthFlowException: MDBList device code request failed: HTTP 502'],
      );
    });

    test('MDBList unexpected poll response remains pending with fixed status diagnostics', () async {
      final service = MdblistAuthService(
        httpClient: MockClient((_) async => http.Response(_rejectedBody, 451)),
      );
      addTearDown(service.dispose);

      expect(await service.probe(_deviceCode), isA<DevicePollPending>());

      _expectNoCanaries(expectedText: ['MDBList device-code unexpected response (HTTP 451, error=null)']);
    });

    test('MDBList device poll error mapping remains unchanged', () async {
      // Unlike Trakt, MDBList reports poll state in the JSON body, so the
      // mapping switches on `error`, not the status code.
      for (final testCase in <({int status, String body, Matcher matcher})>[
        (status: 200, body: json.encode({'access_token': 'local-token'}), matcher: isA<DevicePollSuccess>()),
        (status: 400, body: json.encode({'error': 'authorization_pending'}), matcher: isA<DevicePollPending>()),
        (status: 400, body: json.encode({'error': 'slow_down'}), matcher: isA<DevicePollSlowDown>()),
        (status: 400, body: json.encode({'error': 'access_denied'}), matcher: isA<DevicePollDenied>()),
        (status: 400, body: json.encode({'error': 'expired_token'}), matcher: isA<DevicePollExpired>()),
        (status: 400, body: json.encode({'error': 'device_not_found'}), matcher: isA<DevicePollExpired>()),
      ]) {
        final service = MdblistAuthService(
          httpClient: MockClient((_) async => http.Response(testCase.body, testCase.status)),
        );
        try {
          expect(await service.probe(_deviceCode), testCase.matcher);
        } finally {
          service.dispose();
        }
      }
      _expectNoCanaries(expectedText: const []);
    });
  });
}
