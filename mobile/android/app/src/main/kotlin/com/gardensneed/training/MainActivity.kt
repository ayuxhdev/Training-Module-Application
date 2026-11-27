package com.gardensneed.training

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Activity
import android.content.Intent
import android.content.pm.ActivityInfo
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.io.InputStream
import java.io.FilterInputStream
import java.io.InterruptedIOException
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val REQUEST_CODE_PICK_VIDEO = 1001
    }

    private val leases = mutableSetOf<Int>()
    private var nextLease = 0
    private var wasSecure = false
    private var fullscreenLease: Int? = null
    private val fullscreenOrientation = FullscreenOrientation()
    private var previousUi = 0
    private var statusVisible = true
    private var navigationVisible = true
    private var previousBarsBehavior = 0

    private val pendingPickerResult = VideoPickerPendingResult<MethodChannel.Result>()
    private val backgroundExecutor = Executors.newSingleThreadExecutor()
    private val videoCopyLifecycle = VideoPickerCopyLifecycle()
    private var videoPickerChannel: MethodChannel? = null
    private var copyingVideo = false

    private val pendingSaveResult = VideoPickerPendingResult<MethodChannel.Result>()
    private var pendingSavePayload: PendingSavePayload? = null
    private var fileSaverChannel: MethodChannel? = null
    private var savingFile = false
    private val saveDocumentLifecycle = DocumentSaveLifecycle()
    private var activeSaveSessionId: Long = 0L
    private var activeSaveRequestCode: Int = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gardensneed/protected_video")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        if (leases.isEmpty()) {
                            wasSecure = window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0
                            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        val lease = ++nextLease
                        leases.add(lease)
                        result.success(lease)
                    }
                    "release" -> {
                        val lease = call.arguments as? Int
                        if (fullscreenLease == lease) restoreFullscreen()
                        if (lease != null && leases.remove(lease) && leases.isEmpty() && !wasSecure) {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                        }
                        result.success(null)
                    }
                    "fullscreen" -> {
                        val lease = call.argument<Int>("lease")
                        if (lease == null || !leases.contains(lease)) {
                            result.error("invalid_lease", "Protected window is unavailable", null)
                        } else {
                            if (call.argument<Boolean>("enabled") == true && fullscreenLease == null) {
                                fullscreenLease = lease
                                previousUi = window.decorView.systemUiVisibility
                                val autoRotate = Settings.System.getInt(
                                    contentResolver, Settings.System.ACCELEROMETER_ROTATION, 0,
                                ) == 1
                                fullscreenOrientation.enter(autoRotate, requestedOrientation) {
                                    requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                                }
                                if (Build.VERSION.SDK_INT >= 30) {
                                    val insets = window.decorView.rootWindowInsets
                                    statusVisible = insets?.isVisible(WindowInsets.Type.statusBars()) ?: true
                                    navigationVisible = insets?.isVisible(WindowInsets.Type.navigationBars()) ?: true
                                    window.insetsController?.let {
                                        previousBarsBehavior = it.systemBarsBehavior
                                        it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                                        it.hide(WindowInsets.Type.systemBars())
                                    }
                                } else {
                                    window.decorView.systemUiVisibility = previousUi or
                                        View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                                        View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                                }
                            } else if (fullscreenLease == lease && call.argument<Boolean>("enabled") == false) {
                                restoreFullscreen()
                            }
                            result.success(null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        videoPickerChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gardensneed/video_picker")
        videoPickerChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "pickVideo" -> {
                    if (pendingPickerResult.isPending() || copyingVideo) {
                        result.error("ALREADY_ACTIVE", "A video selection is already in progress", null)
                        return@setMethodCallHandler
                    }
                    if (!pendingPickerResult.begin(result)) {
                        result.error("ALREADY_ACTIVE", "A video selection is already in progress", null)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "video/*"
                        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("video/mp4", "video/webm", "video/quicktime"))
                    }
                    try {
                        startActivityForResult(intent, REQUEST_CODE_PICK_VIDEO)
                    } catch (_: Exception) {
                        try {
                            val fallback = Intent(Intent.ACTION_GET_CONTENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "video/*"
                                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("video/mp4", "video/webm", "video/quicktime"))
                            }
                            startActivityForResult(fallback, REQUEST_CODE_PICK_VIDEO)
                        } catch (ex: Exception) {
                            pendingPickerResult.take()?.error(
                                "NO_ACTIVITY",
                                "No application available to pick video files",
                                ex.message,
                            )
                        }
                    }
                }
                "clearCache" -> {
                    backgroundExecutor.execute {
                        videoCopyLifecycle.clearCache(File(cacheDir, "video_picker"))
                        runOnUiThread {
                            if (videoCopyLifecycle.isAlive()) result.success(null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        fileSaverChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gardensneed/file_saver")
        fileSaverChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFile" -> {
                    if (pendingSaveResult.isPending() || savingFile) {
                        result.error("ALREADY_ACTIVE", "A file save operation is already in progress", null)
                        return@setMethodCallHandler
                    }

                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null || bytes.isEmpty()) {
                        result.error("INVALID_ARGUMENT", "File bytes cannot be null or empty", null)
                        return@setMethodCallHandler
                    }

                    val rawFilename = call.argument<String>("filename")
                    if (rawFilename.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "Filename cannot be empty", null)
                        return@setMethodCallHandler
                    }

                    val mimeType = call.argument<String>("mimeType") ?: "text/csv"
                    val sanitizedFilename = sanitizeSaveFilename(rawFilename)

                    if (!pendingSaveResult.begin(result)) {
                        result.error("ALREADY_ACTIVE", "A file save operation is already in progress", null)
                        return@setMethodCallHandler
                    }
                    val sessionId = nextSaveSessionId()
                    val requestCode = nextSaveRequestCode()
                    activeSaveSessionId = sessionId
                    activeSaveRequestCode = requestCode

                    if (!saveDocumentLifecycle.startPicker(sessionId, requestCode)) {
                        activeSaveSessionId = 0L
                        activeSaveRequestCode = 0
                        pendingSaveResult.take()?.error(
                            "ALREADY_ACTIVE",
                            "A file save operation is already in progress",
                            null,
                        )
                        return@setMethodCallHandler
                    }

                    pendingSavePayload = PendingSavePayload(bytes, sanitizedFilename, mimeType, sessionId, requestCode)

                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = mimeType
                        putExtra(Intent.EXTRA_TITLE, sanitizedFilename)
                    }

                    try {
                        startActivityForResult(intent, requestCode)
                    } catch (ex: Exception) {
                        saveDocumentLifecycle.reset()
                        pendingSavePayload = null
                        activeSaveSessionId = 0L
                        activeSaveRequestCode = 0
                        pendingSaveResult.take()?.error(
                            "NO_ACTIVITY",
                            "No application available to save file: ${ex.message}",
                            null,
                        )
                    }
                }
                "cancelSave" -> {
                    pendingSavePayload = null
                    if (saveDocumentLifecycle.isCompleted()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val cancelled = saveDocumentLifecycle.cancel()
                    if (!cancelled) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    if (!savingFile) {
                        val saveRes = pendingSaveResult.take()
                        // The picker was cancelled while still open; no document was created or deleted.
                        saveRes?.success(mapOf("status" to "cancelled", "cleanedUp" to false))
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (isSaveRequestCode(requestCode)) {
            // Stale or mismatched picker result from another save request or prior activity instance:
            // NEVER delete or write to an unowned/stale picker destination!
            if (requestCode != activeSaveRequestCode || activeSaveRequestCode == 0) {
                return
            }

            if (saveDocumentLifecycle.isCancelled() || !saveDocumentLifecycle.isPickerActive() || !pendingSaveResult.isPending()) {
                // Cancelled or inactive: reset lifecycle and drop unowned URI without deleting.
                saveDocumentLifecycle.reset()
                activeSaveSessionId = 0L
                activeSaveRequestCode = 0
                return
            }

            val payload = pendingSavePayload
            pendingSavePayload = null
            val expectedSessionId = activeSaveSessionId
            val expectedRequestCode = activeSaveRequestCode
            activeSaveSessionId = 0L
            activeSaveRequestCode = 0

            if (resultCode != Activity.RESULT_OK || data?.data == null || payload == null || payload.sessionId != expectedSessionId || payload.requestCode != expectedRequestCode) {
                // Dismissed/cancelled by user in picker, or mismatched payload. Drop without deleting.
                saveDocumentLifecycle.reset()
                pendingSaveResult.take()?.success(mapOf("status" to "cancelled", "cleanedUp" to false))
                return
            }

            val uri: Uri = data.data!!

            // Begin in WRITING phase. Because arbitrary SAF destination URIs have uncertain provenance,
            // canDeleteOnAbort is strictly false (fail-closed) to protect user documents.
            if (!saveDocumentLifecycle.begin(uri.toString(), canDeleteOnAbort = false, sessionId = expectedSessionId, requestCode = expectedRequestCode)) {
                pendingSaveResult.take()?.error(
                    "ALREADY_ACTIVE",
                    "A file save operation is already in progress",
                    null,
                )
                return
            }
            savingFile = true
            backgroundExecutor.execute {
                try {
                    val bytesWritten = writeCsvDocument(
                        payload.bytes,
                        openOutput = { contentResolver.openOutputStream(uri, "wt") },
                        checkActive = {
                            if (saveDocumentLifecycle.isCancelled() || !pendingSaveResult.isPending()) {
                                throw InterruptedIOException("CSV save was cancelled")
                            }
                        },
                    )

                    var displayName = payload.filename
                    try {
                        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            if (cursor.moveToFirst() && nameIndex != -1 && !cursor.isNull(nameIndex)) {
                                displayName = cursor.getString(nameIndex)
                            }
                        }
                    } catch (_: Exception) {}

                    if (saveDocumentLifecycle.isCancelled() || !pendingSaveResult.isPending()) {
                        throw InterruptedIOException("Save cancelled before commit")
                    }

                    // Commit: must succeed before reporting save success
                    val committed = saveDocumentLifecycle.complete(uri.toString(), expectedSessionId)
                    if (!committed) {
                        throw InterruptedIOException("Cancellation won before commit")
                    }

                    val response = mapOf(
                        "status" to "saved",
                        "path" to uri.toString(),
                        "displayName" to displayName,
                        "bytesWritten" to bytesWritten,
                    )
                    runOnUiThread {
                        savingFile = false
                        pendingSaveResult.take()?.success(response)
                    }
                } catch (e: Exception) {
                    val wasCancelled = saveDocumentLifecycle.isCancelled()
                    // Never delete uncertain SAF documents on abort.
                    saveDocumentLifecycle.abortAndCleanup(uri.toString()) { false }

                    val cleanupNote = "An incomplete file may remain at the selected destination."

                    runOnUiThread {
                        savingFile = false
                        val saveRes = pendingSaveResult.take()
                        if (saveRes != null) {
                            if (wasCancelled) {
                                saveRes.success(mapOf(
                                    "status" to "cancelled",
                                    "cleanedUp" to false,
                                    "message" to cleanupNote,
                                ))
                            } else {
                                saveRes.error(
                                    "WRITE_FAILED",
                                    "Failed to write CSV file: ${e.message ?: "I/O error"}. $cleanupNote",
                                    mapOf(
                                        "cleanedUp" to false,
                                        "errorMessage" to (e.message ?: "unknown"),
                                    ),
                                )
                            }
                        }
                    }
                }
            }
            return
        }
        if (requestCode != REQUEST_CODE_PICK_VIDEO || !videoCopyLifecycle.isAlive()) return
        val pickerResult = pendingPickerResult.peek() ?: return
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pendingPickerResult.take()?.success(null)
            return
        }

        val uri: Uri = data.data!!
        copyingVideo = true
        backgroundExecutor.execute {
            var tempFile: File? = null
            try {
                videoCopyLifecycle.checkActive()
                var displayName = "selected_video.mp4"
                contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                    val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (cursor.moveToFirst() && nameIndex != -1 && !cursor.isNull(nameIndex)) {
                        displayName = cursor.getString(nameIndex)
                    }
                }
                videoCopyLifecycle.checkActive()
                val sanitizedName = displayName.replace(Regex("[^a-zA-Z0-9._-]"), "_")
                val pickerDir = File(cacheDir, "video_picker").apply { mkdirs() }
                val target = File(pickerDir, "upload_${UUID.randomUUID()}_$sanitizedName")
                tempFile = target
                val size = videoCopyLifecycle.copy(target) {
                    contentResolver.openInputStream(uri)
                        ?: throw IOException("Could not open input stream for content URI")
                }
                val response = mapOf(
                    "path" to target.absolutePath,
                    "name" to displayName,
                    "size" to size,
                    "mimeType" to (contentResolver.getType(uri) ?: "video/mp4")
                )
                // The lifecycle retains ownership until this main-thread handoff.
                runOnUiThread {
                    copyingVideo = false
                    val result = pendingPickerResult.take()
                    if (result != null) {
                        videoCopyLifecycle.deliver(target) { result.success(response) }
                    } else {
                        videoCopyLifecycle.deliver(target) {}
                    }
                }
            } catch (e: Exception) {
                tempFile?.let { videoCopyLifecycle.abandon(it) }
                runOnUiThread {
                    copyingVideo = false
                    if (videoCopyLifecycle.isAlive()) {
                        pendingPickerResult.take()?.error(
                            "STREAM_ERROR",
                            e.message ?: "Failed to read selected video",
                            null,
                        )
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        videoPickerChannel?.setMethodCallHandler(null)
        fileSaverChannel?.setMethodCallHandler(null)
        val pendingResult = pendingPickerResult.destroy()
        val pendingSave = pendingSaveResult.destroy()
        pendingSavePayload = null
        activeSaveSessionId = 0L
        activeSaveRequestCode = 0
        savingFile = false
        val cancelledInputs = videoCopyLifecycle.destroy()
        val saveUriToCleanup = saveDocumentLifecycle.abortTarget(null)
        saveDocumentLifecycle.cancel()
        backgroundExecutor.shutdownNow()
        copyingVideo = false
        try {
            pendingResult?.success(null)
        } catch (_: Exception) {
            // The Flutter engine or messenger may already be detached during destruction.
        }
        try {
            pendingSave?.success(mapOf("status" to "cancelled"))
        } catch (_: Exception) {
            // Detached during destruction.
        }
        if (saveUriToCleanup != null) {
            Thread({
                deleteCreatedDocumentQuietly(Uri.parse(saveUriToCleanup))
            }, "csv-saver-cleanup").apply { isDaemon = true }.start()
        }
        // A provider's close() may block. Never perform it on Android's UI thread.
        if (cancelledInputs.isNotEmpty()) {
            Thread({
                cancelledInputs.forEach { input ->
                    try { input.close() } catch (_: Exception) {}
                }
            }, "video-picker-cancel").apply { isDaemon = true }.start()
        }
        super.onDestroy()
    }

    private fun restoreFullscreen() {
        if (fullscreenLease == null) return
        fullscreenOrientation.restore { requestedOrientation = it }
        if (Build.VERSION.SDK_INT >= 30) {
            window.insetsController?.let {
                it.systemBarsBehavior = previousBarsBehavior
                if (statusVisible) it.show(WindowInsets.Type.statusBars()) else it.hide(WindowInsets.Type.statusBars())
                if (navigationVisible) it.show(WindowInsets.Type.navigationBars()) else it.hide(WindowInsets.Type.navigationBars())
            }
        } else {
            window.decorView.systemUiVisibility = previousUi
        }
        fullscreenLease = null
    }

    /** Safely deletes an incomplete or failed SAF document without throwing. */
    private fun deleteCreatedDocumentQuietly(uri: Uri): Boolean {
        return try {
            android.provider.DocumentsContract.deleteDocument(contentResolver, uri)
        } catch (_: Exception) {
            false
        }
    }
}

/** Own files until their main-thread handoff; independent of Android for JVM regression tests. */
internal class VideoPickerCopyLifecycle {
    private val lock = Any()
    private var destroyed = false
    private val owned = mutableSetOf<File>()
    private val copying = mutableSetOf<File>()
    private val inputs = mutableMapOf<File, InputStream>()

    fun isAlive(): Boolean = synchronized(lock) { !destroyed }

    fun checkActive() {
        if (!isAlive() || Thread.currentThread().isInterrupted) {
            throw InterruptedIOException("Video selection cancelled")
        }
    }

    fun copy(file: File, openInput: () -> InputStream): Long {
        synchronized(lock) {
            checkActive()
            owned.add(file)
            copying.add(file)
        }
        var completed = false
        try {
            checkActive()
            val input = CloseOnceInputStream(openInput())
            var size = 0L
            input.use {
                synchronized(lock) {
                    checkActive()
                    inputs[file] = input
                }
                FileOutputStream(file).use { output ->
                    val buffer = ByteArray(65536)
                    while (true) {
                        checkActive()
                        val count = input.read(buffer)
                        checkActive()
                        if (count == -1) break
                        output.write(buffer, 0, count)
                        size += count
                    }
                }
            }
            checkActive()
            completed = true
            return size
        } finally {
            synchronized(lock) {
                inputs.remove(file)
                copying.remove(file)
                if (!completed || destroyed) {
                    owned.remove(file)
                    delete(file)
                }
            }
        }
    }

    fun deliver(file: File, callback: () -> Unit): Boolean = synchronized(lock) {
        if (destroyed || file !in owned || file in copying) return false
        var delivered = false
        try {
            callback()
            delivered = true
            true
        } finally {
            owned.remove(file)
            if (!delivered || destroyed) delete(file)
        }
    }

    fun abandon(file: File) = synchronized(lock) {
        if (file !in copying && owned.remove(file)) delete(file)
    }

    fun clearCache(directory: File) = synchronized(lock) {
        try {
            directory.listFiles()?.forEach { file -> if (file !in owned) delete(file) }
        } catch (_: Exception) {}
    }

    fun destroy(): List<InputStream> = synchronized(lock) {
        destroyed = true
        owned.filter { it !in copying }.forEach { file ->
            delete(file)
            owned.remove(file)
        }
        inputs.values.toList()
    }

    private fun delete(file: File) {
        try { file.delete() } catch (_: Exception) {}
    }

    private class CloseOnceInputStream(input: InputStream) : FilterInputStream(input) {
        private val closed = AtomicBoolean(false)
        override fun close() {
            if (closed.compareAndSet(false, true)) super.close()
        }
    }
}

/** Own a single native-to-Flutter result until one lifecycle owner completes it. */
internal class VideoPickerPendingResult<T> {
    private val lock = Any()
    private var pending: T? = null
    private var destroyed = false

    fun begin(result: T): Boolean = synchronized(lock) {
        if (destroyed || pending != null) return false
        pending = result
        true
    }

    fun peek(): T? = synchronized(lock) {
        if (destroyed) null else pending
    }

    fun take(): T? = synchronized(lock) {
        if (destroyed) return null
        val result = pending
        pending = null
        result
    }

    fun destroy(): T? = synchronized(lock) {
        destroyed = true
        val result = pending
        pending = null
        result
    }

    fun isPending(): Boolean = synchronized(lock) {
        !destroyed && pending != null
    }
}

internal const val REQUEST_CODE_SAVE_FILE_BASE = 2000
internal const val REQUEST_CODE_SAVE_FILE_MAX = 62000

private val saveSessionIdSequence = AtomicLong(1L)
private val saveRequestCodeSequence = AtomicInteger(REQUEST_CODE_SAVE_FILE_BASE)

internal fun nextSaveSessionId(): Long = saveSessionIdSequence.getAndIncrement()

internal fun nextSaveRequestCode(): Int {
    return saveRequestCodeSequence.getAndUpdate { current ->
        if (current >= REQUEST_CODE_SAVE_FILE_MAX) REQUEST_CODE_SAVE_FILE_BASE else current + 1
    }
}

internal fun isSaveRequestCode(code: Int): Boolean {
    return code in REQUEST_CODE_SAVE_FILE_BASE..REQUEST_CODE_SAVE_FILE_MAX
}

/** In-flight payload for pending CSV Save As operation. */
internal data class PendingSavePayload(
    val bytes: ByteArray,
    val filename: String,
    val mimeType: String,
    val sessionId: Long,
    val requestCode: Int,
)

/** Strips path traversal and unsafe characters, ensuring a safe filename ending with .csv. */
internal fun sanitizeSaveFilename(name: String): String {
    val base = name.substringAfterLast('/').substringAfterLast('\\').trim()
    val cleaned = base.replace(Regex("[\\\\/:*?\"<>|\\x00-\\x1F\\x7F]"), "_")
    return if (cleaned.isBlank()) {
        "assignment-report.csv"
    } else if (!cleaned.lowercase().endsWith(".csv")) {
        "$cleaned.csv"
    } else {
        cleaned
    }
}

/** Completes only after every byte, flush and close have succeeded. */
internal fun writeCsvDocument(
    bytes: ByteArray,
    openOutput: () -> OutputStream?,
    checkActive: () -> Unit = {},
): Int {
    fun ensureActive() {
        if (Thread.currentThread().isInterrupted) {
            throw InterruptedIOException("CSV write interrupted")
        }
        checkActive()
    }

    ensureActive()
    val output = openOutput() ?: throw IOException("Could not open CSV destination")
    var written = 0
    output.use {
        while (written < bytes.size) {
            ensureActive()
            val count = minOf(64 * 1024, bytes.size - written)
            it.write(bytes, written, count)
            written += count
        }
        ensureActive()
        it.flush()
        ensureActive()
    }
    ensureActive()
    return written
}

internal enum class SaveSessionState {
    IDLE,
    PICKER_ACTIVE,
    WRITING,
    COMPLETED,
    CANCELLED
}

/**
 * Tracks the exact newly created SAF document Uri and ensures that if writing fails,
 * is cancelled, or activity is destroyed before completion, the partial or empty file
 * is safely cleaned up, provided it was newly created and not a pre-existing user file.
 * Defaults strictly to canDelete = false (fail-closed) to protect user-owned documents.
 */
internal class DocumentSaveLifecycle {
    private val lock = Any()
    private var state: SaveSessionState = SaveSessionState.IDLE
    private var activeSessionId: Long = 0L
    private var activeRequestCode: Int = 0
    private var inFlightUri: String? = null
    private var canDelete: Boolean = false
    private var partialCleanupFailed: Boolean = false

    fun state(): SaveSessionState = synchronized(lock) { state }
    fun activeSessionId(): Long = synchronized(lock) { activeSessionId }
    fun activeRequestCode(): Int = synchronized(lock) { activeRequestCode }

    fun startPicker(sessionId: Long = 0L, requestCode: Int = 0): Boolean = synchronized(lock) {
        if (state == SaveSessionState.PICKER_ACTIVE || state == SaveSessionState.WRITING) return false
        state = SaveSessionState.PICKER_ACTIVE
        activeSessionId = if (sessionId != 0L) sessionId else (activeSessionId + 1)
        activeRequestCode = requestCode
        inFlightUri = null
        canDelete = false
        partialCleanupFailed = false
        true
    }

    fun begin(
        uri: String,
        canDeleteOnAbort: Boolean = false,
        sessionId: Long? = null,
        requestCode: Int? = null,
    ): Boolean = synchronized(lock) {
        if (sessionId != null && sessionId != activeSessionId) return false
        if (requestCode != null && requestCode != activeRequestCode) return false
        if (inFlightUri != null || state == SaveSessionState.WRITING || state == SaveSessionState.CANCELLED) return false
        state = SaveSessionState.WRITING
        inFlightUri = uri
        canDelete = canDeleteOnAbort
        partialCleanupFailed = false
        true
    }

    fun setCanDeleteOnAbort(allow: Boolean) = synchronized(lock) {
        canDelete = allow
    }

    fun complete(uri: String, sessionId: Long? = null): Boolean = synchronized(lock) {
        if (sessionId != null && sessionId != activeSessionId) return false
        if (inFlightUri == uri && state == SaveSessionState.WRITING) {
            state = SaveSessionState.COMPLETED
            inFlightUri = null
            true
        } else {
            false
        }
    }

    fun cancel(sessionId: Long? = null): Boolean = synchronized(lock) {
        if (sessionId != null && sessionId != activeSessionId) return false
        if (state == SaveSessionState.COMPLETED) {
            return false // Completed writes cannot be cancelled
        }
        if (state == SaveSessionState.IDLE) {
            return false
        }
        state = SaveSessionState.CANCELLED
        true
    }

    /**
     * Releases the lifecycle lock BEFORE invoking the potentially blocking deleteDocument callback.
     */
    fun abortAndCleanup(uri: String?, deleteDocument: (String) -> Boolean): Boolean {
        val (target, shouldDelete) = synchronized(lock) {
            val target = inFlightUri
            val shouldDelete = canDelete
            val wasWritingOrCancelled = (state == SaveSessionState.WRITING || state == SaveSessionState.CANCELLED)
            if (target != null && (uri == null || uri == target) && wasWritingOrCancelled) {
                inFlightUri = null
                state = SaveSessionState.IDLE
                Pair(target, shouldDelete)
            } else {
                Pair(null, false)
            }
        }
        if (target != null && shouldDelete) {
            val cleaned = try {
                deleteDocument(target)
            } catch (_: Exception) {
                false
            }
            if (!cleaned) {
                synchronized(lock) { partialCleanupFailed = true }
            }
            return cleaned
        }
        return false
    }

    /** Returns the target URI for asynchronous cleanup if safe to delete, then resets state. */
    fun abortTarget(uri: String?): String? = synchronized(lock) {
        val target = inFlightUri
        val shouldDelete = canDelete
        val wasWritingOrCancelled = (state == SaveSessionState.WRITING || state == SaveSessionState.CANCELLED)
        if (target != null && (uri == null || uri == target) && wasWritingOrCancelled) {
            inFlightUri = null
            state = SaveSessionState.IDLE
            if (shouldDelete) target else null
        } else {
            null
        }
    }

    fun reset() = synchronized(lock) {
        state = SaveSessionState.IDLE
        inFlightUri = null
        canDelete = false
        partialCleanupFailed = false
    }

    fun isInFlight(): Boolean = synchronized(lock) { inFlightUri != null || state == SaveSessionState.WRITING }
    fun isCompleted(): Boolean = synchronized(lock) { state == SaveSessionState.COMPLETED }
    fun isCancelled(): Boolean = synchronized(lock) { state == SaveSessionState.CANCELLED }
    fun isPickerActive(): Boolean = synchronized(lock) { state == SaveSessionState.PICKER_ACTIVE }
    fun canDeleteOnAbort(): Boolean = synchronized(lock) { canDelete }
    fun didPartialCleanupFail(): Boolean = synchronized(lock) { partialCleanupFailed }
}
