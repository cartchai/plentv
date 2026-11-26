import 'dart:convert';

/// Stereoscopic 3D detection for PlenTV (1.6.29 Quest 3D update).
///
/// Plex gives nothing: no 3D support in any Plex app and no stereoscopic
/// flag in the API. All detection happens here, from the file itself.
///
/// Signals, ranked: manual per-title choice (persisted) > filename tag >
/// mpv/container metadata > resolution hint > 2D default. A manual choice
/// must stick — once a title has one, that choice is the answer (same
/// "pick one and stick with it" rule the app already uses for EPG
/// affiliates).
///
/// Detection must NOT declare a 1920x1080 file 3D on size alone, re-guess
/// on every load, or transcode a detected 3D title. Detected 3D forces
/// direct play — a Plex transcode would re-encode the packed frame as
/// flat 2D and destroy the 3D.

/// The packed layout of a 3D title.
enum Stereo3dLayout {
  /// Not 3D — an ordinary flat frame.
  twoD,

  /// Side by side: left and right squeezed (half) or full-width (full)
  /// side by side in one frame.
  sbs,

  /// Over-under / top-bottom: left on top, right below.
  ou,

  /// VR180: a 180-degree video wrapped around the viewer (S1).
  vr180,

  /// VR360: a 360-degree video wrapped around the viewer (S1).
  vr360,

  /// No manual choice — use detection. Only meaningful on a per-title
  /// record, never as a detection result.
  auto,
}

/// Which packing density the file uses.
enum Stereo3dPacking {
  /// Each eye squeezed to half the frame (e.g. 1920x1080 holding two
  /// 960x1080 eyes).
  half,

  /// Each eye at full size (e.g. 3840x1080 holding two 1920x1080 eyes).
  full,
}

/// Where a detection came from.
enum Stereo3dSource {
  /// A manual per-title choice, persisted.
  manual,

  /// The filename tag (primary).
  filename,

  /// mpv / container metadata (`video-stereo-mode`).
  container,

  /// The frame resolution (weak hint; only full packings).
  resolution,

  /// No signal — the 2D default.
  none,
}

/// The result of detecting whether a title is 3D.
class Stereo3dDetection {
  final Stereo3dLayout layout;
  final Stereo3dPacking packing;
  final Stereo3dSource source;

  const Stereo3dDetection({
    required this.layout,
    required this.packing,
    required this.source,
  });

  const Stereo3dDetection.twoD()
      : layout = Stereo3dLayout.twoD,
        packing = Stereo3dPacking.half,
        source = Stereo3dSource.none;

  /// True when this is a 3D title (any layout other than 2D).
  bool get is3d => layout != Stereo3dLayout.twoD && layout != Stereo3dLayout.auto;

  @override
  bool operator ==(Object other) =>
      other is Stereo3dDetection &&
      other.layout == layout &&
      other.packing == packing &&
      other.source == source;

  @override
  int get hashCode => Object.hash(layout, packing, source);

  @override
  String toString() => 'Stereo3dDetection($layout, $packing, $source)';
}

