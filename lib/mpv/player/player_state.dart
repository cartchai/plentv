import '../models.dart';

/// Immutable snapshot of the current player state.
/// For reactive updates, use [PlayerStreams].
class PlayerState {
  final bool playing;
  final bool completed;
  final bool buffering;
  final Duration position;
  final Duration duration;
  final bool seekable;
  final Duration buffer;
  final double volume;
  final double rate;
  final Tracks tracks;
  final TrackSelection track;
  final AudioDevice audioDevice;
  final List<AudioDevice> audioDevices;
  final List<BufferRange> bufferRanges;

  /// Whether the file the backend is currently on has rendered a frame:
  /// set by `playback-restart`, cleared when a new file begins
  /// (`start-file`, and `file-loaded` for backends that report no
  /// `start-file`). Survives seeks and end of file.
  final bool hasRenderedFrame;

  /// 1.2.22 §63.3: the plain-words note shown when a file's format was
  /// rejected by the hardware plane and no frame has rendered 3 s after
  /// the rejection — the user is staring at a black frame with no
  /// explanation, so the note says what is happening. Null when no
  /// fallback is in progress; cleared when a frame renders or a new
  /// file begins.
  final String? decoderFallbackNote;

  const PlayerState({
    this.playing = false,
    this.completed = false,
    this.buffering = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.seekable = false,
    this.buffer = Duration.zero,
    this.volume = 100.0,
    this.rate = 1.0,
    this.tracks = const Tracks(),
    this.track = const TrackSelection(),
    this.audioDevice = AudioDevice.auto,
    this.audioDevices = const [],
    this.bufferRanges = const [],
    this.hasRenderedFrame = false,
    this.decoderFallbackNote,
  });

  /// Sentinel so [copyWith] can clear [decoderFallbackNote] (a plain
  /// `String?` parameter could never distinguish "keep" from "clear").
  static const Object _unsetDecoderFallbackNote = Object();

  PlayerState copyWith({
    bool? playing,
    bool? completed,
    bool? buffering,
    Duration? position,
    Duration? duration,
    bool? seekable,
    Duration? buffer,
    double? volume,
    double? rate,
    Tracks? tracks,
    TrackSelection? track,
    AudioDevice? audioDevice,
    List<AudioDevice>? audioDevices,
    List<BufferRange>? bufferRanges,
    bool? hasRenderedFrame,
    Object? decoderFallbackNote = _unsetDecoderFallbackNote,
  }) {
    return PlayerState(
      playing: playing ?? this.playing,
      completed: completed ?? this.completed,
      buffering: buffering ?? this.buffering,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      seekable: seekable ?? this.seekable,
      buffer: buffer ?? this.buffer,
      volume: volume ?? this.volume,
      rate: rate ?? this.rate,
      tracks: tracks ?? this.tracks,
      track: track ?? this.track,
      audioDevice: audioDevice ?? this.audioDevice,
      audioDevices: audioDevices ?? this.audioDevices,
      bufferRanges: bufferRanges ?? this.bufferRanges,
      hasRenderedFrame: hasRenderedFrame ?? this.hasRenderedFrame,
      decoderFallbackNote: identical(decoderFallbackNote, _unsetDecoderFallbackNote)
          ? this.decoderFallbackNote
          : decoderFallbackNote as String?,
    );
  }

  /// Whether media is actively playing (not paused, not at EOF).
  ///
  /// mpv keeps [playing] true at EOF, so raw [playing] alone is unreliable
  /// for gating wakelock, media controls, progress tracking, etc.
  bool get isActive => playing && !completed;

  @override
  String toString() => 'PlayerState(playing: $playing, position: $position, duration: $duration, seekable: $seekable)';
}
