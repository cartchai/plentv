// 1.5.3 K1: the Downloads tree must not merge multi-season Xtream
// downloads into one season row. Episodes stored before 1.5.3 carry the
// SHOW as parentId (`series:<id>`); the season lives only in parentIndex.
// The tree must split them by season.
//
// FAILING-FIRST: on the 1.5.2 base both seasons share the parentId
// `series:123`, so the tree shows a single "Season 1" row holding episodes
// from both seasons.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/widgets/download_tree_view.dart';

/// An Xtream episode exactly as 1.5.2 stored it: the SHOW as parentId,
/// the season only in parentIndex.
MediaItem oldXtreamLeaf({required String id, required int episode, required int season}) => MediaItem.xtream(
  id: id,
  kind: MediaKind.episode,
  title: 'Episode $id',
  serverId: ServerId('srv'),
  grandparentId: '123',
  grandparentTitle: 'South Park',
  parentId: 'series:123',
  parentTitle: 'Season $season',
  parentIndex: season,
  index: episode,
);

void main() {
  group('1.5.3 K1: Downloads tree splits multi-season Xtream downloads', () {
    Future<void> pumpTree(WidgetTester tester, Map<String, MediaItem> metadata, Map<String, DownloadStatus> initial) async {
      final downloads = ValueNotifier<Map<String, DownloadProgress>>({
        for (final entry in initial.entries) entry.key: DownloadProgress(globalKey: entry.key, status: entry.value),
      });
      addTearDown(downloads.dispose);
      await tester.pumpWidget(
        InputModeTracker(
          child: MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<Map<String, DownloadProgress>>(
                valueListenable: downloads,
                builder: (context, value, _) => DownloadTreeView(
                  downloads: value,
                  metadata: metadata,
                  onPause: (_) {},
                  onRetry: (_) {},
                  onRetryAll: (_) {},
                  onDelete: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Nodes start collapsed: tap the show row to reveal its seasons.
      await tester.tap(find.text('South Park'));
      await tester.pumpAndSettle();
    }

    testWidgets('old leaves in two seasons show two season rows', (tester) async {
      await pumpTree(tester, {
        'srv:episode:123:3823': oldXtreamLeaf(id: 'episode:123:3823', episode: 1, season: 1),
        'srv:episode:123:3824': oldXtreamLeaf(id: 'episode:123:3824', episode: 2, season: 1),
        'srv:episode:123:3900': oldXtreamLeaf(id: 'episode:123:3900', episode: 1, season: 2),
      }, {
        'srv:episode:123:3823': DownloadStatus.completed,
        'srv:episode:123:3824': DownloadStatus.completed,
        'srv:episode:123:3900': DownloadStatus.completed,
      });

      expect(find.text('South Park'), findsOneWidget);
      expect(find.text('Season 1'), findsOneWidget, reason: 'S1 must be its own row');
      expect(find.text('Season 2'), findsOneWidget, reason: 'S2 must be its own row, not merged into S1');
    });
  });
}