/// Detect the 3D layout from a server-side file path (the primary signal).
///
/// Uses the scene filename convention, case-insensitive. The path is the
/// `Media[].Part[].file` value Plex already parses. Detection runs on the
/// BASENAME only (B25): a folder named `SBS`/`OU`/`TAB` must not make
/// every file inside it "3D". Never declares a file 3D on size alone —
/// this is a tag check only.
Stereo3dDetection detectStereo3dFromFilename(String? file) {
  if (file == null || file.isEmpty) {
    return const Stereo3dDetection.twoD();
  }
  // Basename only — strip directories on either separator first.
  final basename = file.split(RegExp(r'[/\\]')).last;
  // Strip the extension and split into tokens on any non-alphanumeric
  // separator ('.', '-', '_', ' ', ...). 'H-SBS' -> ['h','sbs'],
  // '_LRF_Full_SBS' -> ['lrf','full','sbs'], '3D.HSBS' -> ['3d','hsbs'].
  final lower = basename.toLowerCase();
  final withoutExtension = lower.replaceAll(RegExp(r'\.[a-z0-9]{1,5}$'), '');
  final tokens = withoutExtension
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.isNotEmpty)
      .toSet();
  bool has(String token) => tokens.contains(token);
  bool hasAny(Iterable<String> candidates) => candidates.any(has);

  // VR180 / VR360 first — the most specific tags (S1).
  if (has('vr180') || (has('180') && has('sbs'))) {
    return const Stereo3dDetection(
      layout: Stereo3dLayout.vr180,
      packing: Stereo3dPacking.half,
      source: Stereo3dSource.filename,
    );
  }
  if (has('vr360') || has('360') || has('equirect') || has('equirectangular')) {
    // D5: mono 360 (full packing) is NOT detectable from a filename — no
    // tag distinguishes it — so VR360 is always half-packed here. Do not
    // re-add a ternary that pretends otherwise.
    return const Stereo3dDetection(
      layout: Stereo3dLayout.vr360,
      packing: Stereo3dPacking.half,
      source: Stereo3dSource.filename,
    );
  }

  // Full SBS: FSBS, F-SBS / Full-SBS, LRF (left-right-full).
  if (has('fsbs') ||
      has('lrf') ||
      (hasAny(const ['f', 'full']) && has('sbs'))) {
    return const Stereo3dDetection(
      layout: Stereo3dLayout.sbs,
      packing: Stereo3dPacking.full,
      source: Stereo3dSource.filename,
    );
  }
  // Half SBS: HSBS, H-SBS / Half-SBS.
  if (has('hsbs') || (hasAny(const ['h', 'half']) && has('sbs'))) {
    return const Stereo3dDetection(
      layout: Stereo3dLayout.sbs,
      packing: Stereo3dPacking.half,
      source: Stereo3dSource.filename,
    );
  }
  // Generic SBS: SBS, LR / RL (Meta's _LR / _RL suffixes).
  if (has('sbs') || has('lr') || has('rl')) {
    return const Stereo3dDetection(
      layout: Stereo3dLayout.sbs,
      packing: Stereo3dPacking.half,
      source: Stereo3dSource.filename,
    );
  }

  // Full over-under: FTAB, F-TAB / Full-TAB, F-OU / Full-OU.
  if (has('ftab') ||
      has('fou') ||
      (hasAny(const ['f', 'full']) && hasAny(const ['tab', 'ou']))) {
    return const Stereo3dDetection(
      layout: Stereo3dLayout.ou,
      packing: Stereo3dPacking.full,
      source: Stereo3dSource.filename,
    );
  }
  // Half over-under: HTAB, HOU, H-TAB / Half-TAB, H-OU / Half-OU.
  if (has('htab') ||
      has('hou') ||
      (hasAny(const ['h', 'half']) && hasAny(const ['tab', 'ou']))) {
    return const Stereo3dDetection(
      layout: Stereo3dLayout.ou,
      packing: Stereo3dPacking.half,
      source: Stereo3dSource.filename,
    );
  }
  // Generic over-under: OU, TAB, TB / BT (Meta's _TB / _BT suffixes).
  if (has('ou') || has('tab') || has('tb') || has('bt')) {
    return const Stereo3dDetection(
      layout: Stereo3dLayout.ou,
      packing: Stereo3dPacking.half,
      source: Stereo3dSource.filename,
    );
  }

  return const Stereo3dDetection.twoD();
}

/// Detect the 3D layout from the frame resolution (weak hint only).
///
/// Full SBS 3840x1080 and full OU 1920x2160 are reliable. Half formats
/// at 1920x1080 are indistinguishable from 2D — this NEVER declares a
/// 1920x1080 file 3D on size alone.
Stereo3dDetection detectStereo3dFromResolution(int width, int height) {
  if (width == 3840 && height == 1080) {
    return const Stereo3dDetection(
      layout: Stereo3dLayout.sbs,
      packing: Stereo3dPacking.full,
      source: Stereo3dSource.resolution,
    );
  }
  if (width == 1920 && height == 2160) {
    return const Stereo3dDetection(
      layout: Stereo3dLayout.ou,
      packing: Stereo3dPacking.full,
      source: Stereo3dSource.resolution,
    );
  }
  return const Stereo3dDetection.twoD();
}

