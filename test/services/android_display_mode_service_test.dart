import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/android_display_mode_service.dart';
import 'package:plezy/utils/device_channel.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  /// Answers `com.plezy/device` and records each call. A null [reply]
  /// leaves the method unimplemented, which is what desktop and a stale
  /// native build look like.
  List<MethodCall> stubDevice(Object? Function(MethodCall call) reply) {
    final calls = <MethodCall>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(deviceChannel, (call) async {
      calls.add(call);
      return reply(call);
    });
    addTearDown(() => binding.defaultBinaryMessenger.setMockMethodCallHandler(deviceChannel, null));
    return calls;
  }

  test('setSurfaceRenderMode invokes the device channel (1.2.19 L-27)', () async {
    final calls = stubDevice((_) => true);

    expect(await AndroidDisplayModeService.setSurfaceRenderMode(true), isTrue);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'setSurfaceRenderMode');
    expect(calls.single.arguments, isTrue);
  });

  test('setSurfaceRenderMode is a logged no-op without a native handler', () async {
    stubDevice((_) => throw MissingPluginException());

    expect(await AndroidDisplayModeService.setSurfaceRenderMode(true), isFalse);
  });

  test('getSurfaceRenderMode reads the native flag', () async {
    stubDevice((_) => true);

    expect(await AndroidDisplayModeService.getSurfaceRenderMode(), isTrue);
  });

  test('setUi1080pMode invokes the device channel (1.2.19 L-18)', () async {
    final calls = stubDevice((_) => true);

    expect(await AndroidDisplayModeService.setUi1080pMode(true), isTrue);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'setUi1080pMode');
    expect(calls.single.arguments, isTrue);
  });

  test('setUi1080pMode is a logged no-op without a native handler', () async {
    stubDevice((_) => throw MissingPluginException());

    expect(await AndroidDisplayModeService.setUi1080pMode(true), isFalse);
  });

  test('describeDisplayModes returns the native description', () async {
    stubDevice((_) => 'current=#1 3840x2160@60.0Hz supported=[#1 3840x2160@60.0Hz]');

    expect(
      await AndroidDisplayModeService.describeDisplayModes(),
      'current=#1 3840x2160@60.0Hz supported=[#1 3840x2160@60.0Hz]',
    );
  });
}
