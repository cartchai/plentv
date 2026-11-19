// 1.4.6 downloads grouping — G3: the Downloads tree must relabel
// already-queued downloads without re-queueing them. An episode queued
// before 1.4.6 carries the series name in parentTitle and nothing in
// grandparentTitle (the 1.4.5 builder bug); the tree must still show the
// series name as the show row and "Season N" as the season row — not
// "Unknown Show" with the series name as its season (the user's
// screenshot).
//
// FAILING-FIRST: on the 1.4.5 base the tree reads grandparentTitle for the
// show row (null → "Unknown Show") and parentTitle for the season row
// (the series name), so both assertions below fail.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/focus/input_mode_tracker.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/download_models.dart';
import 'package:plezy/widgets/download_tree_view.dart';
import '../test_helpers/media_items.dart';

/// An episode exactly as 1.4.5 queued it: the series name sits in
/// parentTitle, grandparentTitle was never set.
MediaItem _oldLeaf({required String id, required int episode}) => testMediaItem(
  id: id,
  backend: MediaBackend.plex,
  kind: MediaKind.episode,
  title: 'Episode $id',
  serverId: ServerId('srv'),
  grandparentId: '123',
  grandparentTitle: null,
  parentId: 'series:123',
  parentTitle: 'South Park',
  parentIndex: 1,
  index: episode,
);

/// An episode as 1.4.6 queues it (G1): show in grandparentTitle, season
/// label in parentTitle.
MediaItem _newLeaf({required String id, required int episode}) => testMediaItem(
  id: id,
  backend: MediaBackend.plex,
  kind: MediaKind.episode,
  title: 'Episode $id',
  serverId: ServerId('srv'),
  grandparentId: '123',
  grandparentTitle: 'South Park',
  parentId: 'series:123',
  parentTitle: 'Season 1',
  parentIndex: 1,
  index: episode,
);

void main() {
  group('1.4.6 G3: Downloads tree relabels already-queued downloads', () {
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
      // The show title differs before/after the fix ("Unknown Show" on
      // the base, the series name once fixed), so tap whichever is there.
      final showFinder = find.text('South Park').evaluate().isNotEmpty ? find.text('South Park') : find.text('Unknown Show');
      await tester.tap(showFinder);
      await tester.pumpAndSettle();
    }

    testWidgets('old leaves: show row is the series name, season row is "Season 1"', (tester) async {
      await pumpTree(tester, {
        'srv:ep3823': _oldLeaf(id: 'ep3823', episode: 1),
        'srv:ep3824': _oldLeaf(id: 'ep3824', episode: 2),
      }, {
        'srv:ep3823': DownloadStatus.completed,
        'srv:ep3824': DownloadStatus.downloading,
      });

      expect(find.text('South Park'), findsOneWidget, reason: 'the show row must carry the series name, not "Unknown Show"');
      expect(find.text('Unknown Show'), findsNothing);
      expect(find.text('Season 1'), findsOneWidget, reason: 'the season row must be "Season 1", not the series name again');
    });

    testWidgets('new leaves still group the same way (no regression)', (tester) async {
      await pumpTree(tester, {
        'srv:ep3823': _newLeaf(id: 'ep3823', episode: 1),
        'srv:ep3824': _newLeaf(id: 'ep3824', episode: 2),
      }, {
        'srv:ep3823': DownloadStatus.completed,
        'srv:ep3824': DownloadStatus.downloading,
      });

      expect(find.text('South Park'), findsOneWidget);
      expect(find.text('Unknown Show'), findsNothing);
      expect(find.text('Season 1'), findsOneWidget);
    });

    testWidgets('a leaf with neither title still falls back to "Unknown Show"', (tester) async {
      final bare = testMediaItem(
        id: 'ep1',
        backend: MediaBackend.plex,
        kind: MediaKind.episode,
        title: 'Episode ep1',
        serverId: ServerId('srv'),
        grandparentId: '123',
        grandparentTitle: null,
        parentId: 'series:123',
        parentTitle: null,
        parentIndex: 1,
        index: 1,
      );
      await pumpTree(tester, {'srv:ep1': bare}, {'srv:ep1': DownloadStatus.completed});

      expect(find.text('Unknown Show'), findsOneWidget);
      expect(find.text('Season 1'), findsOneWidget);
    });
  });
}
