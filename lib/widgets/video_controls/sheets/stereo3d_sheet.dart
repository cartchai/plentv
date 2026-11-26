import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../../focus/focusable_slider.dart';
import '../../../i18n/strings.g.dart';
import '../../../media/media_source_info.dart';
import '../../../mpv/mpv.dart';
import '../../../services/file_picker_service.dart';
import '../../../services/settings_service.dart';
import '../../../services/sleep_timer_service.dart';
import '../../../utils/formatters.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/overlay_sheet.dart';
import '../models/track_controls_state.dart';
import '../widgets/sleep_timer_content.dart';
import 'base_video_control_sheet.dart';
import 'chapter_sheet.dart';
import 'package:plezy/quest/stereo3d.dart';
import 'package:plezy/quest/vr_player_channel.dart';

/// The 3D settings sheet (§1.6 of the Quest 3D spec).
///
/// Opened from the 3D button in the player controls. Shows the detected
/// 3D layout, lets the user pick the layout/packing/screen/passthrough,
/// and launches the native VR player on Quest ("Watch in VR").
///
/// Quest-only rows (VR launch, passthrough, refresh rate, foveated,
/// spatial audio, hand tracking, cooperative overlay, auto-dim, subtitle
/// depth, screen lock, external subtitles) are disabled with a
/// "needs a headset" note on phone/TV. The flat rows (layout, packing,
/// swap eyes, screen size/distance/curvature, depth, remember-for-title,
/// speed, chapters, sleep timer) work everywhere — on phone/TV the panel
/// always shows the packed frame as-is (both eyes, §1.9 FLAT), so these
/// rows only record the choice for a later Quest viewing.
///
/// The per-title record (layout/packing/swap/screen preset/subtitle depth)
/// is stored by [Stereo3dTitleStore] under `ratingKey|partId` and wins over
/// filename detection. The global VR prefs (brightness, foveated, refresh
/// rate, ...) live in [SettingsService].
class Stereo3dSheet extends StatefulWidget {
  final Player player;
  final TrackControlsState trackControlsState;
  final List<MediaChapter> chapters;
  final bool chaptersLoaded;
  final Stereo3dDetection detection;

  /// True on a Quest headset (from [QuestPlatform]). VR-only rows and the
  /// "Watch in VR" button are only enabled when this is true.
  final bool isQuest;

  final SettingsService settings;
  final Stereo3dTitleStore titleStore;
  final VrPlayerChannel vrChannel;
  final Future<void> Function(Duration position)? onSeekRequested;
  final Function(Duration position)? onSeekCompleted;

  const Stereo3dSheet({
    super.key,
    required this.player,
    required this.trackControlsState,
    required this.chapters,
    required this.chaptersLoaded,
    required this.detection,
    required this.isQuest,
    required this.settings,
    required this.titleStore,
    required this.vrChannel,
    this.onSeekRequested,
    this.onSeekCompleted,
  });

  @override
  State<Stereo3dSheet> createState() => _Stereo3dSheetState();
}

class _Stereo3dSheetState extends State<Stereo3dSheet> {
  late Stereo3dLayout _layout;
  late Stereo3dPacking _packing;
  late bool _swapEyes;
  late double _screenSize;
  late double _screenDistance;
  late double _screenCurvature;
  late double _depthSeparation;
  late double _passthroughBrightness;
  late bool _rememberForTitle;
  late String _subtitleDepth;
  late String _screenLock;
  late String _screenPreset;
  late bool _autoDim;
  late bool _foveated;
  late bool _dynamicResolution;
  late int _refreshRate;
  late bool _spatialAudio;
  late bool _handTracking;
  late bool _cooperativeOverlay;
  late List<String> _externalSubtitlePaths;

  bool _isLaunchingVr = false;
  bool _showSleepTimer = false;

  String get _ratingKey => widget.trackControlsState.ratingKey;
  String get _partId => widget.trackControlsState.sourcePartId?.toString() ?? '';
  bool get _hasTitleIdentity => _ratingKey.isNotEmpty;

