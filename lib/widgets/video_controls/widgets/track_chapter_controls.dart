import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';

import '../../../focus/dpad_navigator.dart';
import '../../../mpv/mpv.dart';
import '../../../media/media_part.dart';
import '../../../media/media_source_info.dart';
import '../../../quest/quest_platform.dart';
import '../../../quest/stereo3d.dart';
import '../../../quest/stereo3d_title_store.dart';
import '../../../quest/vr_player_channel.dart';
import '../../../services/settings_service.dart';
import '../../../services/sleep_timer_service.dart';
import '../../../utils/platform_detector.dart';
import '../../../utils/quality_preset_labels.dart';
import '../../../i18n/strings.g.dart';
import '../../../widgets/overlay_sheet.dart';
import '../models/track_controls_state.dart';
import '../sheets/chapter_sheet.dart';
import '../sheets/queue_sheet.dart';
import '../sheets/stereo3d_sheet.dart';
import '../sheets/track_sheet.dart';
import '../sheets/video_settings_sheet.dart';
import '../../../utils/track_label_builder.dart';
import '../video_control_button.dart';

/// Row of track and chapter control buttons for the video player
class TrackChapterControls extends StatefulWidget {
  final Player player;
  final List<MediaChapter> chapters;
  final bool chaptersLoaded;
  final TrackControlsState trackControlsState;
  final Future<void> Function(Duration position)? onSeekRequested;
  final Function(Duration position)? onSeekCompleted;

  /// List of FocusNodes for the buttons (passed from parent for navigation)
  final List<FocusNode>? focusNodes;

  /// Called when focus changes on any button
  final ValueChanged<bool>? onFocusChange;

  final VoidCallback? onNavigateLeft;

  /// Called to navigate up from any button (e.g., to focus timeline on TV)
  final VoidCallback? onNavigateUp;

  /// Called to navigate down from any button (e.g., to show content strip on TV)
  final VoidCallback? onNavigateDown;

  /// Whether to hide the chapters and queue buttons (mobile uses content strip instead)
  final bool hideChaptersAndQueue;

  const TrackChapterControls({
    super.key,
    required this.player,
    required this.chapters,
    required this.chaptersLoaded,
    required this.trackControlsState,
    this.onSeekRequested,
    this.onSeekCompleted,
    this.focusNodes,
    this.onFocusChange,
    this.onNavigateLeft,
    this.onNavigateUp,
    this.onNavigateDown,
    this.hideChaptersAndQueue = false,
  });

  @override
  State<TrackChapterControls> createState() => _TrackChapterControlsState();
}

class _TrackChapterControlsState extends State<TrackChapterControls> {
  /// The container's declared stereo mode (`video-stereo-mode`), read
  /// once the file is open in mpv (D7). Null until the read lands (or
  /// when the player has no such property).
  Stereo3dDetection? _containerDetection;

