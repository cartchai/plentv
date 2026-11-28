import 'dart:async';

/// How long playback may sit with no position advance before the stall
/// indicator shows. Position ticks arrive at ~4 Hz while playing, so 10 s
/// of silence is far past any normal buffering hiccup.
const Duration midStreamStallPatience = Duration(seconds: 10);

/// How long the stall indicator shows before the player retunes on its own.
/// The retune is a seek back to the current position (VOD) or the live
/// ladder retry (live TV) — the same primitives the network-restore and
/// error paths already use.
const Duration midStreamRetuneDelay = Duration(seconds: 10);

/// Sustained progress past a retune point that refills the automatic budget
/// — same 30 s as the spurious-EOF recovery, so a stream that recovers
/// earns its retries back for the next stall.
const int midStreamStallProgressResetMs = 30000;

/// Bounds a mid-stream stall: a stream whose picture froze after the first
/// frame, with nothing client-side ever failing.
///
/// At open time the open-phase watchdog owns the wait; once a frame has
/// rendered, mpv's `paused-for-cache` only drives the generic buffering
/// spinner, and a stream that stops advancing its position entirely — the
/// demuxer dead, the decoder stuck, ffmpeg's reconnect loop backing off
/// silently — sits on a frozen frame forever with no error event. This
/// watchdog watches the one signal that always moves while playback is
/// alive: the position tick. No advance for [stallPatience] while playing
/// raises [onStallChanged] (the indicator); a further [retuneDelay] with
/// still no advance fires [onRetune] (the automatic retune), bounded by
/// [maxRetunes] per open so a permanently dead stream cannot retune
/// forever — after the budget is spent the indicator stays and only a
/// manual retry recovers it.
///
/// The caller decides which opens are eligible and owns the retune itself.
/// Only the timer bookkeeping lives here so it is testable with `fakeAsync`.
///
/// What it cannot see: a renderer-only freeze, where time-pos still
/// advances but no new frame reaches the screen. That needs a frame
/// callback the player does not expose to Dart, so it stays out of scope.
class MidStreamStallWatchdog {
  MidStreamStallWatchdog({
    required this.onStallChanged,
    required this.onRetune,
    this.stallPatience = midStreamStallPatience,
    this.retuneDelay = midStreamRetuneDelay,
    this.maxRetunes = 2,
  });

  final Duration stallPatience;
  final Duration retuneDelay;
  final int maxRetunes;
  final void Function(bool stalled) onStallChanged;
  final void Function() onRetune;

  Timer? _stallTimer;
  Timer? _retuneTimer;
  int? _lastPositionMs;
  int? _baselineMs;
  int _retunes = 0;
  bool _armed = false;
  bool _playing = false;
  bool _stalled = false;

  bool get isArmed => _armed;
  bool get isStalled => _stalled;

  /// Mid-stream begins: the first frame rendered, so position silence from
  /// here on is a stall, not an open. Starts the silence window.
  void arm() {
    _armed = true;
    _playing = true;
    _startStallTimer();
  }

  /// A position tick. Only an ADVANCE counts as alive: mpv keeps emitting
  /// the frozen value while the stream is stuck, so equal values must not
  /// reset the window. A tick while paused is recorded but never resets —
  /// the timers are cancelled while paused anyway.
  void onPosition(Duration position) {
    final ms = position.inMilliseconds;
    if (ms == _lastPositionMs) return;
    _lastPositionMs = ms;
    if (!_armed || !_playing) return;
    _onAlive();
    // Sustained progress past the retune point proves the rebuilt stream
    // is healthy; refill the automatic budget for the next stall.
    final baselineMs = _baselineMs;
    if (baselineMs != null && ms >= baselineMs + midStreamStallProgressResetMs) {
      _retunes = 0;
      _baselineMs = null;
    }
  }

  /// The playhead moved discontinuously (seek, part advance, in-place
  /// reload): the backend is responding, so the stall window restarts.
  /// A seek that never lands still trips the watchdog after [stallPatience]
  /// — a seek stuck that long IS a stall.
  void onPlayheadJump() {
    if (!_armed || !_playing) return;
    _onAlive();
  }

  /// Playback paused or resumed. Pausing suspends the watchdog and clears
  /// the indicator — the viewer took control, so a frozen picture is their
  /// pause, not a stall. Resuming restarts the silence window: if the
  /// stream is still dead the timer fires again after [stallPatience].
  void onPlayingChanged(bool playing) {
    _playing = playing;
    if (!_armed) return;
    if (playing) {
      _startStallTimer();
    } else {
      _cancelTimers();
      _setStalled(false);
    }
  }

  /// Playback ended cleanly: the frozen position at EOF is not a stall.
  void onCompleted() {
    disarm();
  }

  /// A new open is about to produce its own first frame, or the screen is
  /// going away: any further position silence belongs to the next open.
  /// A new open is a fresh retune budget.
  void disarm() {
    _cancelTimers();
    _setStalled(false);
    _armed = false;
    _playing = false;
    _retunes = 0;
    _baselineMs = null;
  }

  void _onAlive() {
    _cancelTimers();
    _setStalled(false);
    if (_armed && _playing) _startStallTimer();
  }

  void _startStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = Timer(stallPatience, _onStallTimer);
  }

  void _onStallTimer() {
    _stallTimer = null;
    if (!_armed || !_playing) return;
    _setStalled(true);
    _retuneTimer?.cancel();
    _retuneTimer = Timer(retuneDelay, _onRetuneTimer);
  }

  void _onRetuneTimer() {
    _retuneTimer = null;
    if (!_armed || !_playing) return;
    if (_retunes >= maxRetunes) {
      // Budget spent: the indicator stays, and only a manual retry
      // recovers the stream. Never retune forever on a dead stream.
      return;
    }
    _retunes++;
    _baselineMs = _lastPositionMs;
    onRetune();
    // The retune may or may not recover the stream: if position stays
    // frozen, the stall timer fires again and the next retune follows
    // after another patience + delay — until the budget is spent. (The
    // retune itself may have disarmed the watchdog — a new open owns its
    // own window — so re-check before restarting.)
    if (_armed && _playing) _startStallTimer();
  }

  void _setStalled(bool stalled) {
    if (_stalled == stalled) return;
    _stalled = stalled;
    onStallChanged(stalled);
  }

  void _cancelTimers() {
    _stallTimer?.cancel();
    _stallTimer = null;
    _retuneTimer?.cancel();
    _retuneTimer = null;
  }
}
