package com.plentv.app

import org.junit.Assert.assertEquals
import org.junit.Test

class CatalogSyncNotificationTextTest {

  @Test
  fun fetchingWithBytesShowsPercent() {
    assertEquals(
      "Live TV · downloading 42%",
      CatalogSyncNotificationText.build(
        type = "live",
        phase = "fetching",
        rows = 0,
        receivedBytes = 4200L,
        totalBytes = 10000L,
      ),
    )
  }

  @Test
  fun fetchingWithoutBytesShowsDownloading() {
    assertEquals(
      "Movies · downloading…",
      CatalogSyncNotificationText.build(
        type = "movie",
        phase = "fetching",
        rows = 0,
        receivedBytes = null,
        totalBytes = null,
      ),
    )
  }

  @Test
  fun percentIsClampedAtOneHundred() {
    // A resume overrun (already-downloaded bytes counted twice) must
    // never show 104%.
    assertEquals(
      "Series · downloading 100%",
      CatalogSyncNotificationText.build(
        type = "series",
        phase = "fetching",
        rows = 0,
        receivedBytes = 12000L,
        totalBytes = 10000L,
      ),
    )
  }

  @Test
  fun writingShowsRowCount() {
    assertEquals(
      "Live TV · saving 17885 rows…",
      CatalogSyncNotificationText.build(
        type = "live",
        phase = "writing",
        rows = 17885,
        receivedBytes = null,
        totalBytes = null,
      ),
    )
  }

  @Test
  fun doneAndSkippedHavePlainLabels() {
    assertEquals(
      "Movies · done",
      CatalogSyncNotificationText.build(
        type = "movie",
        phase = "done",
        rows = 27530,
        receivedBytes = null,
        totalBytes = null,
      ),
    )
    assertEquals(
      "Series · skipped",
      CatalogSyncNotificationText.build(
        type = "series",
        phase = "skipped",
        rows = 0,
        receivedBytes = null,
        totalBytes = null,
      ),
    )
  }

  @Test
  fun unknownTypeFallsBackToCatalog() {
    assertEquals(
      "Catalog · syncing…",
      CatalogSyncNotificationText.build(
        type = "",
        phase = "starting",
        rows = 0,
        receivedBytes = null,
        totalBytes = null,
      ),
    )
  }
}
