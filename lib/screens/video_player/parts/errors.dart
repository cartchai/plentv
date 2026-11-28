part of '../../video_player_screen.dart';

extension _VideoPlayerErrorMethods on VideoPlayerScreenState {
  String _safePlaybackErrorMessage(Object error) {
    // The native core failed to start; the sentinel carries no prose because
    // the UI owns the wording — show the localized copy directly.
    if (error is PlayerInitializationException) {
      return t.messages.playbackFailed;
    }
    final raw = error.toString();
    final redacted = LogRedactionManager.redact(raw);
    if (raw.contains('No client registered')) {
      return t.messages.errorLoading(error: t.messages.serverUnavailableForProfile);
    }
    return t.messages.errorLoading(error: redacted);
  }

  void _onPlayerError(PlayerError err) {
    appLogger.e('[Player ERROR] ${err.message}');
    if (!mounted || _isExiting.value) return;
    // The open already failed and its verdict is on screen: every further
    // error is the same dead load (a playlist walk, a retrying reconnect)
    // reporting again, and re-running the policy per event is what turned a
    // failed HLS open into an ANR. A new open resets the latch.
    if (_hasFatalPlaybackError) return;

    // A sidecar subtitle fetch can also log a status, but it never raises the
    // end-file error this handler is wired to, so a latched status belongs to
    // the primary media open.
    final action = resolvePlaybackFailureAction(
      cause: err.cause,
      fatalHttpStatuses: _fatalHttpStatuses,
      transientHttpStatuses: _transientHttpStatuses,
      transientRetryAttempts: _transientRetryAttempts,
      isLive: widget.isLive,
      liveRetrying: _live.retrying,
      liveFallbackLevel: _live.fallbackLevel,
      liveRetryFailed: _live.retryFailed,
      // 1.2.19 L-47: a catch-up open is the only live open whose 404/458
      // take the missing-recording / line-busy cards instead of the ladder.
      // Per-tune, not per-screen: a zap after a catch-up launch is a live
      // tune, and its failures must never read as a missing recording.
      isCatchUp: _isCurrentTuneCatchUp,
      lastHttpStatus: _lastHttpStatus,
    );

    switch (action) {
      // Every dialog is unrecoverable until the server side changes, so each
      // replaces the snackbar rather than joining it.
      case PlaybackFailureAction.playbackNotAllowedDialog:
        _latchFatalPlaybackError(action);
        unawaited(_showPlaybackNotAllowedDialog());
      // 1.2.19 L-47: the panel answered this catch-up open — 404 means no
      // recording for the programme, 458 means the line is busy. Neither
      // may touch the ladder (it would drop the offset and silently
      // re-open live TV). The card names the programme and channel and
      // offers Watch live; a busy line also keeps Retry, which replays
      // the same catch-up offset — a missing recording never retries.
      case PlaybackFailureAction.catchUpMissingRecording:
        _latchFatalPlaybackError(action);
        _presentPlaybackFailure(
          _catchUpMissingRecordingMessage(),
          showRetry: false,
          secondaryLabel: t.iptv.miniPlayerWatchLive,
          onSecondaryAction: _watchLiveFromCatchUpFailure,
        );
      case PlaybackFailureAction.catchUpLineBusy:
        _latchFatalPlaybackError(action);
        _presentPlaybackFailure(
          t.iptv.miniPlayerLineBusy,
          secondaryLabel: t.iptv.miniPlayerWatchLive,
          onSecondaryAction: _watchLiveFromCatchUpFailure,
        );
      // One bounded re-open after a backoff for a transient refusal (429
      // only, build #28 — a 403 is never retried). The failure view stays
      // down — the viewer never sees a flash of the error for a failure the
      // retry may clear. If the retry also fails, the policy runs again with
      // the budget spent and the terminal path owns it. Deliberately NOT
      // latched as fatal: the open is still recoverable.
      case PlaybackFailureAction.retryTransient:
        _transientRetryAttempts++;
        unawaited(_retryTransientPlayback());
        return;
      case PlaybackFailureAction.serverLimitDialog:
        _latchFatalPlaybackError(action);
        unawaited(_showServerLimitDialog());
      case PlaybackFailureAction.mediaUnreadableDialog:
        _latchFatalPlaybackError(action);
        unawaited(_showMediaUnreadableDialog());
      case PlaybackFailureAction.serverBusyDialog:
        _latchFatalPlaybackError(action);
        unawaited(_showServerBusyDialog());
      // The bounded retry operation owns errors raised while applying/opening
      // its replacement stream. Do not let the same error close the route.
      case PlaybackFailureAction.ignore:
        return;
      case PlaybackFailureAction.liveRetry:
        _beginLiveLadderRetry();
      case PlaybackFailureAction.liveInterrupted:
        showGlobalErrorSnackBar(t.messages.liveStreamInterrupted);
      case PlaybackFailureAction.fatal:
        _latchFatalPlaybackError(action, cause: err.cause);
        // A failed core start carries only diagnostic text; _lastLogError is
        // raw mpv/ffmpeg output, so neither is fit to show bare — use the
        // localized copy, with the redacted diagnostic as its detail. A timed
        // out open raised nothing itself, but the last error line mpv logged
        // on the way to the stall (a chain that failed, a stream that never
        // produced) is the only diagnosis there is, so it rides along too.
        final lastLogError = _lastLogError;
        // 1.6.22: the open went through the tunnel proxy — say so plainly
        // instead of the generic text. The latch is set only when the
        // proxy write landed for THIS open; a direct-mode failure keeps
        // the current generic text. The screen's `player` field is the
        // current player, and a fresh instance's latch starts false, so
        // a stale read can only fall back to generic, never name the
        // tunnel wrongly.
        final message = (player?.lastOpenUsedProxy ?? false)
            ? t.messages.playbackFailedViaTunnel
            : switch (err.cause) {
                PlayerError.playerInitFailed => t.messages.playbackFailed,
                PlayerError.openTimedOut =>
                  lastLogError == null
                      ? t.messages.playbackFailed
                      : t.messages.playbackFailedDetail(error: lastLogError),
                PlayerError.audioOutputFailed => t.messages.audioOutputFailed,
                _ => t.messages.playbackFailedDetail(error: _redactPlayerError(lastLogError ?? err.message)),
              };
        // Live TV has no in-place reload to retry through: its own start
        // flow leaves the route on failure, so a dead live session does too.
        if (widget.isLive) {
          showGlobalErrorSnackBar(message);
          unawaited(_handleBackButton());
          return;
        }
        _presentPlaybackFailure(message);
    }
  }

