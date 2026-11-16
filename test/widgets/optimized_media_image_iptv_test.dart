import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/connection/connection.dart';
import 'package:plezy/media/iptv_client.dart';
import 'package:plezy/utils/media_image_helper.dart';
import 'package:plezy/widgets/optimized_media_image.dart';

/// 1.2.19 L-30: IPTV artwork renders thumbnail-first, full after — the
/// same URL decoded twice (small bound, then display size), not one
/// full-resolution decode. Non-IPTV artwork is unchanged (one stage —
/// the existing `optimized_media_image_test.dart` pins that).
void main() {
  testWidgets('IPTV poster decodes the thumbnail first, then the full image', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    // Pin the display so the Linux-compositor fallback (display width /
    // 1920) can't raise the ratio out from under the assertion.
    tester.view.display.size = const Size(1920, 1080);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.display.reset);
    const imageUrl = 'https://example.invalid/iptv-poster.jpg';
    // A real client with a dummy connection: construction does no I/O
    // (the API client is lazy), and the widget only reads its artwork
    // headers. The password is a dummy single character, not a secret.
    final iptv = IptvClient.xtream(
      xtreamConnection: XtreamConnection(
        id: 'test',
        name: 'Test',
        serverUrl: 'https://example.invalid',
        username: 'test',
        password: 'x',
        createdAt: DateTime(2026, 1, 1),
      ),
    );
    addTearDown(iptv.close);

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 600,
          child: OptimizedMediaImage.poster(client: iptv, imagePath: imageUrl, width: 400, height: 600),
        ),
      ),
    );

    // Two Images in the tree: the full image, and the thumbnail painting
    // underneath it as the placeholder while the full decode runs.
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, hasLength(2));
    final widths = images.map((image) => (image.image as ResizeImage).width).toSet();
    final (fullWidth, _) = MediaImageHelper.getMemCacheDimensions(displayWidth: 400, displayHeight: 600);
    expect(widths, {160, fullWidth});
    expect(fullWidth, 400);
    // Same URL, same disk-cache bytes — the staging is decode order,
    // not a second download.
    final providers = images
        .map((image) => (image.image as ResizeImage).imageProvider as CachedNetworkImageProvider)
        .toList();
    expect(providers.map((p) => p.url).toSet(), {imageUrl});
    expect(providers.map((p) => p.cacheKey).toSet(), hasLength(1));
  });

  testWidgets('IPTV poster with no client is a single full decode, like any other artwork', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.display.size = const Size(1920, 1080);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.display.reset);
    const imageUrl = 'https://example.invalid/iptv-poster-no-client.jpg';

    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 400,
          height: 600,
          child: OptimizedMediaImage.poster(imagePath: imageUrl, width: 400, height: 600),
        ),
      ),
    );

    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, hasLength(1));
    expect((images.single.image as ResizeImage).width, 400);
  });
}