/// Detect the 3D layout from mpv's `video-stereo-mode` property (container
/// metadata, read while mpv opens the stream — zero extra I/O).
///
/// mpv reports 'left_right' / 'right_left' for SBS, 'top_bottom' /
/// 'bottom_top' for over-under, and 'mono' for flat.
Stereo3dDetection detectStereo3dFromMpvStereoMode(String? mode) {
  switch (mode?.toLowerCase()) {
    case 'left_right':
    case 'right_left':
      return const Stereo3dDetection(
        layout: Stereo3dLayout.sbs,
        packing: Stereo3dPacking.half,
        source: Stereo3dSource.container,
      );
    case 'top_bottom':
    case 'bottom_top':
      return const Stereo3dDetection(
        layout: Stereo3dLayout.ou,
        packing: Stereo3dPacking.half,
        source: Stereo3dSource.container,
      );
    default:
      return const Stereo3dDetection.twoD();
  }
}

/// One shared detection entry point (U2/B6): every caller that decides
/// "is this title 3D" goes through here with the same precedence, so the
/// 3D button, the sheet's detection line and the Plex direct-play rule
/// cannot disagree about the same title.
///
/// Signals, in order: manual per-title choice > filename tag >
/// mpv/container metadata > resolution hint > 2D default.
///
/// The `container` signal only exists once the file is open in mpv, so
/// the pre-playback Plex direct-play decision passes none — it cannot
/// read a container that is not open yet. The button/sheet path passes
/// the live `video-stereo-mode` read.
Stereo3dDetection detectStereo3dForTitle({
  Stereo3dDetection? manual,
  String? filename,
  Stereo3dDetection? container,
  int? width,
  int? height,
}) {
  return resolveStereo3d(
    manual: manual,
    filename: filename,
    container: container,
    width: width,
    height: height,
  );
}

/// Resolve the final detection from every signal, in precedence order:
/// manual per-title choice > filename tag > mpv/container metadata >
/// resolution hint > 2D default.
///
/// A manual record whose layout is [Stereo3dLayout.auto] means "no
/// override" and falls through to detection.
Stereo3dDetection resolveStereo3d({
  Stereo3dDetection? manual,
  String? filename,
  Stereo3dDetection? container,
  int? width,
  int? height,
}) {
  if (manual != null && manual.layout != Stereo3dLayout.auto && manual.is3d) {
    return manual;
  }
  if (manual != null && manual.layout == Stereo3dLayout.twoD) {
    // A manual "play flat" choice is deliberate — it wins over a tag.
    return manual;
  }
  final fromFilename = detectStereo3dFromFilename(filename);
  if (fromFilename.is3d) return fromFilename;
  if (container != null && container.is3d) return container;
  if (width != null && height != null) {
    final fromResolution = detectStereo3dFromResolution(width, height);
    if (fromResolution.is3d) return fromResolution;
  }
  return const Stereo3dDetection.twoD();
}

/// Flat-screen presentation of a detected 3D title (1.6.29 §1.9, DECIDED:
/// FLAT). On phone/TV a detected 3D file plays as-is — the packed frame
/// with both eyes visible — NOT mono-left. The 3D files are a separate
/// set used only for 3D; phone/TV won't play them; showing both eyes is
/// the diagnostic (it tells the user it is a 3D file and whether it is
/// loading correctly). In VR, seeing both sides means the per-eye
/// splitting failed — each eye must see ONLY its half.
///
/// There is deliberately NO filter function here (D6): flat playback
/// never converts a 3D title, so "no filter — play the packed frame
/// as-is" is the whole rule and needs no API surface. (A manual
/// "watch in 2D (left eye)" choice from the 3D sheet is a separate,
/// explicit user action, not an automatic conversion.)

/// Whether the 3D button is shown in the player controls.
///
/// Visible only when a 3D file was detected on a Quest headset, or when
/// the Advanced debug toggle forces it on every video (any device). The
/// debug toggle exists so an untagged 3D file can still be marked 3D by
/// hand — without it, a file with no filename tag would never show the
/// button and could never get a manual record.
bool shouldShowStereo3dButton({
  required bool isQuest,
  required bool debugToggle,
  required Stereo3dDetection detection,
}) {
  return (isQuest && detection.is3d) || debugToggle;
}

/// A per-title 3D record, persisted per file (by Plex rating key + part
/// id — the same identity the app already uses for per-file progress).
///
/// `layout == auto` means "no manual choice — use detection". Once a
/// title has a manual choice, that choice sticks.
class Stereo3dTitleRecord {
  final Stereo3dLayout layout;
  final Stereo3dPacking packing;
  final bool swapEyes;