  /// One bounded re-open after [transientRetryBackoff] for a transient
  /// refusal. The guards matter: a playback restart in the meantime means
  /// the stream recovered on its own (the budget reset to 0 is the signal),
  /// and a new attempt — the viewer pressing Retry, a reload — supersedes
  /// this one. Either way the retry must not re-open a working stream.
  Future<void> _retryTransientPlayback() async {
    final attempt = _playbackAttempt;
    await Future.delayed(transientRetryBackoff);
    if (!mounted || _shuttingDown || _hasFatalPlaybackError) return;
    if (_transientRetryAttempts == 0) return;
    if (!identical(_playbackAttempt, attempt) || !(attempt?.isCurrent ?? false)) return;
    _retryFailedPlayback();
  }

  /// A terminal player error: the attempt is no longer current, progress
  /// reporting stops, every waiter armed for its open collapses, and the
  /// backend is told to stop — the error UI is the only thing left running
  /// for it. The stop is not optional: on a failed HLS open mpv falls back to
  /// its playlist parser and walks the manifest's entries, each failing in
  /// turn (46 end-file errors in 4 s on a Fire TV), and with the route no
  /// longer popping nothing else halts that walk; a stalled load is likewise
  /// still retrying and a late success must not play behind the failure
  /// view. Further errors from the same dead open are ignored by
  /// [_onPlayerError] until a new open resets the latch. The launch receipt
  /// goes terminal here, not on exit: the route may never close (an
  /// agent-launched player has nothing to pop to), and a caller polling the
  /// receipt must not read a failed open as `opening` or, after Back, as a
  /// user stop.
  void _latchFatalPlaybackError(PlaybackFailureAction action, {String? cause}) {
    _hasFatalPlaybackError = true;
    _progressTracker?.stopTracking();
    // Build #28: the stream is dead — background panel work may run again.
    IptvPlaybackActivity.instance.markIdle();
    _abortCurrentOpen('player error: ${action.name}');
    _detachWatchTogetherAfterFailure();
    final currentPlayer = player;
    if (currentPlayer != null) {
      unawaited(
        currentPlayer.stop().catchError((Object e, StackTrace st) {
          appLogger.w('Failed to stop the failed load', error: e, stackTrace: st);
        }),
      );
    }
    if (_ownsLaunchPlayback() && widget.launchObserver?.failure == null) {
      widget.launchObserver?.mark(
        'failed',
        failure: switch (action) {
          PlaybackFailureAction.playbackNotAllowedDialog => 'playbackNotAllowed',
          PlaybackFailureAction.serverLimitDialog => 'serverLimit',
          PlaybackFailureAction.mediaUnreadableDialog => 'mediaUnreadable',
          PlaybackFailureAction.serverBusyDialog => 'serverBusy',
          _ => cause == PlayerError.audioOutputFailed ? 'audioOutputFailed' : 'playbackFailed',
        },
      );
    }
  }

