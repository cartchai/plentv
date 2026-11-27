package com.plentv.quest

import android.content.Intent
import android.os.Bundle

/**
 * The playback request handed from Dart to the native VR player (1.6.29).
 *
 * The keys match [VrPlayerRequest.toMap] on the Dart side
 * (lib/quest/vr_player_channel.dart) exactly — the plugin copies the
 * MethodChannel arguments into an Intent with these keys, and
 * [VrPlayerActivity] reads them back. Keep the two sides in sync.
 *
 * `layout` is one of `twoD` / `sbs` / `ou` / `vr180` / `vr360` / `auto`
 * (auto is resolved to the detected layout before the handoff, so the
 * native side only ever sees a concrete layout). `packing` is `half` or
 * `full`. `subtitleDepth` is `below` / `onScreen` / `follow`.
 * `screenLock` is `world` / `head`. `passthroughBrightness` is -100..100
 * (neutral 0). `refreshRate` is 72 / 90 / 120.
 */
data class VrPlayerRequest(
  val videoUrl: String,
  val layout: String,
  val packing: String,
  val swapEyes: Boolean,
  val screenSize: Double,
  val screenDistance: Double,
  val screenCurvature: Double,
  val depthSeparation: Double,
  val passthroughBrightness: Double,
  val autoDimPassthrough: Boolean,
  val foveatedRendering: Boolean,
  val dynamicResolution: Boolean,
  val refreshRate: Int,
  val spatialAudio: Boolean,
  val handTracking: Boolean,
  val cooperativeOverlay: Boolean,
  val subtitleDepth: String,
  val screenLock: String,
  val playbackSpeed: Double,
  val sleepTimerSeconds: Double,
  val startPositionSeconds: Double,
  val externalSubtitlePaths: List<String>,
  val title: String?,
) {
  companion object {
    const val EXTRA_VIDEO_URL = "videoUrl"
    const val EXTRA_LAYOUT = "layout"
    const val EXTRA_PACKING = "packing"
    const val EXTRA_SWAP_EYES = "swapEyes"
    const val EXTRA_SCREEN_SIZE = "screenSize"
    const val EXTRA_SCREEN_DISTANCE = "screenDistance"
    const val EXTRA_SCREEN_CURVATURE = "screenCurvature"
    const val EXTRA_DEPTH_SEPARATION = "depthSeparation"
    const val EXTRA_PASSTHROUGH_BRIGHTNESS = "passthroughBrightness"
    const val EXTRA_AUTO_DIM = "autoDimPassthrough"
    const val EXTRA_FOVEATED = "foveatedRendering"
    const val EXTRA_DYNAMIC_RESOLUTION = "dynamicResolution"
    const val EXTRA_REFRESH_RATE = "refreshRate"
    const val EXTRA_SPATIAL_AUDIO = "spatialAudio"
    const val EXTRA_HAND_TRACKING = "handTracking"
    const val EXTRA_COOPERATIVE_OVERLAY = "cooperativeOverlay"
    const val EXTRA_SUBTITLE_DEPTH = "subtitleDepth"
    const val EXTRA_SCREEN_LOCK = "screenLock"
    const val EXTRA_PLAYBACK_SPEED = "playbackSpeed"
    const val EXTRA_SLEEP_TIMER_SECONDS = "sleepTimerSeconds"
    const val EXTRA_START_POSITION = "startPositionSeconds"
    const val EXTRA_EXTERNAL_SUBTITLES = "externalSubtitlePaths"
    const val EXTRA_TITLE = "title"

    /** Where the VR session stopped, returned to Dart. */
    const val RESULT_POSITION_SECONDS = "positionSeconds"
    const val RESULT_COMPLETED = "completed"

    /**
     * Whether VR init succeeded (P0.4). False when init failed before any
     * frame — the panel must not seek to 0 on that result.
     */
    const val RESULT_STARTED = "started"

    /**
     * Why VR failed to start (P0.4/T2), as a stable reason code — 'egl' |
     * 'openxr' | 'actions' | 'mpv' | 'gl' from the render-thread init
     * chain, 'library_missing' | 'invalid_request' | 'already_running' |
     * 'start_failed' from the activity/start path. Absent when VR
     * started or when the failure predates the reason channel. The Dart
     * side maps the code to a localized message; unknown codes fall back
     * to the generic message.
     */
    const val RESULT_FAILURE_REASON = "failureReason"

    fun fromMap(map: Map<String, Any?>): VrPlayerRequest? {
      val videoUrl = map[EXTRA_VIDEO_URL] as? String
      if (videoUrl.isNullOrBlank()) return null
      @Suppress("UNCHECKED_CAST")
      val subtitles = (map[EXTRA_EXTERNAL_SUBTITLES] as? List<*>
        )?.filterIsInstance<String>() ?: emptyList()
      return VrPlayerRequest(
        videoUrl = videoUrl,
        // U5: a missing layout defaults to twoD (flat) everywhere — SBS
        // is the dangerous direction for a flat file shown split.
        layout = map[EXTRA_LAYOUT] as? String ?: "twoD",
        packing = map[EXTRA_PACKING] as? String ?: "half",
        swapEyes = map[EXTRA_SWAP_EYES] as? Boolean ?: false,
        screenSize = (map[EXTRA_SCREEN_SIZE] as? Number)?.toDouble() ?: 1.0,
        screenDistance = (map[EXTRA_SCREEN_DISTANCE] as? Number)?.toDouble() ?: 3.0,
        screenCurvature = (map[EXTRA_SCREEN_CURVATURE] as? Number)?.toDouble() ?: 0.0,
        depthSeparation = (map[EXTRA_DEPTH_SEPARATION] as? Number)?.toDouble() ?: 0.5,
        passthroughBrightness =
          (map[EXTRA_PASSTHROUGH_BRIGHTNESS] as? Number)?.toDouble() ?: 0.0,
        autoDimPassthrough = map[EXTRA_AUTO_DIM] as? Boolean ?: true,
        foveatedRendering = map[EXTRA_FOVEATED] as? Boolean ?: true,
        dynamicResolution = map[EXTRA_DYNAMIC_RESOLUTION] as? Boolean ?: true,
        refreshRate = (map[EXTRA_REFRESH_RATE] as? Number)?.toInt() ?: 90,
        spatialAudio = map[EXTRA_SPATIAL_AUDIO] as? Boolean ?: true,
        handTracking = map[EXTRA_HAND_TRACKING] as? Boolean ?: false,
        cooperativeOverlay = map[EXTRA_COOPERATIVE_OVERLAY] as? Boolean ?: true,
        subtitleDepth = map[EXTRA_SUBTITLE_DEPTH] as? String ?: "below",
        screenLock = map[EXTRA_SCREEN_LOCK] as? String ?: "world",
        playbackSpeed = (map[EXTRA_PLAYBACK_SPEED] as? Number)?.toDouble() ?: 1.0,
        sleepTimerSeconds =
          (map[EXTRA_SLEEP_TIMER_SECONDS] as? Number)?.toDouble() ?: 0.0,
        startPositionSeconds =
          (map[EXTRA_START_POSITION] as? Number)?.toDouble() ?: 0.0,
        externalSubtitlePaths = subtitles,
        title = map[EXTRA_TITLE] as? String,
      )
    }

    fun fromIntent(intent: Intent): VrPlayerRequest? {
      val extras = intent.extras ?: return null
      val videoUrl = extras.getString(EXTRA_VIDEO_URL)
      if (videoUrl.isNullOrBlank()) return null
      return VrPlayerRequest(
        videoUrl = videoUrl,
        // U5: same twoD default as fromMap (see above).
        layout = extras.getString(EXTRA_LAYOUT, "twoD"),
        packing = extras.getString(EXTRA_PACKING, "half"),
        swapEyes = extras.getBoolean(EXTRA_SWAP_EYES, false),
        screenSize = extras.getDouble(EXTRA_SCREEN_SIZE, 1.0),
        screenDistance = extras.getDouble(EXTRA_SCREEN_DISTANCE, 3.0),
        screenCurvature = extras.getDouble(EXTRA_SCREEN_CURVATURE, 0.0),
        depthSeparation = extras.getDouble(EXTRA_DEPTH_SEPARATION, 0.5),
        passthroughBrightness = extras.getDouble(EXTRA_PASSTHROUGH_BRIGHTNESS, 0.0),
        autoDimPassthrough = extras.getBoolean(EXTRA_AUTO_DIM, true),
        foveatedRendering = extras.getBoolean(EXTRA_FOVEATED, true),
        dynamicResolution = extras.getBoolean(EXTRA_DYNAMIC_RESOLUTION, true),
        refreshRate = extras.getInt(EXTRA_REFRESH_RATE, 90),
        spatialAudio = extras.getBoolean(EXTRA_SPATIAL_AUDIO, true),
        handTracking = extras.getBoolean(EXTRA_HAND_TRACKING, false),
        cooperativeOverlay = extras.getBoolean(EXTRA_COOPERATIVE_OVERLAY, true),
        subtitleDepth = extras.getString(EXTRA_SUBTITLE_DEPTH, "below"),
        screenLock = extras.getString(EXTRA_SCREEN_LOCK, "world"),
        playbackSpeed = extras.getDouble(EXTRA_PLAYBACK_SPEED, 1.0),
        sleepTimerSeconds = extras.getDouble(EXTRA_SLEEP_TIMER_SECONDS, 0.0),
        startPositionSeconds = extras.getDouble(EXTRA_START_POSITION, 0.0),
        externalSubtitlePaths =
          extras.getStringArrayList(EXTRA_EXTERNAL_SUBTITLES) ?: emptyList(),
        title = extras.getString(EXTRA_TITLE),
      )
    }
  }

  /** The Intent extras the activity reads. */
  fun toExtras(): Bundle {
    return Bundle().apply {
      putString(EXTRA_VIDEO_URL, videoUrl)
      putString(EXTRA_LAYOUT, layout)
      putString(EXTRA_PACKING, packing)
      putBoolean(EXTRA_SWAP_EYES, swapEyes)
      putDouble(EXTRA_SCREEN_SIZE, screenSize)
      putDouble(EXTRA_SCREEN_DISTANCE, screenDistance)
      putDouble(EXTRA_SCREEN_CURVATURE, screenCurvature)
      putDouble(EXTRA_DEPTH_SEPARATION, depthSeparation)
      putDouble(EXTRA_PASSTHROUGH_BRIGHTNESS, passthroughBrightness)
      putBoolean(EXTRA_AUTO_DIM, autoDimPassthrough)
      putBoolean(EXTRA_FOVEATED, foveatedRendering)
      putBoolean(EXTRA_DYNAMIC_RESOLUTION, dynamicResolution)
      putInt(EXTRA_REFRESH_RATE, refreshRate)
      putBoolean(EXTRA_SPATIAL_AUDIO, spatialAudio)
      putBoolean(EXTRA_HAND_TRACKING, handTracking)
      putBoolean(EXTRA_COOPERATIVE_OVERLAY, cooperativeOverlay)
      putString(EXTRA_SUBTITLE_DEPTH, subtitleDepth)
      putString(EXTRA_SCREEN_LOCK, screenLock)
      putDouble(EXTRA_PLAYBACK_SPEED, playbackSpeed)
      putDouble(EXTRA_SLEEP_TIMER_SECONDS, sleepTimerSeconds)
      putDouble(EXTRA_START_POSITION, startPositionSeconds)
      putStringArrayList(EXTRA_EXTERNAL_SUBTITLES, ArrayList(externalSubtitlePaths))
      putString(EXTRA_TITLE, title)
    }
  }
}