  /// Screen preset override: 'tv' or 'cinema', or null for the default.
  final String? screenPreset;

  /// Subtitle depth: 'below', 'onscreen' or 'follow', or null for default.
  final String? subtitleDepth;

  const Stereo3dTitleRecord({
    this.layout = Stereo3dLayout.auto,
    this.packing = Stereo3dPacking.half,
    this.swapEyes = false,
    this.screenPreset,
    this.subtitleDepth,
  });

  Map<String, dynamic> toJson() => {
        'layout': layout.name,
        'packing': packing.name,
        'swapEyes': swapEyes,
        if (screenPreset != null) 'screenPreset': screenPreset,
        if (subtitleDepth != null) 'subtitleDepth': subtitleDepth,
      };

  factory Stereo3dTitleRecord.fromJson(Map<String, dynamic> json) {
    final layoutName = json['layout'] as String?;
    final packingName = json['packing'] as String?;
    return Stereo3dTitleRecord(
      layout: layoutName == null
          ? Stereo3dLayout.auto
          : Stereo3dLayout.values.firstWhere(
              (e) => e.name == layoutName,
              orElse: () => Stereo3dLayout.auto,
            ),
      packing: packingName == null
          ? Stereo3dPacking.half
          : Stereo3dPacking.values.firstWhere(
              (e) => e.name == packingName,
              orElse: () => Stereo3dPacking.half,
            ),
      swapEyes: json['swapEyes'] == true,
      screenPreset: json['screenPreset'] as String?,
      subtitleDepth: json['subtitleDepth'] as String?,
    );
  }

  /// The manual detection this record represents, or an `auto` detection
  /// when the record carries no manual choice.
  Stereo3dDetection toDetection() => Stereo3dDetection(
        layout: layout,
        packing: packing,
        source: Stereo3dSource.manual,
      );

  Stereo3dTitleRecord copyWith({
    Stereo3dLayout? layout,
    Stereo3dPacking? packing,
    bool? swapEyes,
    String? screenPreset,
    String? subtitleDepth,
  }) {
    return Stereo3dTitleRecord(
      layout: layout ?? this.layout,
      packing: packing ?? this.packing,
      swapEyes: swapEyes ?? this.swapEyes,
      screenPreset: screenPreset ?? this.screenPreset,
      subtitleDepth: subtitleDepth ?? this.subtitleDepth,
    );
  }
}

/// Storage backend for the per-title 3D records. The production backend
/// is a single JSON string in SharedPreferences; tests use an in-memory
/// backend.
abstract class Stereo3dTitleStoreBackend {
  String? read();
  void write(String value);
}

/// The per-title 3D store: one JSON object keyed by
/// `"ratingKey|partId"` holding a [Stereo3dTitleRecord] per title.
///
/// No in-memory cache (B26): every read goes through the backend, which
/// is an in-memory pref read. A per-instance cache with no invalidation
/// let a save through one live store stay invisible to another.
class Stereo3dTitleStore {
  final Stereo3dTitleStoreBackend backend;

  Stereo3dTitleStore(this.backend);

  String _key(String ratingKey, String partId) => '$ratingKey|$partId';

  Map<String, Stereo3dTitleRecord> _records() {
    final raw = backend.read();
    final map = <String, Stereo3dTitleRecord>{};
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          for (final entry in decoded.entries) {
            final value = entry.value;
            if (value is Map<String, dynamic>) {
              map[entry.key] = Stereo3dTitleRecord.fromJson(value);
            }
          }
        }
      } catch (_) {
        // A corrupt store reads as empty; the next save overwrites it.
      }
    }
    return map;
  }

  Stereo3dTitleRecord? load(String ratingKey, String partId) {
    return _records()[_key(ratingKey, partId)];
  }

  void save(String ratingKey, String partId, Stereo3dTitleRecord record) {
    final records = _records();
    records[_key(ratingKey, partId)] = record;
    _persist(records);
  }

  void clear(String ratingKey, String partId) {
    final records = _records();
    if (records.remove(_key(ratingKey, partId)) != null) {
      _persist(records);
    }
  }

  void _persist(Map<String, Stereo3dTitleRecord> records) {
    final json = <String, dynamic>{
      for (final entry in records.entries) entry.key: entry.value.toJson(),
    };
    backend.write(jsonEncode(json));
  }
}
