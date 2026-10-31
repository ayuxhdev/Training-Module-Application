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
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.FilterInputStream
import java.io.InterruptedIOException
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    companion object {
        private const val REQUEST_CODE_PICK_VIDEO = 1001
    }

    private val leases = mutableSetOf<Int>()
    private var nextLease = 0
    private var wasSecure = false
    private var fullscreenLease: Int? = null
    private var previousOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    private var previousUi = 0
    private var statusVisible = true
    private var navigationVisible = true
    private var previousBarsBehavior = 0

    private var pendingPickerResult: MethodChannel.Result? = null
    private val backgroundExecutor = Executors.newSingleThreadExecutor()
    private val videoCopyLifecycle = VideoPickerCopyLifecycle()
    private var videoPickerChannel: MethodChannel? = null
    private var copyingVideo = false

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
                                previousOrientation = requestedOrientation
                                previousUi = window.decorView.systemUiVisibility
                                requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
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
                    if (pendingPickerResult != null || copyingVideo) {
                        result.error("ALREADY_ACTIVE", "A video selection is already in progress", null)
                        return@setMethodCallHandler
                    }
                    pendingPickerResult = result
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
                            pendingPickerResult = null
                            result.error("NO_ACTIVITY", "No application available to pick video files", ex.message)
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
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_CODE_PICK_VIDEO || !videoCopyLifecycle.isAlive()) return
        val pickerResult = pendingPickerResult ?: return
        pendingPickerResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            pickerResult.success(null)
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
                    videoCopyLifecycle.deliver(target) { pickerResult.success(response) }
                }
            } catch (e: Exception) {
                tempFile?.let { videoCopyLifecycle.abandon(it) }
                runOnUiThread {
                    copyingVideo = false
                    if (videoCopyLifecycle.isAlive()) {
                        pickerResult.error("STREAM_ERROR", e.message ?: "Failed to read selected video", null)
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        videoPickerChannel?.setMethodCallHandler(null)
        pendingPickerResult = null
        val cancelledInputs = videoCopyLifecycle.destroy()
        backgroundExecutor.shutdownNow()
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
        requestedOrientation = previousOrientation
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
