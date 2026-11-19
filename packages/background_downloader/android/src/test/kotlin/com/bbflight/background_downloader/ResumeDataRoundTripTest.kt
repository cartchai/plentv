package com.bbflight.background_downloader

import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * 1.4.61 F7 — the resume record the timeout branch stores must survive its
 * prefs round-trip faithfully.
 *
 * SCOPE, stated honestly: this is the best test the JVM seam allows. The
 * timeout branch itself (DownloadTaskRunner.process()) cannot be driven
 * here — it needs Android framework classes (Uri, PreferenceManager,
 * QueueService/MethodChannel, WorkManager) and there is no Robolectric in
 * the test deps (only junit 4.13.2 + kotlinx-coroutines-test; the existing
 * tests are pure JVM, e.g. RunHandoffTest, TransferBytesTest). So this
 * test proves the record F1 now leaves usable — task id, byte offset and
 * ETag — round-trips through the exact JSON the handoff stores in prefs
 * (RunHandoff.store / take). The branch behaviour itself (partial kept,
 * second run reports "Resuming" and continues past the offset) is proven
 * on a device: Matt's phone is the downloads tester for 1.4.61. Kotlin
 * compile proof is CI — local Gradle builds are effectively impossible
 * here.
 *
 * Why this matters for the 1.4.6 failure: the timeout handler stored
 * resume data pointing at a file cleanup() had already deleted. F1 leaves
 * the partial in place, so the stored offset is now a real resume point —
 * but only if the stored record itself is faithful. A record that lost
 * its offset or ETag would resume from the wrong byte or fail the 206
 * gate and start from 0% again, the exact symptom on Matt's phone.
 */
class ResumeDataRoundTripTest {

    private fun taskFor(id: String) = Task(
        taskId = id,
        url = "https://example.test/video.mp4",
        filename = "video.mp4",
        headers = mapOf(),
        baseDirectory = BaseDirectory.applicationDocuments,
        group = "default",
        updates = Updates.status,
        taskType = "DownloadTask",
    )

    @Test
    fun resumeDataRoundTripsWithOffsetAndETag() {
        // The shape of Matt's case at the 120 s timeout: 58% of the file
        // transferred, strong ETag on the Range answer.
        val stored = ResumeData(
            task = taskFor("pleztv-dl-test"),
            data = "/storage/downloads/video.mp4",
            requiredStartByte = 58123456L,
            eTag = "\"abc123\"",
        )
        val json = bdJson.encodeToString(stored)
        val decoded = bdJson.decodeFromString<ResumeData>(json)

        assertEquals("pleztv-dl-test", decoded.task.taskId)
        assertEquals("/storage/downloads/video.mp4", decoded.data)
        assertEquals(58123456L, decoded.requiredStartByte)
        assertEquals("\"abc123\"", decoded.eTag)
    }

    @Test
    fun resumeDataRoundTripsWithoutETag() {
        // The plain-200 shape: no ETag on the response, so the record
        // carries null — the resume run must still know the exact offset.
        val stored = ResumeData(
            task = taskFor("pleztv-dl-no-etag"),
            data = "/storage/downloads/video.mp4",
            requiredStartByte = 1234567L,
            eTag = null,
        )
        val decoded = bdJson.decodeFromString<ResumeData>(
            bdJson.encodeToString(stored),
        )

        assertEquals(1234567L, decoded.requiredStartByte)
        assertNull(decoded.eTag)
    }

    @Test
    fun resumeDataDecodesLenientlyWithUnknownKeys() {
        // A record written by a newer/older build must still decode: the
        // handoff map is read on every run, and a strict decode would drop
        // the resume point entirely.
        val json = "{\"task\":{\"taskId\":\"pleztv-dl-test\",\"url\":\"https://example.test/video.mp4\",\"filename\":\"video.mp4\",\"headers\":{},\"baseDirectory\":0,\"group\":\"default\",\"updates\":1,\"taskType\":\"DownloadTask\",\"unknownTaskField\":1},\"data\":\"/storage/downloads/video.mp4\",\"requiredStartByte\":999,\"eTag\":null,\"unknownField\":\"x\"}"
        val decoded = bdJson.decodeFromString<ResumeData>(json)

        assertEquals("pleztv-dl-test", decoded.task.taskId)
        assertEquals(999L, decoded.requiredStartByte)
    }
}