  /// Raise the persistent failure surface over the player. It stays until
  /// Retry re-runs the open or Back leaves; a snackbar is neither focusable
  /// nor on a remote's path, and it is gone in seconds. The spinner is
  /// forced down so it cannot sit over the view, and Retry takes focus once
  /// the view has built (see [_initializationErrorFocusNode]). The backend's
  /// end-file verdict always lands; a thrown open only fills an empty view,
  /// since the verdict that preceded it is the more specific of the two.
  ///
  /// [showRetry] hides the Retry button (1.2.19 L-47: a missing recording
  /// is never retried — the panel already answered). [secondaryLabel] +
  /// [onSecondaryAction] add the Watch live button beside it.
  void _presentPlaybackFailure(
    String message, {
    bool showRetry = true,
    String? secondaryLabel,
    VoidCallback? onSecondaryAction,
  }) {
    if (!mounted || _shuttingDown) return;
    _firstFrame.forceUiReadyOnFailure();
    // Nothing plays behind the view, so it must not hold the screen awake
    // while it waits; the playing-state handler takes the wakelock again once
    // a retried open plays.
    unawaited(_wakelockController.setEnabled(false));
    _setPlayerState(() {
      _playbackFailureMessage = message;
      _playbackFailureRetry = showRetry ? _retryFailedPlayback : null;
      _playbackFailureSecondaryLabel = secondaryLabel;
      _playbackFailureSecondaryAction = onSecondaryAction;
    });
    _focusFailureActionAfterBuild();
  }

  void _dismissPlaybackFailure() {
    if (_playbackFailureMessage == null) return;
    _setPlayerState(() {
      _playbackFailureMessage = null;
      _playbackFailureRetry = null;
      _playbackFailureSecondaryLabel = null;
      _playbackFailureSecondaryAction = null;
    });
  }

  /// Missing-recording card text (1.2.19 L-47): the mini-player's wording,
  /// naming the programme and channel — "Could not start" told the owner nothing
  /// about a catch-up the panel simply has no recording for.
  String _catchUpMissingRecordingMessage() {
    final channel = _currentLiveChannel?.displayName ?? widget.live?.channel.displayName ?? t.liveTv.unknownChannel;
    final programme = widget.live?.catchUpProgrammeTitle;
    if (programme != null && programme.isNotEmpty) {
      return t.iptv.miniPlayerMissingRecording(programme: programme, channel: channel);
    }
    return t.iptv.miniPlayerMissingRecordingNoProgramme(channel: channel);
  }

  /// Watch live (1.2.19 L-47): the catch-up cards' one action — re-tune
  /// the same channel live, with no catch-up epoch. The panel has no
  /// recording for the programme (or the line is busy), but the live
  /// stream works. The override is consumed once by the next
  /// [_startPlayback]; a later manual Retry replays the catch-up, as
  /// the mini-player's Retry does.
  void _watchLiveFromCatchUpFailure() {
    _watchLiveAfterCatchUpFailure = true;
    _dismissPlaybackFailure();
    _retryPlayerInitialization();
  }

