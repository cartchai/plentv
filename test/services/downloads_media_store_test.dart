// 1.2.21 — the shared Downloads collection via MediaStore (Kotlin
// channel). No storage permission is needed for the app's own files on
// API 29+; the Hisense TV is API 31. The native side is only provable
// by the CI release build — these tests prove the Dart side: staging,
// the channel call, the never-throw contract, and the debug seam.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/services/downloads_media_store.dart';

import '../test_helpers/io_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.plentv.app/downloads');
  late Directory tempDir;
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pleztv-downloads-test-');
    originalPathProvider = PathProviderPlatform.instance;
    PathProviderPlatform.instance = FakePathProvider(tempDir);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    DownloadsMediaStore.debugWriteOverride = null;
    PathProviderPlatform.instance = originalPathProvider;
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('writes via the native channel and returns the saved path', () async {
    String? seenFileName;
    String? seenSourcePath;
    String? seenMimeType;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'writeToDownloads');
      final args = call.arguments as Map;
      seenFileName = args['fileName'] as String?;
      seenSourcePath = args['sourcePath'] as String?;
      seenMimeType = args['mimeType'] as String?;
      // The staged file must exist with the exact bytes while the
      // channel call runs.
      expect(await File(seenSourcePath!).readAsBytes(), [1, 2, 3, 4]);
      return '/storage/emulated/0/Download/plentv-autodump.txt';
    });

    final path = await DownloadsMediaStore.writeFile(
      fileName: 'plentv-autodump.txt',
      bytes: Uint8List.fromList([1, 2, 3, 4]),
    );
    expect(path, '/storage/emulated/0/Download/plentv-autodump.txt');
    expect(seenFileName, 'plentv-autodump.txt');
    expect(seenMimeType, 'text/plain');
    // The staging file is deleted after the write.
    expect(await File(seenSourcePath!).exists(), isFalse);
  });

  test('a null channel result reads as no file, never a throw', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(
      await DownloadsMediaStore.writeFile(fileName: 'plentv-autodump.txt', bytes: Uint8List.fromList([1])),
      isNull,
    );
  });

  test('a channel failure reads as no file, never a throw', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(
      await DownloadsMediaStore.writeFile(fileName: 'plentv-autodump.txt', bytes: Uint8List.fromList([1])),
      isNull,
    );
  });

  test('the debug override answers without touching the channel', () async {
    var channelCalled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async {
      channelCalled = true;
      return null;
    });
    DownloadsMediaStore.debugWriteOverride =
        ({required fileName, required bytes, required mimeType}) async =>
            '/storage/emulated/0/Download/$fileName';
    final path = await DownloadsMediaStore.writeFile(
      fileName: 'plentv-autodump.txt',
      bytes: Uint8List.fromList([9]),
    );
    expect(path, '/storage/emulated/0/Download/plentv-autodump.txt');
    expect(channelCalled, isFalse);
  });

  test('a null debug override reads as no file, never a throw', () async {
    DownloadsMediaStore.debugWriteOverride =
        ({required fileName, required bytes, required mimeType}) async => null;
    expect(
      await DownloadsMediaStore.writeFile(fileName: 'plentv-autodump.txt', bytes: Uint8List.fromList([1])),
      isNull,
    );
  });
}