  /// Generation of the in-flight container read: a title change while
  /// a read is still out must not let the old title's answer land on
  /// the new title (K(i)).
  int _containerLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _loadContainerStereoMode();
  }

  @override
  void didUpdateWidget(TrackChapterControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      _containerDetection = null;
      _loadContainerStereoMode();
    } else if (_titleIdentity(oldWidget.trackControlsState) !=
        _titleIdentity(widget.trackControlsState)) {
      // Same player session, new title (next episode, or a version
      // switch to a different file): the container value belongs to
      // the file open in mpv, so the old title's value must not
      // survive (K(i)). Clear it first so the old title's 3D button
      // does not linger while the new read is in flight, then re-read.
      _containerDetection = null;
      _loadContainerStereoMode();
    }
  }

  /// The part of the selected version the detection reads the filename
  /// from: the part matching [TrackControlsState.sourcePartId], else
  /// the version's first part. Shared by [_detectStereo3d] and
  /// [_titleIdentity] so both agree on which file the title is.
  MediaPart? _selectedPart(TrackControlsState state) {
    if (state.availableVersions.isEmpty) return null;
    final index = state.selectedMediaIndex.clamp(
      0,
      state.availableVersions.length - 1,
    );
    final version = state.availableVersions[index];
    final partId = state.sourcePartId;
    if (partId != null) {
      for (final candidate in version.parts) {
        if (candidate.id == partId.toString()) return candidate;
      }
    }
    return version.parts.isNotEmpty ? version.parts.first : null;
  }

  /// Identity of the title (and file) the container read belongs to:
  /// the Plex rating key, the part, the selected version and the file
  /// open in mpv. Any of these changing means a different file is
  /// open, so the container value must be re-read (K(i)).
  String _titleIdentity(TrackControlsState state) {
    final part = _selectedPart(state);
    return '${state.ratingKey}|${state.sourcePartId}|'
        '${state.selectedMediaIndex}|${part?.file}';
  }

  Future<void> _loadContainerStereoMode() async {
    final generation = ++_containerLoadGeneration;
    try {
      final mode = await widget.player.getProperty('video-stereo-mode');
      if (!mounted || generation != _containerLoadGeneration) return;
      setState(() {
        _containerDetection = detectStereo3dFromMpvStereoMode(mode);
      });
    } catch (_) {
      // No container signal (a player without the property, or no file
      // open yet): filename/resolution/manual detection stands.
    }
  }

  KeyEventResult _handleButtonKeyEvent(FocusNode _, KeyEvent event, int index, int totalButtons) {
    if (!event.isActionable) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (index > 0 && widget.focusNodes != null && widget.focusNodes!.length > index - 1) {
        widget.focusNodes![index - 1].requestFocus();
        return KeyEventResult.handled;
      } else if (index == 0) {
        widget.onNavigateLeft?.call();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      if (index < totalButtons - 1 && widget.focusNodes != null && widget.focusNodes!.length > index + 1) {
        widget.focusNodes![index + 1].requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      widget.onNavigateUp?.call();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      widget.onNavigateDown?.call();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// Build a track control button with consistent focus handling
  Widget _buildTrackButton({
    required int buttonIndex,
    required IconData icon,
    required String semanticLabel,
    required VoidCallback? onPressed,
    // The row being built. Arrow-key navigation reads its length lazily, so
    // by event time it reflects every button that build() actually added.
    required List<Widget> buttons,
    String? tooltip,
    String? semanticValue,
    bool? checked,
    bool isActive = false,
  }) {
    return VideoControlButton(
      icon: icon,
      tooltip: tooltip,
      semanticLabel: semanticLabel,
      semanticValue: semanticValue,
      checked: checked,
      isActive: isActive,
      focusNode: widget.focusNodes != null && widget.focusNodes!.length > buttonIndex ? widget.focusNodes![buttonIndex] : null,
      onKeyEvent: widget.focusNodes != null
          ? (node, event) => _handleButtonKeyEvent(node, event, buttonIndex, buttons.length)
          : null,
      onFocusChange: widget.onFocusChange,
      onPressed: onPressed,
    );
  }

  /// Detects the stereo layout for the title currently playing, from
  /// the manual per-title record, the selected version's part filename
  /// and resolution, and the container's declared stereo mode once the
  /// file is open in mpv. One shared helper ([detectStereo3dForTitle])
  /// with the Plex direct-play decision, so the button and the
  /// direct-play rule cannot disagree (B6/U2). The container tier only
  /// applies here — the pre-playback Plex decision has no open file to
  /// read it from (D7).
  Stereo3dDetection _detectStereo3d(TrackControlsState state) {
    if (state.availableVersions.isEmpty) {
      return const Stereo3dDetection.twoD();
    }
    final index = state.selectedMediaIndex.clamp(
      0,
      state.availableVersions.length - 1,
    );
    final version = state.availableVersions[index];
    final part = _selectedPart(state);
    Stereo3dDetection? manual;
    final settings = SettingsService.instanceOrNull;
    if (settings != null && part != null && state.ratingKey.isNotEmpty) {
      final record =
          stereo3dTitleStore(settings).load(state.ratingKey, part.id);
      if (record != null) manual = record.toDetection();
    }
    return detectStereo3dForTitle(
      manual: manual,
      filename: part?.file,
      container: _containerDetection,
      width: version.width,
      height: version.height,
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Tracks>(
      stream: widget.player.streams.tracks,
      initialData: widget.player.state.tracks,
      builder: (context, snapshot) {
        final tracks = snapshot.data;
        final state = widget.trackControlsState;
        final isMobile = PlatformDetector.isMobile(context);
        final isDesktop = PlatformDetector.isDesktopOS();

        // 3D button (Quest 3D update): shown only when a 3D file was
        // detected on a Quest headset, or when the Advanced debug toggle
        // forces it on every video. Needs SettingsService for the toggle
        // and the sheet's prefs; without it the button stays hidden.
        final settings = SettingsService.instanceOrNull;
        final isQuest = QuestPlatform.isQuest;
        final detection = _detectStereo3d(state);
        final showStereo3dButton = settings != null &&
            shouldShowStereo3dButton(
              isQuest: isQuest,
              debugToggle: settings.read(SettingsService.questShow3dButtonDebug),
              detection: detection,
            );

        final buttons = <Widget>[];
        int buttonIndex = 0;

        buttons.add(
          ListenableBuilder(
            listenable: SleepTimerService(),
            builder: (context, _) {
              final sleepTimer = SleepTimerService();
              final shaderService = state.shaderService;
              final isShaderActive =
                  shaderService != null && shaderService.isSupported && shaderService.currentPreset.isEnabled;
              final isZoomActive = (state.videoZoomScale - 1.0).abs() > 0.0001;
              final isActive =
                  sleepTimer.isActive ||
                  state.audioSyncOffset != 0 ||
                  state.subtitleSyncOffset != 0 ||
                  isShaderActive ||
                  isZoomActive;
              return _buildTrackButton(
                buttonIndex: 0,
                icon: Symbols.tune_rounded,
                isActive: isActive,
                checked: isActive,
                tooltip: t.videoControls.settingsButton,
                semanticValue: _versionQualitySemanticValue(),
                semanticLabel: t.videoControls.settingsButton,
                buttons: buttons,
                onPressed: () {
                  state.onCancelAutoHide?.call();
                  OverlaySheetController.of(context)
                      .show(
                        builder: (_) => VideoSettingsSheet(player: widget.player, trackControlsState: state),
                      )
                      .whenComplete(() => state.onStartAutoHide?.call());
                },
              );
            },
          ),
        );
        buttonIndex++;

        {
          final currentIndex = buttonIndex;
          buttons.add(
            StreamBuilder<TrackSelection>(
              stream: widget.player.streams.track,
              initialData: widget.player.state.track,
              builder: (context, selectionSnapshot) {
                final selection = selectionSnapshot.data ?? widget.player.state.track;
                final hasSubtitleControls = state.hasSubtitleControls(tracks);
                final selectedSub = selection.subtitle;
                final hasActiveSubtitle = selectedSub != null && selectedSub.id != SubtitleTrack.off.id;
                final isHidden = hasSubtitleControls && hasActiveSubtitle && !state.subtitlesVisible;
                final icon = hasSubtitleControls
                    ? (isHidden ? Symbols.subtitles_off_rounded : Symbols.subtitles_rounded)
                    : Symbols.audiotrack_rounded;
                return _buildTrackButton(
                  buttonIndex: currentIndex,
                  icon: icon,
                  tooltip: t.videoControls.tracksButton,
                  semanticLabel: t.videoControls.tracksButton,
                  semanticValue: _selectionSemanticValue(tracks, selection),
                  buttons: buttons,
                  onPressed: () {
                    state.onCancelAutoHide?.call();
                    OverlaySheetController.of(context)
                        .show(
                          builder: (_) => TrackSheet(player: widget.player, trackControlsState: state),
                        )
                        .whenComplete(() => state.onStartAutoHide?.call());
                  },
                );
              },
            ),
          );
          buttonIndex++;
        }

        if (widget.chapters.isNotEmpty && !widget.hideChaptersAndQueue) {
          final currentIndex = buttonIndex;
          buttons.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: Symbols.bookmarks_rounded,
              tooltip: t.videoControls.chaptersButton,
              semanticLabel: t.videoControls.chaptersButton,
              buttons: buttons,
              onPressed: () {
                state.onCancelAutoHide?.call();
                OverlaySheetController.of(context)
                    .show(
                      builder: (_) => ChapterSheet(
                        player: widget.player,
                        chapters: widget.chapters,
                        chaptersLoaded: widget.chaptersLoaded,
                        canControl: state.canControl,
                        serverId: state.serverId,
                        onSeekRequested: widget.onSeekRequested,
                        onSeekCompleted: widget.onSeekCompleted,
                      ),
                    )
                    .whenComplete(() => state.onStartAutoHide?.call());
              },
            ),
          );
          buttonIndex++;
        }

        // 3D button (Quest 3D update): opens the 3D sheet. Only when a 3D
        // file was detected on a Quest headset, or the Advanced debug
        // toggle forces it on. The sheet itself gates the VR-only rows.
        if (showStereo3dButton) {
          final currentIndex = buttonIndex;
          buttons.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: Symbols.view_in_ar_rounded,
              tooltip: t.stereo3d.buttonTooltip,
              semanticLabel: t.stereo3d.button,
              isActive: detection.is3d,
              buttons: buttons,
              onPressed: () {
                state.onCancelAutoHide?.call();
                OverlaySheetController.of(context)
                    .show(
                      builder: (_) => Stereo3dSheet(
                        player: widget.player,
                        trackControlsState: state,
                        chapters: widget.chapters,
                        chaptersLoaded: widget.chaptersLoaded,
                        detection: detection,
                        isQuest: isQuest,
                        settings: settings,
                        titleStore: stereo3dTitleStore(settings),
                        vrChannel: VrPlayerChannel(),
                        onSeekRequested: widget.onSeekRequested,
                        onSeekCompleted: widget.onSeekCompleted,
                      ),
                    )
                    .whenComplete(() => state.onStartAutoHide?.call());
              },
            ),
          );
          buttonIndex++;
        }

        if (state.showQueueButton && state.onQueueItemSelected != null && !widget.hideChaptersAndQueue) {
          final currentIndex = buttonIndex;
          buttons.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: Symbols.queue_rounded,
              tooltip: t.videoControls.queue,
              semanticLabel: t.videoControls.queue,
              buttons: buttons,
              onPressed: () {
                state.onCancelAutoHide?.call();
                OverlaySheetController.of(context)
                    .show(builder: (_) => QueueSheet(onItemSelected: state.onQueueItemSelected!))
                    .whenComplete(() => state.onStartAutoHide?.call());
              },
            ),
          );
          buttonIndex++;
        }

        if (state.onTogglePIPMode != null) {
          final currentIndex = buttonIndex;
          buttons.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: Symbols.picture_in_picture_alt_rounded,
              tooltip: t.videoControls.pipButton,
              semanticLabel: t.videoControls.pipButton,
              buttons: buttons,
              onPressed: state.onTogglePIPMode,
            ),
          );
          buttonIndex++;
        }

        // BoxFit mode button
        if (state.onCycleBoxFitMode != null) {
          final currentIndex = buttonIndex;
          buttons.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: _getBoxFitIcon(state.boxFitMode),
              tooltip: _getBoxFitTooltip(state.boxFitMode),
              semanticLabel: t.videoControls.aspectRatioButton,
              semanticValue: _getBoxFitTooltip(state.boxFitMode),
              buttons: buttons,
              onPressed: state.onCycleBoxFitMode,
            ),
          );
          buttonIndex++;
        }

        // Rotation lock button (mobile only, not on TV since screens don't rotate)
        if (isMobile && !PlatformDetector.isTV()) {
          final currentIndex = buttonIndex;
          buttons.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: state.isRotationLocked ? Symbols.screen_lock_rotation_rounded : Symbols.screen_rotation_rounded,
              tooltip: state.isRotationLocked ? t.videoControls.unlockRotation : t.videoControls.lockRotation,
              semanticLabel: t.videoControls.rotationLockButton,
              checked: state.isRotationLocked,
              buttons: buttons,
              onPressed: state.onToggleRotationLock,
            ),
          );
          buttonIndex++;
        }

        // Screen lock button (mobile only, not on TV)
        if (isMobile && !PlatformDetector.isTV()) {
          final currentIndex = buttonIndex;
          buttons.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: Symbols.lock_rounded,
              tooltip: t.videoControls.lockScreen,
              semanticLabel: t.videoControls.screenLockButton,
              buttons: buttons,
              onPressed: state.onToggleScreenLock,
            ),
          );
          buttonIndex++;
        }

        // Always on top button (desktop only, not TV)
        if (isDesktop && state.onToggleAlwaysOnTop != null) {
          final currentIndex = buttonIndex;
          buttons.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: Symbols.layers_rounded,
              tooltip: t.videoControls.alwaysOnTopButton,
              semanticLabel: t.videoControls.alwaysOnTopButton,
              isActive: state.isAlwaysOnTop,
              checked: state.isAlwaysOnTop,
              buttons: buttons,
              onPressed: state.onToggleAlwaysOnTop,
            ),
          );
          buttonIndex++;
        }

        // Fullscreen button (desktop only)
        if (isDesktop) {
          final currentIndex = buttonIndex;
          buttons.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: state.isFullscreen ? Symbols.fullscreen_exit_rounded : Symbols.fullscreen_rounded,
              tooltip: state.isFullscreen ? t.videoControls.exitFullscreenButton : t.videoControls.fullscreenButton,
              semanticLabel: state.isFullscreen
                  ? t.videoControls.exitFullscreenButton
                  : t.videoControls.fullscreenButton,
              checked: state.isFullscreen,
              buttons: buttons,
              onPressed: state.onToggleFullscreen,
            ),
          );
        }

        return IntrinsicHeight(
          child: Row(mainAxisSize: .min, crossAxisAlignment: .stretch, children: buttons),
        );
      },
    );
  }

  String? _versionQualitySemanticValue() {
    final state = widget.trackControlsState;
    final values = <String>[];
    if (state.availableVersions.length > 1) {
      final index = state.selectedMediaIndex;
      if (index >= 0 && index < state.availableVersions.length) {
        values.add(state.availableVersions[index].displayLabel);
      }
    }
    if (state.serverSupportsTranscoding) {
      values.add(qualityPresetLabel(state.selectedQualityPreset));
    }
    return values.isEmpty ? null : values.join(' / ');
  }

  String? _selectionSemanticValue(Tracks? tracks, TrackSelection selection) {
    final values = <String>[];
    final audio = selection.audio;
    if (audio != null && audio.id != AudioTrack.off.id) {
      final index = tracks?.audio.indexWhere((track) => track.id == audio.id) ?? -1;
      final visibleIndex = index < 0 ? 0 : index;
      final label = TrackLabelBuilder.audioLabel(
        title: audio.title,
        language: audio.language,
        codec: audio.codec,
        codecProfile: audio.codecProfile,
        channels: audio.channelsCount,
        index: visibleIndex,
      );
      values.add(label.joined);
    }

    final subtitle = selection.subtitle;
    if (subtitle != null && subtitle.id != SubtitleTrack.off.id) {
      final index = tracks?.subtitle.indexWhere((track) => track.id == subtitle.id) ?? -1;
      values.add(
        TrackLabelBuilder.subtitleLabel(
          title: subtitle.title,
          language: subtitle.language,
          codec: subtitle.codec,
          forced: subtitle.isForced,
          index: index < 0 ? 0 : index,
        ).joined,
      );
    }

    return values.isEmpty ? null : values.join(', ');
  }

  IconData _getBoxFitIcon(int mode) {
    switch (mode) {
      case 0:
        return Symbols.fit_screen_rounded; // contain (letterbox)
      case 1:
        return Symbols.aspect_ratio_rounded; // cover (fill screen)
      case 2:
        return Symbols.settings_overscan_rounded; // fill (stretch)
      default:
        return Symbols.fit_screen_rounded;
    }
  }

  String _getBoxFitTooltip(int mode) {
    switch (mode) {
      case 0:
        return t.videoControls.letterbox;
      case 1:
        return t.videoControls.fillScreen;
      case 2:
        return t.videoControls.stretch;
      default:
        return t.videoControls.letterbox;
    }
  }
}