  @override
  void initState() {
    super.initState();
    final settings = widget.settings;
    final record = _hasTitleIdentity
        ? widget.titleStore.load(_ratingKey, _partId)
        : null;
    // Manual per-title choice wins; otherwise the detected layout.
    _layout = record?.layout ?? widget.detection.layout;
    _packing = record?.packing ?? widget.detection.packing;
    _swapEyes = record?.swapEyes ?? false;
    final preset = record?.screenPreset;
    // B7: a 'custom' preset has no fixed numbers — its values live in
    // the global prefs (where the sliders wrote them). Only the named
    // presets (tv/cinema) read from the preset table.
    _screenSize = preset != null && preset != 'custom'
        ? _presetSize(preset)
        : settings.read(SettingsService.questScreenSize);
    _screenDistance = preset != null && preset != 'custom'
        ? _presetDistance(preset)
        : settings.read(SettingsService.questScreenDistance);
    _screenCurvature = preset != null && preset != 'custom'
        ? _presetCurvature(preset)
        : settings.read(SettingsService.questScreenCurvature);
    _depthSeparation = settings.read(SettingsService.questDepthSeparation);
    _passthroughBrightness =
        settings.read(SettingsService.questPassthroughBrightness);
    _rememberForTitle = record != null;
    // T3: subtitle depth has one owner per scope — the per-title record
    // is the override, the global pref is only the default for titles
    // with no record. The segment below writes the record only.
    _subtitleDepth = record?.subtitleDepth ??
        settings.read(SettingsService.questSubtitleDepth);
    // B17: screen lock is a persisted global pref, not session-only.
    final screenLock = settings.read(SettingsService.questScreenLock);
    _screenLock = screenLock == 'head' ? 'head' : 'world';
    _screenPreset = record?.screenPreset ?? _presetFor(_screenSize, _screenDistance, _screenCurvature);
    _autoDim = settings.read(SettingsService.questAutoDimPassthrough);
    _foveated = settings.read(SettingsService.questFoveatedRendering);
    _dynamicResolution = settings.read(SettingsService.questDynamicResolution);
    _refreshRate = settings.read(SettingsService.questRefreshRate);
    _spatialAudio = settings.read(SettingsService.questSpatialAudio);
    _handTracking = settings.read(SettingsService.questHandTracking);
    _cooperativeOverlay = settings.read(SettingsService.questCooperativeOverlay);
    _externalSubtitlePaths = const [];
  }

  /// One source of truth for the screen presets (U4): preset →
  /// (size, distance, curvature). Every reader below consults this map,
  /// so a number cannot drift between the preset functions and the
  /// preset matcher. 'custom' is not in the map — it means "the values
  /// in the global prefs", read directly in initState.
  static const _screenPresetValues =
      <String, ({double size, double distance, double curvature})>{
    'tv': (size: 0.8, distance: 2.5, curvature: 0.0),
    'cinema': (size: 1.6, distance: 5.0, curvature: 0.15),
  };

  double _presetSize(String preset) => _screenPresetValues[preset]?.size ?? 1.0;
  double _presetDistance(String preset) =>
      _screenPresetValues[preset]?.distance ?? 3.0;
  double _presetCurvature(String preset) =>
      _screenPresetValues[preset]?.curvature ?? 0.0;

  String _presetFor(double size, double distance, double curvature) {
    for (final entry in _screenPresetValues.entries) {
      final values = entry.value;
      if ((size - values.size).abs() < 0.01 &&
          (distance - values.distance).abs() < 0.01 &&
          (curvature - values.curvature).abs() < 0.01) {
        return entry.key;
      }
    }
    return 'custom';
  }

  /// The playback speeds the sheet offers (B27). A panel rate set
  /// elsewhere (e.g. 1.1x) maps to the nearest offered segment so the
  /// SegmentedButton's selected set always matches a segment.
  /// Keep in sync with the speed segments in build().
  static const _offeredPlaybackSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  double _nearestPlaybackSpeed(double rate) {
    var best = _offeredPlaybackSpeeds.first;
    for (final value in _offeredPlaybackSpeeds) {
      if ((value - rate).abs() < (best - rate).abs()) best = value;
    }
    return best;
  }

  Stereo3dLayout _effectiveLayout() {
    if (_layout != Stereo3dLayout.auto) return _layout;
    return widget.detection.layout;
  }

  void _saveRecord() {
    if (!_hasTitleIdentity) return;
    if (_rememberForTitle) {
      widget.titleStore.save(
        _ratingKey,
        _partId,
        Stereo3dTitleRecord(
          layout: _layout,
          packing: _packing,
          swapEyes: _swapEyes,
          screenPreset: _screenPreset,
          subtitleDepth: _subtitleDepth,
        ),
      );
    } else {
      widget.titleStore.clear(_ratingKey, _partId);
    }
  }

