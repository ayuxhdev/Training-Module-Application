package com.gardensneed.training

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InterruptedIOException
import java.io.OutputStream

private fun expectWriteFailure(type: Class<out Throwable>, block: () -> Unit) {
    var failure: Throwable? = null
    try {
        block()
    } catch (error: Throwable) {
        failure = error
    }
    check(type.isInstance(failure)) { "Expected ${type.simpleName}, got $failure" }
}

/** Dependency-free JVM tests for CSV file saver native helper logic. */
fun main() {
    var passed = 0
    fun scenario(name: String, test: () -> Unit) {
        test()
        passed++
        println("PASS: $name")
    }

    scenario("sanitizeSaveFilename preserves standard clean csv filename") {
        val input = "assignment-report-2026-11-16.csv"
        check(sanitizeSaveFilename(input) == "assignment-report-2026-11-16.csv")
    }

    scenario("sanitizeSaveFilename strips directory traversal paths") {
        check(sanitizeSaveFilename("../../etc/passwd.csv") == "passwd.csv")
        check(sanitizeSaveFilename("..\\..\\Windows\\System32\\report.csv") == "report.csv")
        check(sanitizeSaveFilename("/sdcard/Download/report.csv") == "report.csv")
    }

    scenario("sanitizeSaveFilename replaces illegal filesystem characters and control chars") {
        val illegal = "report:*?\"<>|test.csv"
        val sanitized = sanitizeSaveFilename(illegal)
        check(!sanitized.contains(':') && !sanitized.contains('*') && !sanitized.contains('?'))
        check(!sanitized.contains('"') && !sanitized.contains('<') && !sanitized.contains('>'))
        check(!sanitized.contains('|'))
        check(sanitized.endsWith(".csv"))
    }

    scenario("sanitizeSaveFilename appends .csv extension if omitted") {
        check(sanitizeSaveFilename("monthly_summary") == "monthly_summary.csv")
    }

    scenario("sanitizeSaveFilename defaults blank name to assignment-report.csv") {
        check(sanitizeSaveFilename("") == "assignment-report.csv")
        check(sanitizeSaveFilename("   ") == "assignment-report.csv")
    }

    scenario("pending save result completes exactly once and rejects concurrent duplicate begin") {
        val pending = VideoPickerPendingResult<String>()
        check(pending.begin("first-save-request"))
        check(!pending.begin("duplicate-concurrent-request")) // ALREADY_ACTIVE guard
        check(pending.isPending())
        check(pending.peek() == "first-save-request")
        check(pending.take() == "first-save-request")
        check(pending.peek() == null)
        check(!pending.isPending())
    }

    scenario("pending save result resolves on activity destruction") {
        val pending = VideoPickerPendingResult<String>()
        check(pending.begin("in-flight-save"))
        check(pending.destroy() == "in-flight-save")
        check(pending.take() == null)
        check(!pending.begin("after-destroy-request"))
    }

    scenario("null output stream fails without reporting a completed write") {
        var completed = false
        expectWriteFailure(IOException::class.java) {
            writeCsvDocument(byteArrayOf(1, 2, 3), openOutput = { null })
            completed = true
        }
        check(!completed)
    }

    scenario("success requires complete bytes, flush and close") {
        var flushed = false
        var closed = false
        val output = object : ByteArrayOutputStream() {
            override fun flush() { flushed = true }
            override fun close() { closed = true }
        }
        val bytes = ByteArray(150000) { (it % 127).toByte() }
        val count = writeCsvDocument(bytes, openOutput = { output })
        check(count == bytes.size)
        check(output.toByteArray().contentEquals(bytes))
        check(flushed && closed)
    }

    scenario("write exception closes stream and cannot report success") {
        var closed = false
        val output = object : OutputStream() {
            override fun write(value: Int) { throw IOException("Test write failure") }
            override fun close() { closed = true }
        }
        expectWriteFailure(IOException::class.java) {
            writeCsvDocument(byteArrayOf(1), openOutput = { output })
        }
        check(closed)
    }

    scenario("flush failure still closes stream and cannot report success") {
        var closed = false
        val output = object : ByteArrayOutputStream() {
            override fun flush() { throw IOException("Test flush failure") }
            override fun close() { closed = true }
        }
        expectWriteFailure(IOException::class.java) {
            writeCsvDocument(byteArrayOf(1), openOutput = { output })
        }
        check(closed)
    }

    scenario("close failure cannot report success after writing and flushing") {
        var flushed = false
        val output = object : ByteArrayOutputStream() {
            override fun flush() { flushed = true }
            override fun close() { throw IOException("Test close failure") }
        }
        expectWriteFailure(IOException::class.java) {
            writeCsvDocument(byteArrayOf(1), openOutput = { output })
        }
        check(flushed)
    }

    scenario("destination permission denial propagates as failure") {
        expectWriteFailure(SecurityException::class.java) {
            writeCsvDocument(byteArrayOf(1), openOutput = { throw SecurityException("Denied") })
        }
    }

    scenario("cancellation before opening does not touch a destination") {
        var opened = false
        expectWriteFailure(InterruptedIOException::class.java) {
            writeCsvDocument(byteArrayOf(1), openOutput = {
                opened = true
                ByteArrayOutputStream()
            }, checkActive = { throw InterruptedIOException("Cancelled") })
        }
        check(!opened)
    }

    scenario("activity destruction during writing stops further chunks and closes output") {
        val pending = VideoPickerPendingResult<String>()
        check(pending.begin("csv-save"))
        var closed = false
        val output = object : ByteArrayOutputStream() {
            override fun write(bytes: ByteArray, offset: Int, count: Int) {
                super.write(bytes, offset, count)
                check(pending.destroy() == "csv-save")
            }
            override fun close() { closed = true }
        }
        expectWriteFailure(InterruptedIOException::class.java) {
            writeCsvDocument(ByteArray(150000), openOutput = { output }, checkActive = {
                if (!pending.isPending()) throw InterruptedIOException("Destroyed")
            })
        }
        check(closed)
        check(output.size() == 64 * 1024)
        check(pending.take() == null)
    }

    scenario("DocumentSaveLifecycle tracks in-flight URI and rejects concurrent begin") {
        val lifecycle = DocumentSaveLifecycle()
        check(!lifecycle.isInFlight())
        check(lifecycle.begin("content://com.android.providers.downloads/101"))
        check(lifecycle.isInFlight())
        check(!lifecycle.isCompleted())
        check(!lifecycle.begin("content://com.android.providers.downloads/102"))
    }

    scenario("DocumentSaveLifecycle complete protects successful document from deletion") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/202"
        check(lifecycle.begin(uri))
        check(lifecycle.complete(uri))
        check(!lifecycle.isInFlight())
        check(lifecycle.isCompleted())

        var deletedUri: String? = null
        val cleaned = lifecycle.abortAndCleanup(uri) { target ->
            deletedUri = target
            true
        }
        check(!cleaned)
        check(deletedUri == null)
    }

    scenario("DocumentSaveLifecycle abortAndCleanup deletes in-flight document on failure") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/303"
        check(lifecycle.begin(uri, canDeleteOnAbort = true))

        var deletedUri: String? = null
        val cleaned = lifecycle.abortAndCleanup(uri) { target ->
            deletedUri = target
            true
        }
        check(cleaned)
        check(deletedUri == uri)
        check(!lifecycle.isInFlight())
        check(!lifecycle.isCompleted())
    }

    scenario("DocumentSaveLifecycle never deletes unrelated URI") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/404"
        check(lifecycle.begin(uri, canDeleteOnAbort = true))

        var deletedUri: String? = null
        val cleaned = lifecycle.abortAndCleanup("content://unrelated/999") { target ->
            deletedUri = target
            true
        }
        check(!cleaned)
        check(deletedUri == null)
        check(lifecycle.isInFlight())
    }

    scenario("DocumentSaveLifecycle onDestroy abortAndCleanup deletes in-flight document with null uri") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/505"
        check(lifecycle.begin(uri, canDeleteOnAbort = true))

        var deletedUri: String? = null
        val cleaned = lifecycle.abortAndCleanup(null) { target ->
            deletedUri = target
            true
        }
        check(cleaned)
        check(deletedUri == uri)
        check(!lifecycle.isInFlight())
    }

    scenario("DocumentSaveLifecycle suppresses delete callback exceptions safely") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/606"
        check(lifecycle.begin(uri, canDeleteOnAbort = true))

        val cleaned = lifecycle.abortAndCleanup(uri) {
            throw UnsupportedOperationException("Provider does not support delete")
        }
        check(!cleaned)
        check(!lifecycle.isInFlight())
    }

    scenario("DocumentSaveLifecycle provenance guard protects pre-existing document from deletion") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/707"
        // canDeleteOnAbort = false simulates initialSize > 0 (user selected existing file)
        check(lifecycle.begin(uri, canDeleteOnAbort = false))
        check(!lifecycle.canDeleteOnAbort())

        var attemptedDelete = false
        val cleaned = lifecycle.abortAndCleanup(uri) {
            attemptedDelete = true
            true
        }
        check(!cleaned)
        check(!attemptedDelete)
        check(!lifecycle.isInFlight())
    }

    scenario("DocumentSaveLifecycle abortTarget returns URI only when canDeleteOnAbort is true") {
        val lifecycleProtected = DocumentSaveLifecycle()
        val uriProtected = "content://com.android.providers.downloads/808"
        check(lifecycleProtected.begin(uriProtected, canDeleteOnAbort = false))
        check(lifecycleProtected.abortTarget(null) == null)
        check(!lifecycleProtected.isInFlight())

        val lifecycleNew = DocumentSaveLifecycle()
        val uriNew = "content://com.android.providers.downloads/909"
        check(lifecycleNew.begin(uriNew, canDeleteOnAbort = true))
        check(lifecycleNew.abortTarget(null) == uriNew)
        check(!lifecycleNew.isInFlight())
    }

    scenario("DocumentSaveLifecycle startPicker transitions to PICKER_ACTIVE and cancel transitions to CANCELLED") {
        val lifecycle = DocumentSaveLifecycle()
        check(lifecycle.state() == SaveSessionState.IDLE)
        check(lifecycle.startPicker())
        check(lifecycle.isPickerActive())
        check(lifecycle.state() == SaveSessionState.PICKER_ACTIVE)
        check(!lifecycle.startPicker())
        check(lifecycle.cancel())
        check(lifecycle.isCancelled())
        check(!lifecycle.isPickerActive())
    }

    scenario("DocumentSaveLifecycle cancellation during active picker rejects begin on late onActivityResult") {
        val lifecycle = DocumentSaveLifecycle()
        check(lifecycle.startPicker())
        check(lifecycle.cancel())
        check(!lifecycle.begin("content://com.android.providers.downloads/1001"))
        check(lifecycle.isCancelled())
    }

    scenario("DocumentSaveLifecycle complete protects completed write from subsequent cancel") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/1002"
        check(lifecycle.startPicker())
        check(lifecycle.begin(uri, canDeleteOnAbort = true))
        check(lifecycle.complete(uri))
        check(lifecycle.isCompleted())
        check(!lifecycle.cancel())
        check(lifecycle.isCompleted())
        var attemptedDelete = false
        val cleaned = lifecycle.abortAndCleanup(uri) {
            attemptedDelete = true
            true
        }
        check(!cleaned)
        check(!attemptedDelete)
    }

    scenario("DocumentSaveLifecycle cancel during writing triggers cleanup on abortAndCleanup") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/1003"
        check(lifecycle.begin(uri, canDeleteOnAbort = true))
        check(lifecycle.cancel())
        check(lifecycle.isCancelled())
        var deletedUri: String? = null
        val cleaned = lifecycle.abortAndCleanup(uri) { target ->
            deletedUri = target
            true
        }
        check(cleaned)
        check(deletedUri == uri)
        check(!lifecycle.isInFlight())
    }

    scenario("DocumentSaveLifecycle cancel when IDLE returns false") {
        val lifecycle = DocumentSaveLifecycle()
        check(!lifecycle.cancel())
        check(lifecycle.state() == SaveSessionState.IDLE)
    }

    scenario("DocumentSaveLifecycle abortTarget returns URI when cancelled during writing") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/1004"
        check(lifecycle.begin(uri, canDeleteOnAbort = true))
        check(lifecycle.cancel())
        check(lifecycle.abortTarget(null) == uri)
        check(!lifecycle.isInFlight())
    }

    scenario("DocumentSaveLifecycle abortAndCleanup releases lock before calling deleteDocument") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/2001"
        check(lifecycle.startPicker(1L))
        check(lifecycle.begin(uri, canDeleteOnAbort = true, sessionId = 1L))

        var lockAcquiredDuringDelete = false
        val cleaned = lifecycle.abortAndCleanup(uri) {
            // Verify that calling a synchronized method on lifecycle while deleteDocument is running does not deadlock
            lockAcquiredDuringDelete = (lifecycle.state() == SaveSessionState.IDLE)
            true
        }
        check(cleaned)
        check(lockAcquiredDuringDelete)
    }

    scenario("DocumentSaveLifecycle tracks partial-file cleanup failure truthfully") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/2002"
        check(lifecycle.startPicker(2L))
        check(lifecycle.begin(uri, canDeleteOnAbort = true, sessionId = 2L))
        check(lifecycle.cancel(2L))

        val cleaned = lifecycle.abortAndCleanup(uri) {
            false // simulated deletion failure (e.g. DocumentProvider refusal)
        }
        check(!cleaned)
        check(lifecycle.didPartialCleanupFail())
    }

    scenario("DocumentSaveLifecycle ties picker and completion to exact sessionId") {
        val lifecycle = DocumentSaveLifecycle()
        check(lifecycle.startPicker(10L))
        check(lifecycle.activeSessionId() == 10L)

        // Session 9 (stale/earlier) is rejected
        check(!lifecycle.begin("content://test/stale", canDeleteOnAbort = true, sessionId = 9L))

        // Session 10 (active) is accepted
        val uri = "content://test/active"
        check(lifecycle.begin(uri, canDeleteOnAbort = true, sessionId = 10L))

        // Stale completion rejected
        check(!lifecycle.complete(uri, sessionId = 9L))

        // Active completion accepted
        check(lifecycle.complete(uri, sessionId = 10L))
        check(lifecycle.isCompleted())
    }

    scenario("DocumentSaveLifecycle cancellation wins before commit prevents completion") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/2003"
        check(lifecycle.startPicker(3L))
        check(lifecycle.begin(uri, canDeleteOnAbort = true, sessionId = 3L))

        // Cancellation arrives immediately before commit
        check(lifecycle.cancel(3L))
        check(lifecycle.isCancelled())

        // Background thread attempts commit: must be rejected!
        check(!lifecycle.complete(uri, sessionId = 3L))
        check(!lifecycle.isCompleted())

        // Abort and cleanup removes partial file
        var deleted = false
        check(lifecycle.abortAndCleanup(uri) { deleted = true; true })
        check(deleted)
    }

    scenario("MainActivity request code helpers generate unique non-colliding sequential request codes") {
        val code1 = nextSaveRequestCode()
        val code2 = nextSaveRequestCode()
        check(isSaveRequestCode(code1))
        check(isSaveRequestCode(code2))
        check(code1 != code2)
        check(code2 == code1 + 1)
        check(!isSaveRequestCode(1001)) // video picker code
        check(!isSaveRequestCode(1999))
        check(!isSaveRequestCode(63000))
    }

    scenario("DocumentSaveLifecycle handles duplicate cancellation requests idempotently") {
        val lifecycle = DocumentSaveLifecycle()
        check(lifecycle.startPicker(4L))
        check(lifecycle.cancel(4L))
        check(lifecycle.isCancelled())
        // Second cancel while CANCELLED returns true (already cancelled)
        check(lifecycle.cancel(4L))
        check(lifecycle.isCancelled())
    }

    scenario("DocumentSaveLifecycle provenance guard protects non-empty document from deletion on abort") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/2004"
        check(lifecycle.startPicker(5L))
        check(lifecycle.begin(uri, canDeleteOnAbort = false, sessionId = 5L))

        var deleteAttempted = false
        val cleaned = lifecycle.abortAndCleanup(uri) {
            deleteAttempted = true
            true
        }
        check(!cleaned)
        check(!deleteAttempted)
    }

    scenario("DocumentSaveLifecycle defaults canDeleteOnAbort to false to protect uncertain documents") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/uncertain"
        check(lifecycle.startPicker(6L))
        check(lifecycle.begin(uri, sessionId = 6L)) // default canDeleteOnAbort = false
        check(!lifecycle.canDeleteOnAbort())

        var deleteAttempted = false
        val cleaned = lifecycle.abortAndCleanup(uri) {
            deleteAttempted = true
            true
        }
        check(!cleaned)
        check(!deleteAttempted)
        check(lifecycle.abortTarget(null) == null)
    }

    scenario("DocumentSaveLifecycle rejects mismatched requestCode on begin") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/mismatched"
        check(lifecycle.startPicker(sessionId = 7L, requestCode = 2050))
        check(lifecycle.activeSessionId() == 7L)
        check(lifecycle.activeRequestCode() == 2050)

        // Mismatched request code from stale picker or prior activity instance is rejected
        check(!lifecycle.begin(uri, sessionId = 7L, requestCode = 2049))
        check(lifecycle.state() == SaveSessionState.PICKER_ACTIVE)

        // Matching request code and session ID is accepted
        check(lifecycle.begin(uri, sessionId = 7L, requestCode = 2050))
        check(lifecycle.state() == SaveSessionState.WRITING)
    }

    scenario("Process-wide session IDs increment monotonically across instances") {
        val s1 = nextSaveSessionId()
        val s2 = nextSaveSessionId()
        check(s2 > s1)
    }

    scenario("Failed write with uncertain ownership preserves destination without deletion") {
        val lifecycle = DocumentSaveLifecycle()
        val uri = "content://com.android.providers.downloads/preserve_user_doc"
        check(lifecycle.startPicker(sessionId = 8L, requestCode = 2060))
        check(lifecycle.begin(uri, canDeleteOnAbort = false, sessionId = 8L, requestCode = 2060))

        var deletionCalled = false
        val cleaned = lifecycle.abortAndCleanup(uri) {
            deletionCalled = true
            true
        }
        check(!cleaned)
        check(!deletionCalled)
        check(!lifecycle.didPartialCleanupFail())
    }

    println("All $passed CsvSaverLifecycleTest scenarios passed successfully.")
}
