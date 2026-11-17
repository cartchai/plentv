import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../i18n/strings.g.dart';
import '../../media/iptv_live_tv.dart';
import '../../services/iptv/iptv_epg_sources.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import 'iptv_epg_assign_screen.dart';

/// Channels without guide (§3.2, the "see my assigned EPGs per channel"
/// overview): every channel with no EPG, grouped by reason, each row
/// with an Assign action. The reason groups read in the order a fix is
/// most actionable — no source at all, no match, a failed source, not
/// loaded yet.
class IptvEpgNoGuideScreen extends StatefulWidget {
  final IptvLiveTvSupport support;

  const IptvEpgNoGuideScreen({super.key, required this.support});

  @override
  State<IptvEpgNoGuideScreen> createState() => _IptvEpgNoGuideScreenState();
}

class _IptvEpgNoGuideScreenState extends State<IptvEpgNoGuideScreen> {
  List<IptvChannelWithoutGuide>? _channels;
  bool _loading = true;

  /// 1.2.17: the first load against a failing panel (fresh install, no
  /// disk cache) throws — a plain message + Retry, never an uncaught
  /// throw from initState that leaves the spinner up forever.
  String? _error;

  /// 1.3.26 §69: search + reason filter over the in-memory list —
  /// the list is thousands long, so scrolling to a channel by name
  /// was the whole complaint. The controller (and the query) survives
  /// the post-assign reload — _load() never touches them, so the
  /// search stays put after an Assign.
  final _searchController = TextEditingController();
  String _searchQuery = '';
  IptvEpgNoGuideReason? _selectedReason;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (mounted) setState(() => _searchQuery = _searchController.text);
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// The in-memory list filtered by the search query (normalized
  /// name substring, same normalization as the matcher) and the
  /// selected reason (null = all). Grouping by reason happens after
  /// filtering, in build.
  List<IptvChannelWithoutGuide> get _filteredChannels {
    final channels = _channels ?? const <IptvChannelWithoutGuide>[];
    final query = normalizeEpgChannelName(_searchQuery);
    return channels.where((channel) {
      if (_selectedReason != null && channel.reason != _selectedReason) return false;
      if (query.isEmpty) return true;
      return normalizeEpgChannelName(channel.channelName).contains(query);
    }).toList();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    List<IptvChannelWithoutGuide> channels;
    try {
      channels = await widget.support.channelsWithoutGuide();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _channels = null;
        _error = epgFeedErrorReason(e);
        _loading = false;
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _channels = channels;
      _loading = false;
    });
  }

  String _reasonLabel(IptvEpgNoGuideReason reason) {
    return switch (reason) {
      IptvEpgNoGuideReason.noSource => t.iptv.epgNoGuideReasonNoSource,
      IptvEpgNoGuideReason.noMatch => t.iptv.epgNoGuideReasonNoMatch,
      IptvEpgNoGuideReason.sourceFailed => t.iptv.epgNoGuideReasonSourceFailed,
      IptvEpgNoGuideReason.notLoaded => t.iptv.epgNoGuideReasonNotLoaded,
      IptvEpgNoGuideReason.ambiguous => t.iptv.epgNoGuideReasonAmbiguous,
      IptvEpgNoGuideReason.foreign => t.iptv.epgNoGuideReasonForeign,
      IptvEpgNoGuideReason.matchedButNoPrograms => t.iptv.epgNoGuideReasonMatchedButNoPrograms,
    };
  }

  static const _reasonOrder = [
    IptvEpgNoGuideReason.noSource,
    IptvEpgNoGuideReason.ambiguous,
    IptvEpgNoGuideReason.foreign,
    IptvEpgNoGuideReason.matchedButNoPrograms,
    IptvEpgNoGuideReason.noMatch,
    IptvEpgNoGuideReason.sourceFailed,
    IptvEpgNoGuideReason.notLoaded,
  ];

  Future<void> _assign(IptvChannelWithoutGuide channel) async {
    final assigned = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => IptvEpgAssignScreen(
          support: widget.support,
          channelKey: channel.channelKey,
          channelName: channel.channelName,
        ),
      ),
    );
    if (assigned == true && mounted) {
      setState(() => _loading = true);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final channels = _channels ?? const <IptvChannelWithoutGuide>[];
    final filtered = _filteredChannels;
    final grouped = <IptvEpgNoGuideReason, List<IptvChannelWithoutGuide>>{};
    for (final channel in filtered) {
      grouped.putIfAbsent(channel.reason, () => []).add(channel);
    }
    return FocusedScrollScaffold(
      title: Text(t.iptv.epgNoGuideTitle),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.iptv.epgNoGuideDescription, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 12),
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: t.iptv.epgNoGuideSearchHint,
                    prefixIcon: const AppIcon(Symbols.search_rounded),
                    suffixIcon: _searchQuery.isEmpty
                        ? null
                        : IconButton(
                            icon: const AppIcon(Symbols.close_rounded),
                            onPressed: _searchController.clear,
                          ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: Text(t.iptv.epgNoGuideReasonAll),
                        selected: _selectedReason == null,
                        onSelected: (_) => setState(() => _selectedReason = null),
                      ),
                      for (final reason in _reasonOrder) ...[
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: Text(_reasonLabel(reason)),
                          selected: _selectedReason == reason,
                          onSelected: (_) => setState(() => _selectedReason = reason),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!_loading && _error == null && channels.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    t.iptv.epgNoGuideSearchCount(shown: filtered.length, total: channels.length),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_loading)
          const SliverPadding(
            padding: EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(child: Center(child: CircularProgressIndicator())),
          )
        else if (_error != null)
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.iptv.epgNoGuideLoadFailed(reason: _error!),
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => unawaited(_load()),
                    child: Text(t.common.retry),
                  ),
                ],
              ),
            ),
          )
        else if (channels.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverToBoxAdapter(
              child: Text(t.iptv.epgNoGuideEmpty, style: theme.textTheme.bodyMedium),
            ),
          )
        else
          for (final reason in _reasonOrder)
            if (grouped[reason] != null) ...[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                sliver: SliverToBoxAdapter(
                  child: Text(_reasonLabel(reason), style: theme.textTheme.titleSmall),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverList.builder(
                  itemCount: grouped[reason]!.length,
                  itemBuilder: (context, index) {
                    final channel = grouped[reason]![index];
                    return ListTile(
                      leading: const AppIcon(Symbols.live_tv_rounded),
                      title: Text(channel.channelName),
                      subtitle: channel.candidates.isEmpty
                          ? null
                          : Text(
                              t.iptv.epgNoGuideCandidates(candidates: channel.candidates.take(3).join(', ')),
                            ),
                      trailing: TextButton(
                        onPressed: () => unawaited(_assign(channel)),
                        child: Text(t.iptv.epgAssignTitle),
                      ),
                    );
                  },
                ),
              ),
            ],
        const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
      ],
    );
  }
}