  double _sleepTimerRemainingSeconds() {
    final timer = SleepTimerService();
    if (!timer.isActive) return 0.0;
    final remaining = timer.remainingTime;
    if (remaining == null) return 0.0;
    return remaining.inMilliseconds / 1000.0;
  }

  Future<void> _watchInVr() async {
    if (_isLaunchingVr) return;
    setState(() => _isLaunchingVr = true);
    // The spinner stays up until the activity result returns (Q4): this
    // flag is only cleared in the finally below, after playInVr answers.
    var vrStarted = false;
    try {
      // The panel player pauses first: the VR player opens the same URL,
      // and the panel must not keep playing (audio + a second stream) while
      // the VR session runs. The position is restored on return.
      await widget.player.pause();
      final url = await widget.player.getProperty('path');
      if (url == null || url.isEmpty) {
        if (mounted) showErrorSnackBar(context, t.stereo3d.vrUnavailable);
        return;
      }
      final request = VrPlayerRequest(
        videoUrl: url,
        layout: _effectiveLayout(),
        packing: _packing,
        swapEyes: _swapEyes,
        screenSize: _screenSize,
        screenDistance: _screenDistance,
        screenCurvature: _screenCurvature,
        depthSeparation: _depthSeparation,
        passthroughBrightness: _passthroughBrightness,
        autoDimPassthrough: _autoDim,
        foveatedRendering: _foveated,
        dynamicResolution: _dynamicResolution,
        refreshRate: _refreshRate,
        spatialAudio: _spatialAudio,
        handTracking: _handTracking,
        cooperativeOverlay: _cooperativeOverlay,
        subtitleDepth: _subtitleDepth,
        screenLock: _screenLock,
        playbackSpeed: widget.player.state.rate,
        // S13: the panel's sleep timer carries into VR — the native
        // player pauses when it fires.
        sleepTimerSeconds: _sleepTimerRemainingSeconds(),
        startPositionSeconds:
            widget.player.state.position.inMilliseconds / 1000.0,
        externalSubtitlePaths: _externalSubtitlePaths,
        title: widget.trackControlsState.mediaTitle,
      );
      final result = await widget.vrChannel.playInVr(request);
      if (!mounted) return;
      if (result == null) {
        showErrorSnackBar(context, t.stereo3d.vrUnavailable);
        return;
      }
      if (!result.started) {
        // P0.4 contract: the native side reports started=false when VR
        // init failed before any frame. The returned position is
        // meaningless (0) — do NOT seek the panel to 0, do NOT pop the
        // sheet. The panel is resumed in the finally below.
        showErrorSnackBar(context, t.stereo3d.vrUnavailable);
        return;
      }
      vrStarted = true;
      // Back in the panel: restore the watch position the VR session left.
      final position =
          Duration(milliseconds: (result.positionSeconds * 1000).round());
      final seek = widget.onSeekRequested;
      if (seek != null) {
        await seek(position);
      } else {
        await widget.player.seek(position);
      }
      widget.onSeekCompleted?.call(position);
      if (mounted) Navigator.of(context).pop();
    } on PlatformException catch (e) {
      if (mounted) {
        showErrorSnackBar(context, e.message ?? t.stereo3d.vrUnavailable);
      }
    } finally {
      if (mounted) setState(() => _isLaunchingVr = false);
      if (!vrStarted) {
        // P0.12: a failed VR launch leaves playback exactly as it was —
        // the panel was paused for a session that never started, so
        // resume it. Best-effort: a resume failure must not mask the
        // VR error already shown.
        try {
          await widget.player.play();
        } catch (_) {}
      }
    }
  }

  Future<void> _recenter() async {
    final done = await widget.vrChannel.recenter();
    if (!mounted) return;
    if (done) {
      showSuccessSnackBar(context, t.stereo3d.recentered);
    } else {
      showErrorSnackBar(context, t.stereo3d.notInVr);
    }
  }

