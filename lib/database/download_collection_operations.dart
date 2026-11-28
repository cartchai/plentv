import 'dart:convert';

import 'package:drift/drift.dart';

import 'app_database.dart';

/// One collection's downloaded members for a profile: the persisted form of
/// [DownloadCollections] with [memberIds] decoded, in collection order.
typedef StoredDownloadCollection = ({String serverId, String collectionId, List<String> memberIds});

/// The last membership refresh of one profile's downloads on one server.
typedef DownloadCollectionSyncState = ({int syncedAt, Set<String> checkedIds});

extension DownloadCollectionDatabaseOperations on AppDatabase {
  /// Every stored collection for [profileId]. A row whose member list does not
  /// decode is skipped; the next refresh of its server rewrites it.
  Future<List<StoredDownloadCollection>> getDownloadCollections(String profileId) async {
    if (profileId.isEmpty) return const [];
    final rows = await (select(downloadCollections)..where((t) => t.profileId.equals(profileId))).get();
    return [
      for (final row in rows)
        if (_decodeIds(row.memberIds) case final memberIds?)
          (serverId: row.serverId, collectionId: row.collectionId, memberIds: memberIds),
    ];
  }

  Future<DownloadCollectionSyncState?> getDownloadCollectionSync({
    required String profileId,
    required String serverId,
  }) async {
    final row = await (select(
      downloadCollectionSyncs,
    )..where((t) => t.profileId.equals(profileId) & t.serverId.equals(serverId))).getSingleOrNull();
    if (row == null) return null;
    final checkedIds = _decodeIds(row.checkedIds);
    if (checkedIds == null) return null;
    return (syncedAt: row.syncedAt, checkedIds: checkedIds.toSet());
  }

  /// Replace [profileId]'s stored membership on [serverId] with
  /// [membersByCollection] (collection id → member ids in collection order)
  /// and record the refresh, atomically.
  Future<void> replaceDownloadCollections({
    required String profileId,
    required String serverId,
    required Map<String, List<String>> membersByCollection,
    required Set<String> checkedIds,
    required int syncedAt,
  }) {
    return transaction(() async {
      await (delete(
        downloadCollections,
      )..where((t) => t.profileId.equals(profileId) & t.serverId.equals(serverId))).go();
      await batch((batch) {
        batch.insertAll(downloadCollections, [
          for (final entry in membersByCollection.entries)
            DownloadCollectionsCompanion.insert(
              profileId: profileId,
              serverId: serverId,
              collectionId: entry.key,
              memberIds: jsonEncode(entry.value),
            ),
        ]);
      });
      await into(downloadCollectionSyncs).insertOnConflictUpdate(
        DownloadCollectionSyncsCompanion.insert(
          profileId: profileId,
          serverId: serverId,
          syncedAt: syncedAt,
          checkedIds: jsonEncode(checkedIds.toList()..sort()),
        ),
      );
    });
  }

  /// Move a removed profile's collection membership to [toProfileId]
  /// (1.6.35 anchor migration). When the target already holds the same
  /// collection, its row wins and the source row is dropped: both rows
  /// describe the same collection, and the target's member list is the
  /// live one. The per-server sync rows move the same way.
  Future<void> transferDownloadCollectionsForProfile(String fromProfileId, String toProfileId) async {
    if (fromProfileId.isEmpty || toProfileId.isEmpty || fromProfileId == toProfileId) return;
    await transaction(() async {
      final sourceCollections =
          await (select(downloadCollections)..where((t) => t.profileId.equals(fromProfileId))).get();
      if (sourceCollections.isNotEmpty) {
        final targetCollections =
            await (select(downloadCollections)..where((t) => t.profileId.equals(toProfileId))).get();
        final targetKeys = {for (final row in targetCollections) (row.serverId, row.collectionId)};
        for (final row in sourceCollections) {
          if (!targetKeys.contains((row.serverId, row.collectionId))) continue;
          await (delete(downloadCollections)
                ..where(
                  (t) =>
                      t.profileId.equals(fromProfileId) &
                      t.serverId.equals(row.serverId) &
                      t.collectionId.equals(row.collectionId),
                ))
              .go();
        }
        await (update(downloadCollections)..where((t) => t.profileId.equals(fromProfileId))).write(
          DownloadCollectionsCompanion(profileId: Value(toProfileId)),
        );
      }
      final sourceSyncs =
          await (select(downloadCollectionSyncs)..where((t) => t.profileId.equals(fromProfileId))).get();
      if (sourceSyncs.isNotEmpty) {
        final targetSyncs =
            await (select(downloadCollectionSyncs)..where((t) => t.profileId.equals(toProfileId))).get();
        final targetServers = {for (final row in targetSyncs) row.serverId};
        for (final row in sourceSyncs) {
          if (!targetServers.contains(row.serverId)) continue;
          await (delete(downloadCollectionSyncs)
                ..where((t) => t.profileId.equals(fromProfileId) & t.serverId.equals(row.serverId)))
              .go();
        }
        await (update(downloadCollectionSyncs)..where((t) => t.profileId.equals(fromProfileId))).write(
          DownloadCollectionSyncsCompanion(profileId: Value(toProfileId)),
        );
      }
    });
  }

  /// Drop a removed profile's collection membership (profile teardown).
  Future<void> deleteDownloadCollectionsForProfile(String profileId) {
    return transaction(() async {
      await (delete(downloadCollections)..where((t) => t.profileId.equals(profileId))).go();
      await (delete(downloadCollectionSyncs)..where((t) => t.profileId.equals(profileId))).go();
    });
  }

  /// Drop every profile's collection membership (full logout).
  Future<void> clearAllDownloadCollections() {
    return transaction(() async {
      await delete(downloadCollections).go();
      await delete(downloadCollectionSyncs).go();
    });
  }
}

List<String>? _decodeIds(String json) {
  try {
    final decoded = jsonDecode(json);
    if (decoded is! List) return null;
    return [for (final id in decoded) id.toString()];
  } on FormatException {
    return null;
  }
}