  /// The button only exists after the next frame builds, so the request waits
  /// for it; see [_initializationErrorFocusNode] for why autofocus alone
  /// leaves the view with nothing focused.
  void _focusFailureActionAfterBuild() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _shuttingDown || (_playerInitializationError == null && _playbackFailureMessage == null)) {
        return;
      }
      if (_initializationErrorFocusNode.canRequestFocus) _initializationErrorFocusNode.requestFocus();
    });
  }

  /// The open Retry re-runs for the failure on screen. A failed in-place
  /// source switch restores the request that was playing before it — one
  /// attempt, prompted; a restore that fails too leaves the failure view up.
  /// Anything else re-runs the failed open itself, from the playhead when
  /// that open had already rendered.
  _PlaybackOpenRequest? _retryRequestForFailure() {
    final current = _currentOpenRequest;
    if (current == null) return null;
    final working = _workingOpenRequest;
    if (working != null && working.metadata.globalKey == current.metadata.globalKey && !working.sameSourceAs(current)) {
      return working.resumingAt(current.resumePosition ?? working.resumePosition);
    }
    if (_firstFrame.rendered) return current.resumingAt(player?.state.position);
    return current;
  }

  void _retryFailedPlayback() {
    final request = _retryRequestForFailure();
    if (request == null || player == null) {
      // Nothing was ever dispatched (or the core is gone): start over.
      _retryPlayerInitialization();
      return;
    }
    unawaited(_reopenAfterFailure(request));
  }

  Future<void> _reopenAfterFailure(_PlaybackOpenRequest request) async {
    final outcome = await _reloadMediaInPlace(
      metadata: request.metadata,
      selectedMediaIndex: request.mediaIndex,
      selectedMediaSourceId: request.mediaSourceId,
      qualityPreset: request.qualityPreset,
      forceTranscode: request.forceTranscode,
      selectedAudioStreamId: request.audioStreamId,
      useCurrentAudioStreamSelection: false,
      resumePosition: request.resumePosition,
      preferredSubtitleTrackOverride: SubtitlePreference.trackOrNull(_playbackSession?.subtitleSelection.primaryTrack),
      // A failure before the open rolls the view back to the message it
      // retried from; one after it raises its own through _onPlayerError.
      showErrorUi: false,
      reason: 'retry after playback failure',
    );
    if (outcome == MediaReloadOutcome.failed && mounted && _playbackFailureMessage == null) {
      _presentPlaybackFailure(t.messages.playbackFailed);
    }
  }

  void _onPlayerLog(PlayerLog log) {
    final status = PlayerError.httpStatusFromLog(log.text);
    // 1.2.19 L-47: latch the panel's HTTP answer for the current tune,
    // fatal or not — the mini-player keeps the same latch (`_onPlayerLog`
    // there). ffmpeg logs the status one warn-level line ahead of the
    // error; mpv collapses every status into the same "file failed to
    // load", so without this latch a catch-up 404 and a busy line look
    // identical. Reset per tune, so a stale status from an earlier tune
    // can never mislabel the next failure.
    if (status != null) _lastHttpStatus = status;
    // Build #27: a stream the panel answers with a fatal HTTP status is
    // a refusal — record it (once per open: the set only latches a status
    // the first time) so it shows in Settings → IPTV → Connection
    // refusals. Record-only; the failure policy below is unchanged.
    if (status != null && fatalPlaybackHttpStatuses.contains(status) && _fatalHttpStatuses.add(status)) {
      unawaited(_recordIptvStreamRefusal(status: status, failureKind: 'http'));
    }
    if (status != null && transientPlaybackHttpStatuses.contains(status)) _transientHttpStatuses.add(status);
    // An open the server answers with 503 never fails on its own: ffmpeg's
    // reconnect loop retries 503 forever and mpv just reports buffering
    // (#1830). Bound it. Live TV stays out — its ladder owns retries there.
    // A sidecar subtitle fetch shares this log stream and could arm the
    // watchdog too, but a first frame disarms it, so that only matters when
    // the primary media is itself stuck.
    if (status == 503 && !widget.isLive && !_firstFrame.rendered && !_hasFatalPlaybackError) {
      _http503Watchdog.onOpenPhase503();
    }
    if (log.level == PlayerLogLevel.error || log.level == PlayerLogLevel.fatal) {
      appLogger.e('[Player LOG ERROR] [${log.prefix}] ${log.text}');
      _lastLogError = _redactPlayerError(log.text.trim());
    }
    if (SpuriousEofRecovery.isTransportFaultLog(log)) _transportFaultSeen = true;
    // A stream mpv gives up on at open (`error_on_track`) ends the file only
    // when the other stream is gone too; otherwise the load lives on with no
    // end-file and the viewer waits out the open deadline for an error mpv
    // logged seconds earlier. Fail the open on that line instead. Same guard
    // as the deadline: a first frame or a latched error already settled this
    // open, and a superseded attempt's lines are not this open's business.
    if (_firstFrame.rendered || _hasFatalPlaybackError || !(_playbackAttempt?.isCurrent ?? false)) return;
    final cause = openFailureCauseFromLog(level: log.level, prefix: log.prefix, text: log.text);
    if (cause == null) return;
    appLogger.w('mpv gave up on a stream while opening — giving up on this open');
    _onPlayerError(PlayerError(log.text.trim(), cause: cause));
  }

  /// Record a stream refusal in the IPTV refusal log (build #27): the
  /// panel answered this open with [status], or the open stalled out
  /// ([failureKind] 'timeout', no status). Record-only — it never
  /// changes the failure policy, and it only fires for IPTV clients:
  /// a Plex/Jellyfin 403 is not a panel refusal. The action is the
  /// title of what was opening, never the stream URL (which carries the
  /// credentials in its path). Fire-and-forget: the log write must never
  /// hold up the failure UI.
  Future<void> _recordIptvStreamRefusal({required int? status, required String failureKind}) async {
    final client = _getMediaServerClient(context);
    if (client is! IptvClient) return;
    final title = _currentOpenRequest?.metadata.title;
    final action = title == null || title.isEmpty ? 'stream' : 'stream: $title';
    try {
      await IptvRefusalLog.instance.record(
        IptvRefusalEntry(
          timestamp: DateTime.now(),
          connectionId: client.connection.id,
          connectionName: client.connection.displayName,
          action: action,
          statusCode: status,
          failureKind: failureKind,
          userAgent: client.streamHeaders['User-Agent'] ?? '',
        ),
      );
    } catch (_) {
      // Recording is best-effort; the failure itself is unaffected.
    }
  }

  /// The open-phase 503 watchdog's deadline passed with no first frame: the
  /// server is still refusing the stream. Synthesize the error the reconnect
  /// loop will never raise on its own so the normal failure policy runs.
  void _onOpenHttp503Persistent() {
    if (!mounted || _isExiting.value || _firstFrame.rendered || _hasFatalPlaybackError) return;
    appLogger.w(
      'Server kept answering the stream with HTTP 503 for '
      '${openHttp503Patience.inSeconds}s without a first frame — giving up on this open',
    );
    unawaited(_recordIptvStreamRefusal(status: 503, failureKind: 'http'));
    _onPlayerError(PlayerError(t.messages.serverBusyTitle, cause: PlayerError.serverHttp503));
  }

  /// The mid-stream stall watchdog fired: the position has not advanced
  /// for [midStreamStallPatience] while playing. The buffering overlay
  /// shows the stall label until the position moves again (or the viewer
  /// pauses). Guarded like the 503 callback: a late timer must not touch
  /// a disposed screen.
  void _onStallChanged(bool stalled) {
    if (!mounted || _shuttingDown) return;
    _isStalled.value = stalled;
    if (stalled) {
      appLogger.w(
        'Stream stalled mid-play: no position advance for '
        '${midStreamStallPatience.inSeconds}s — showing the stall indicator',
      );
    }
  }

  /// The stall outlasted the indicator window: retune automatically.
  /// VOD re-opens the stream at the current position (the same seek the
  /// network-restore path uses); live TV retries its ladder at the same
  /// level, re-opening at the live edge. Bounded by the watchdog's
  /// per-open budget, so a dead stream cannot retune forever.
  void _onStallRetune() {
    if (!mounted || _shuttingDown || player == null) return;
    appLogger.i('Stream still stalled after the indicator window — retuning automatically');
    if (widget.isLive) {
      unawaited(_retryLiveStream());
    } else {
      _forceStreamReconnect();
    }
  }

  /// The attempt's open deadline passed: the backend started the load and
  /// then stopped moving without loading, failing, or dying. Its waiters are
  /// already aborted; synthesize the error the backend never raised so the
  /// failure policy runs (which stops the still-retrying load) and the viewer
  /// is not left on a spinner. Same guard as the 503 watchdog: a first frame
  /// or a latched error already settled this open.
  void _onOpenDeadlineExpired(Player currentPlayer, int generation) {
    if (!_isCurrentPlaybackGeneration(generation, currentPlayer) || _firstFrame.rendered || _hasFatalPlaybackError) {
      return;
    }
    appLogger.w(
      'No load progress for ${openDeadlineFor(isLive: widget.isLive).inSeconds}s before the first frame — giving up on this open',
    );
    unawaited(_recordIptvStreamRefusal(status: null, failureKind: 'timeout'));
    _onPlayerError(PlayerError(t.messages.playbackFailed, cause: PlayerError.openTimedOut));
  }

  String _redactPlayerError(String message) => LogRedactionManager.redact(message);

  Future<void> _showPlaybackNotAllowedDialog() async {
    if (!mounted) return;
    await showPlaybackNotAllowedDialog(context);
    if (mounted) unawaited(_handleBackButton());
  }

  /// The HTTP 500 modal. Where [offersServerLimitTranscode] allows, it also
  /// offers to have the server transcode the item; picking that reopens the
  /// item as a transcode instead of leaving the route.
  Future<void> _showServerLimitDialog() async {
    if (!mounted) return;
    final offerTranscode = offersServerLimitTranscode(
      isLive: widget.isLive,
      isPlexBacked: _currentMetadata.backend == MediaBackend.plex,
      serverSupportsTranscoding: _serverSupportsTranscoding,
      requestedPreset: _currentOpenRequest?.qualityPreset ?? _selectedQualityPreset,
      fallbackAlreadyUsed: _serverLimitFallbackUsed,
    );
    final transcode = await showServerLimitDialog(context, offerTranscode: offerTranscode);
    if (!mounted) return;
    if (transcode && offerTranscode) {
      await _reopenAsServerLimitTranscode();
      return;
    }
    unawaited(_handleBackButton());
  }

  /// Reopen the item the server refused (HTTP 500) as a server transcode at
  /// the same preset, once. The server picks the output its limit admits; the
  /// raw file is never requested again: the reload withholds direct play and
  /// fails instead of falling back to the file. A refused transcode, before
  /// or after its open, brings the dialog back without the offer, because
  /// [_serverLimitFallbackUsed] is set.
  Future<void> _reopenAsServerLimitTranscode() async {
    final request = _retryRequestForFailure();
    if (request == null || player == null) {
      unawaited(_handleBackButton());
      return;
    }
    _serverLimitFallbackUsed = true;
    // The raw file's 500 must not classify the transcode's own failure.
    _fatalHttpStatuses.clear();
    final outcome = await _reloadMediaInPlace(
      metadata: request.metadata,
      selectedMediaIndex: request.mediaIndex,
      selectedMediaSourceId: request.mediaSourceId,
      qualityPreset: request.qualityPreset,
      forceTranscode: true,
      selectedAudioStreamId: request.audioStreamId,
      useCurrentAudioStreamSelection: false,
      resumePosition: request.resumePosition,
      // Same carry as episode navigation: the viewer's launch picks, or what
      // they chose since, survive the switch to the transcode.
      preserveCurrentTrackSelection: true,
      preservedAudioTrack: _sessionAudioPreference ?? _preferredAudioTrack,
      preservedSubtitleTrack: _sessionSubtitlePreference ?? _preferredSubtitleTrack,
      preservedSecondarySubtitleTrack: _sessionSecondarySubtitlePreference ?? _preferredSecondarySubtitleTrack,
      showErrorUi: false,
      reason: 'server limit transcode',
    );
    if (!mounted) return;
    switch (outcome) {
      // Playing, or a newer transition owns the player now; a failure after
      // the open arrives through _onPlayerError like any other.
      case MediaReloadOutcome.opened:
      case MediaReloadOutcome.superseded:
      case MediaReloadOutcome.rejected:
        return;
      // The server would not start the transcode: its final answer.
      case MediaReloadOutcome.failed:
        _latchFatalPlaybackError(PlaybackFailureAction.serverLimitDialog);
        unawaited(_showServerLimitDialog());
    }
  }

  Future<void> _showMediaUnreadableDialog() async {
    if (!mounted) return;
    await showMediaUnreadableDialog(context);
    if (mounted) unawaited(_handleBackButton());
  }

  Future<void> _showServerBusyDialog() async {
    if (!mounted) return;
    // The reconnect loop is still running behind the modal; pause so a server
    // that recovers mid-dialog cannot start playing under it. Best-effort —
    // the route is left on dialog close either way.
    unawaited(player?.pause().catchError((_) {}));
    await showServerBusyDialog(context);
    if (mounted) unawaited(_handleBackButton());
  }

  /// Handle notification when native player switched from ExoPlayer to MPV
  Future<void> _onBackendSwitched() async {
    _playerBackendLabel = 'mpv';
    _recordLifecycleState('backend_switched', action: 'mpv_fallback');

    _toastController.show(
      Symbols.swap_horiz_rounded,
      t.messages.switchingToCompatiblePlayer,
      duration: const Duration(seconds: 2),
    );

    await _trackManager?.onBackendSwitched();
  }
}