  Future<void> _pickExternalSubtitles() async {
    // One file per pick through the app's guarded picker; tap again to add
    // another. The service swallows the 'already_active' case.
    final picked = await FilePickerService.instance.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['srt', 'ass'],
    );
    if (picked == null || !mounted) return;
    final paths = picked.files
        .map((f) => f.path)
        .whereType<String>()
        .where((p) => p.isNotEmpty)
        .toList();
    if (paths.isEmpty) return;
    setState(() {
      _externalSubtitlePaths = [..._externalSubtitlePaths, ...paths];
    });
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 18, bottom: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _switchRow({
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    bool enabled = true,
  }) {
    return FocusableListTile(
      title: Text(title),
      subtitle: subtitle != null ? Text(subtitle) : null,
      enabled: enabled,
      trailing: Switch(
        value: value,
        onChanged: enabled ? onChanged : null,
        activeThumbColor: Colors.amber,
      ),
      onTap: enabled ? () => onChanged(!value) : null,
    );
  }

  Widget _sliderRow({
    required String title,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: const TextStyle(fontSize: 15)),
              Text(valueText,
                  style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).textTheme.bodySmall?.color)),
            ],
          ),
          FocusableSlider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: enabled ? onChanged : null,
            onChangeEnd: enabled ? onChangeEnd : null,
          ),
        ],
      ),
    );
  }

  Widget _vrOnlyNote() {
    if (widget.isQuest) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Icon(Symbols.headset_rounded, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.stereo3d.needsHeadset,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_showSleepTimer) {
      return BaseVideoControlSheet(
        title: t.stereo3d.sleepTimer,
        icon: Symbols.bedtime_rounded,
        onBack: () => setState(() => _showSleepTimer = false),
        child: SleepTimerContent(
          sleepTimer: SleepTimerService(),
          onCancel: () => setState(() => _showSleepTimer = false),
        ),
      );
    }

    final detection = widget.detection;
    final detectionText = detection.is3d
        ? '${detection.layout.name.toUpperCase()} · ${detection.packing.name} · ${detection.source.name}'
        : t.stereo3d.layout2d;
    final rate = widget.player.state.rate;
    final sleepTimer = SleepTimerService();
    final isQuest = widget.isQuest;

    return BaseVideoControlSheet(
      title: t.stereo3d.title,
      icon: Symbols.view_in_ar_rounded,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Detected layout.
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Symbols.view_in_ar_rounded, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      detectionText,
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                ],
              ),
            ),
            // Watch in VR (Quest) / needs-headset note (phone/TV).
            if (isQuest)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: FilledButton.icon(
                  onPressed: _isLaunchingVr ? null : _watchInVr,
                  icon: _isLaunchingVr
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Symbols.view_in_ar_rounded),
                  label: Text(t.stereo3d.watchInVr),
                ),
              )
            else
              _vrOnlyNote(),
            // Watch flat instead (records 2D for this title).
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton(
                onPressed: () {
                  setState(() {
                    _layout = Stereo3dLayout.twoD;
                    _rememberForTitle = true;
                  });
                  _saveRecord();
                  Navigator.of(context).pop();
                },
                child: Text(t.stereo3d.watchIn2d),
              ),
            ),
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                t.stereo3d.watchIn2dDescription,
                style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).textTheme.bodySmall?.color),
              ),
            ),

            _sectionLabel(t.stereo3d.layout),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<Stereo3dLayout>(
                segments: [
                  ButtonSegment(
                      value: Stereo3dLayout.twoD,
                      label: Text(t.stereo3d.layout2d)),
                  ButtonSegment(
                      value: Stereo3dLayout.sbs,
                      label: Text(t.stereo3d.layoutSbs)),
                  ButtonSegment(
                      value: Stereo3dLayout.ou,
                      label: Text(t.stereo3d.layoutOu)),
                  ButtonSegment(
                      value: Stereo3dLayout.vr180,
                      label: Text(t.stereo3d.layoutVr180)),
                  ButtonSegment(
                      value: Stereo3dLayout.vr360,
                      label: Text(t.stereo3d.layoutVr360)),
                  ButtonSegment(
                      value: Stereo3dLayout.auto,
                      label: Text(t.stereo3d.layoutAuto)),
                ],
                selected: {_layout},
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  setState(() => _layout = selection.single);
                  _saveRecord();
                },
              ),
            ),
            _sectionLabel(t.stereo3d.packing),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<Stereo3dPacking>(
                segments: [
                  ButtonSegment(
                    value: Stereo3dPacking.half,
                    label: Text(t.stereo3d.packingHalf),
                    enabled: _layout != Stereo3dLayout.twoD,
                  ),
                  ButtonSegment(
                    value: Stereo3dPacking.full,
                    label: Text(t.stereo3d.packingFull),
                    enabled: _layout != Stereo3dLayout.twoD,
                  ),
                ],
                selected: {_packing},
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  setState(() => _packing = selection.single);
                  _saveRecord();
                },
              ),
            ),
            _switchRow(
              title: t.stereo3d.swapEyes,
              subtitle: t.stereo3d.swapEyesDescription,
              value: _swapEyes,
              onChanged: (v) {
                setState(() => _swapEyes = v);
                _saveRecord();
              },
            ),
            _switchRow(
              title: t.stereo3d.rememberForTitle,
              value: _rememberForTitle,
              enabled: _hasTitleIdentity,
              onChanged: (v) {
                setState(() => _rememberForTitle = v);
                _saveRecord();
              },
            ),
            // Q6: undo a manual choice entirely — back to auto-detect.
            // Only meaningful while a record exists (remember on).
            FocusableListTile(
              title: Text(t.stereo3d.resetToAutoDetect),
              leading: const Icon(Symbols.restart_alt_rounded),
              enabled: _hasTitleIdentity && _rememberForTitle,
              onTap: () {
                widget.titleStore.clear(_ratingKey, _partId);
                setState(() {
                  _rememberForTitle = false;
                  _layout = widget.detection.layout;
                  _packing = widget.detection.packing;
                  _screenSize =
                      widget.settings.read(SettingsService.questScreenSize);
                  _screenDistance = widget.settings
                      .read(SettingsService.questScreenDistance);
                  _screenCurvature = widget.settings
                      .read(SettingsService.questScreenCurvature);
                  _screenPreset = _presetFor(
                      _screenSize, _screenDistance, _screenCurvature);
                  _subtitleDepth = widget.settings
                      .read(SettingsService.questSubtitleDepth);
                });
              },
            ),

            _sectionLabel(t.stereo3d.screenPreset),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                      value: 'tv', label: Text(t.stereo3d.screenPresetTv)),
                  ButtonSegment(
                      value: 'cinema',
                      label: Text(t.stereo3d.screenPresetCinema)),
                  ButtonSegment(
                      value: 'custom',
                      label: Text(t.stereo3d.screenPresetCustom)),
                ],
                selected: {_screenPreset},
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  final preset = selection.single;
                  setState(() {
                    _screenPreset = preset;
                    _screenSize = _presetSize(preset);
                    _screenDistance = _presetDistance(preset);
                    _screenCurvature = _presetCurvature(preset);
                  });
                  _saveRecord();
                  unawaited(() async {
                    final s = widget.settings;
                    await s.write(SettingsService.questScreenSize, _screenSize);
                    await s.write(
                        SettingsService.questScreenDistance, _screenDistance);
                    await s.write(
                        SettingsService.questScreenCurvature, _screenCurvature);
                  }());
                },
              ),
            ),
            _sliderRow(
              title: t.stereo3d.screenSize,
              valueText: '${(_screenSize * 100).round()}%',
              value: _screenSize,
              min: 0.5,
              max: 2.0,
              divisions: 30,
              onChanged: (v) => setState(() {
                _screenSize = v;
                _screenPreset = 'custom';
              }),
              onChangeEnd: (v) {
                _screenPreset = 'custom';
                _saveRecord();
                unawaited(widget.settings
                    .write(SettingsService.questScreenSize, v));
              },
            ),
            _sliderRow(
              title: t.stereo3d.screenDistance,
              valueText: '${_screenDistance.toStringAsFixed(1)} m',
              value: _screenDistance,
              min: 1.0,
              max: 8.0,
              divisions: 70,
              onChanged: (v) => setState(() {
                _screenDistance = v;
                _screenPreset = 'custom';
              }),
              onChangeEnd: (v) {
                _screenPreset = 'custom';
                _saveRecord();
                unawaited(widget.settings
                    .write(SettingsService.questScreenDistance, v));
              },
            ),
            _sliderRow(
              title: t.stereo3d.screenCurvature,
              valueText: '${(_screenCurvature * 100).round()}%',
              value: _screenCurvature,
              min: 0.0,
              max: 0.5,
              divisions: 25,
              onChanged: (v) => setState(() {
                _screenCurvature = v;
                _screenPreset = 'custom';
              }),
              onChangeEnd: (v) {
                _screenPreset = 'custom';
                _saveRecord();
                unawaited(widget.settings
                    .write(SettingsService.questScreenCurvature, v));
              },
            ),
            _sliderRow(
              title: t.stereo3d.depth,
              valueText: '${(_depthSeparation * 100).round()}%',
              value: _depthSeparation,
              min: 0.0,
              max: 1.0,
              divisions: 20,
              onChanged: (v) => setState(() => _depthSeparation = v),
              onChangeEnd: (v) {
                _saveRecord();
                unawaited(widget.settings
                    .write(SettingsService.questDepthSeparation, v));
              },
            ),
            FocusableListTile(
              title: Text(t.stereo3d.recenter),
              leading: const Icon(Symbols.center_focus_strong_rounded),
              enabled: isQuest,
              onTap: isQuest ? _recenter : null,
            ),

            _sectionLabel(t.stereo3d.passthroughBrightness),
            _sliderRow(
              title: t.stereo3d.passthroughBrightness,
              valueText: _passthroughBrightness.round().toString(),
              value: _passthroughBrightness,
              min: -100,
              max: 100,
              divisions: 40,
              enabled: isQuest,
              onChanged: (v) =>
                  setState(() => _passthroughBrightness = v),
              onChangeEnd: (v) => unawaited(widget.settings
                  .write(SettingsService.questPassthroughBrightness, v)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                t.stereo3d.passthroughBrightnessDescription,
                style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).textTheme.bodySmall?.color),
              ),
            ),

            _sectionLabel(t.stereo3d.subtitleDepth),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                      value: 'below',
                      label: Text(t.stereo3d.subtitleDepthBelow),
                      enabled: isQuest),
                  ButtonSegment(
                      value: 'onScreen',
                      label: Text(t.stereo3d.subtitleDepthOnScreen),
                      enabled: isQuest),
                  ButtonSegment(
                      value: 'follow',
                      label: Text(t.stereo3d.subtitleDepthFollow),
                      enabled: isQuest),
                ],
                selected: {_subtitleDepth},
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  // T3: the record is the per-title override; the global
                  // pref stays the default for titles never touched here.
                  setState(() => _subtitleDepth = selection.single);
                  _saveRecord();
                },
              ),
            ),
            _sectionLabel(t.stereo3d.screenLock),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                      value: 'world',
                      label: Text(t.stereo3d.screenLockWorld),
                      enabled: isQuest),
                  ButtonSegment(
                      value: 'head',
                      label: Text(t.stereo3d.screenLockHead),
                      enabled: isQuest),
                ],
                selected: {_screenLock},
                showSelectedIcon: false,
                onSelectionChanged: (selection) {
                  setState(() => _screenLock = selection.single);
                  unawaited(widget.settings.write(
                      SettingsService.questScreenLock, _screenLock));
                },
              ),
            ),
            _sectionLabel(t.stereo3d.refreshRate),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 72, label: Text('72 Hz')),
                  ButtonSegment(value: 90, label: Text('90 Hz')),
                  ButtonSegment(value: 120, label: Text('120 Hz')),
                ],
                selected: {_refreshRate},
                showSelectedIcon: false,
                onSelectionChanged: isQuest
                    ? (selection) {
                        setState(() => _refreshRate = selection.single);
                        unawaited(widget.settings.write(
                            SettingsService.questRefreshRate, _refreshRate));
                      }
                    : null,
              ),
            ),

            _switchRow(
              title: t.stereo3d.autoDim,
              subtitle: t.stereo3d.autoDimDescription,
              value: _autoDim,
              enabled: isQuest,
              onChanged: (v) {
                setState(() => _autoDim = v);
                unawaited(widget.settings.write(
                    SettingsService.questAutoDimPassthrough, v));
              },
            ),
            _switchRow(
              title: t.stereo3d.foveatedRendering,
              subtitle: t.stereo3d.foveatedRenderingDescription,
              value: _foveated,
              enabled: isQuest,
              onChanged: (v) {
                setState(() => _foveated = v);
                unawaited(widget.settings.write(
                    SettingsService.questFoveatedRendering, v));
              },
            ),
            _switchRow(
              title: t.stereo3d.dynamicResolution,
              subtitle: t.stereo3d.dynamicResolutionDescription,
              value: _dynamicResolution,
              enabled: isQuest,
              onChanged: (v) {
                setState(() => _dynamicResolution = v);
                unawaited(widget.settings.write(
                    SettingsService.questDynamicResolution, v));
              },
            ),
            _switchRow(
              title: t.stereo3d.spatialAudio,
              subtitle: t.stereo3d.spatialAudioDescription,
              value: _spatialAudio,
              enabled: isQuest,
              onChanged: (v) {
                setState(() => _spatialAudio = v);
                unawaited(widget.settings.write(
                    SettingsService.questSpatialAudio, v));
              },
            ),
            _switchRow(
              title: t.stereo3d.handTracking,
              subtitle: t.stereo3d.handTrackingDescription,
              value: _handTracking,
              enabled: isQuest,
              onChanged: (v) {
                setState(() => _handTracking = v);
                unawaited(widget.settings.write(
                    SettingsService.questHandTracking, v));
              },
            ),
            _switchRow(
              title: t.stereo3d.cooperativeOverlay,
              subtitle: t.stereo3d.cooperativeOverlayDescription,
              value: _cooperativeOverlay,
              enabled: isQuest,
              onChanged: (v) {
                setState(() => _cooperativeOverlay = v);
                unawaited(widget.settings.write(
                    SettingsService.questCooperativeOverlay, v));
              },
            ),

            _sectionLabel(t.stereo3d.externalSubtitles),
            FocusableListTile(
              title: Text(t.stereo3d.externalSubtitles),
              subtitle: Text(t.stereo3d.externalSubtitlesDescription),
              leading: const Icon(Symbols.subtitles_rounded),
              enabled: isQuest,
              onTap: isQuest ? _pickExternalSubtitles : null,
            ),
            for (final path in _externalSubtitlePaths)
              ListTile(
                dense: true,
                title: Text(path.split('/').last,
                    overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  icon: const Icon(Symbols.close_rounded),
                  onPressed: () => setState(
                      () => _externalSubtitlePaths.remove(path)),
                ),
              ),

            _sectionLabel(t.stereo3d.playbackSpeed),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<double>(
                segments: const [
                  ButtonSegment(value: 0.5, label: Text('0.5×')),
                  ButtonSegment(value: 0.75, label: Text('0.75×')),
                  ButtonSegment(value: 1.0, label: Text('1×')),
                  ButtonSegment(value: 1.25, label: Text('1.25×')),
                  ButtonSegment(value: 1.5, label: Text('1.5×')),
                  ButtonSegment(value: 2.0, label: Text('2×')),
                ],
                selected: {_nearestPlaybackSpeed(rate)},
                showSelectedIcon: false,
                onSelectionChanged: (selection) async {
                  final newRate = selection.single;
                  final onRate = widget.trackControlsState.onRateRequested;
                  if (onRate != null) {
                    await onRate(newRate);
                  } else {
                    await widget.player.setRate(newRate);
                  }
                  if (mounted) setState(() {});
                },
              ),
            ),
            FocusableListTile(
              title: Text(t.stereo3d.chapters),
              subtitle: widget.chaptersLoaded
                  ? Text('${widget.chapters.length}')
                  : null,
              leading: const Icon(Symbols.list_rounded),
              enabled: widget.chaptersLoaded && widget.chapters.isNotEmpty,
              onTap: widget.chaptersLoaded && widget.chapters.isNotEmpty
                  ? () {
                      widget.trackControlsState.onCancelAutoHide?.call();
                      OverlaySheetController.of(context).show(
                        builder: (_) => ChapterSheet(
                          player: widget.player,
                          chapters: widget.chapters,
                          chaptersLoaded: widget.chaptersLoaded,
                          canControl: widget.trackControlsState.canControl,
                          serverId: widget.trackControlsState.serverId,
                          onSeekRequested: widget.onSeekRequested,
                          onSeekCompleted: widget.onSeekCompleted,
                        ),
                      );
                    }
                  : null,
            ),
            ListenableBuilder(
              listenable: sleepTimer,
              builder: (context, _) {
                final remaining = sleepTimer.remainingTime;
                final label = sleepTimer.isActive && remaining != null
                    ? t.videoSettings.sleepTimerActive(
                        duration: formatDurationWithSeconds(remaining))
                    : t.common.off;
                return FocusableListTile(
                  title: Text(t.stereo3d.sleepTimer),
                  subtitle: Text(label),
                  leading: const Icon(Symbols.bedtime_rounded),
                  onTap: () => setState(() => _showSleepTimer = true),
                );
              },
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
