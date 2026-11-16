import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../services/storage_health.dart';
import '../../widgets/focusable_list_tile.dart';

/// "Storage almost full" row (1.2.19, L-20): a plain-words warning in
/// Settings → Advanced, shown ONLY while free space is below 500 MB —
/// the guide and artwork are limited then (no feed download, short-EPG
/// only; the image disk cache evicted to 500 objects; no full-file
/// catalog rewrite). Healthy storage shows nothing at all: the row is
/// a warning, not a status.
///
/// Loads only the one cached free-space reading (refreshed at
/// startup) — it does not depend on the IPTV or Plex clients, so it is
/// reachable even when the app is otherwise unstable, like the
/// LastCrashRow next to it.
class StorageHealthRow extends StatefulWidget {
  const StorageHealthRow({super.key, this.focusNode});

  final FocusNode? focusNode;

  @override
  State<StorageHealthRow> createState() => _StorageHealthRowState();
}

class _StorageHealthRowState extends State<StorageHealthRow> {
  bool _loading = true;
  int? _freeBytes;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final free = await StorageHealth.freeBytes();
    if (!mounted) return;
    setState(() {
      _freeBytes = free;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final free = _freeBytes;
    if (free == null || free >= StorageHealth.lowFreeSpaceThresholdBytes) {
      return const SizedBox.shrink();
    }
    return FocusableListTile(
      focusNode: widget.focusNode,
      leading: const Icon(Symbols.storage_rounded),
      title: Text(t.settings.storageAlmostFull),
      subtitle: Text(
        t.settings.storageAlmostFullDetail(free: StorageHealth.formatMegabytes(free)),
      ),
    );
  }
}
