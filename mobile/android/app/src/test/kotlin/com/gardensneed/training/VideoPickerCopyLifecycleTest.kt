package com.gardensneed.training

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** Dependency-free JVM tests; run with ../run_video_picker_lifecycle_tests.py. */
fun main() {
    var passed = 0
    fun scenario(name: String, test: (File) -> Unit) {
        val directory = Files.createTempDirectory("video-picker-test-").toFile()
        try {
            test(directory)
            passed++
            println("PASS: $name")
        } finally {
            check(directory.deleteRecursively())
        }
    }

    scenario("bounded successful copy, single handoff and claimed-file preservation") { directory ->
        val lifecycle = VideoPickerCopyLifecycle()
        val file = File(directory, "video.mp4")
        val bytes = ByteArray(150000) { (it % 256).toByte() }
        var closes = 0
        val input = object : ByteArrayInputStream(bytes) {
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                check(len <= 65536)
                return super.read(b, off, len)
            }
            override fun close() { closes++ }
        }
        check(lifecycle.copy(file) { input } == bytes.size.toLong())
        check(file.readBytes().contentEquals(bytes))
        check(closes == 1)
        var callbacks = 0
        check(lifecycle.deliver(file) { callbacks++ })
        check(!lifecycle.deliver(file) { callbacks++ })
        check(callbacks == 1)
        check(lifecycle.destroy().isEmpty())
        check(file.exists()) // Ownership already belongs to Flutter.
    }

    scenario("copy failure closes input and deletes partial output") { directory ->
        val lifecycle = VideoPickerCopyLifecycle()
        val file = File(directory, "partial.mp4")
        var closes = 0
        val input = object : InputStream() {
            var reads = 0
            override fun read(): Int = error("Use bounded reads")
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (reads++ == 0) { b[off] = 1; return 1 }
                throw IOException("Simulated provider failure")
            }
            override fun close() { closes++ }
        }
        try {
            lifecycle.copy(file) { input }
            error("Expected provider failure")
        } catch (_: IOException) {}
        check(closes == 1 && !file.exists())
        check(!lifecycle.deliver(file) { error("Unexpected callback") })
    }

    scenario("destruction during blocked copying cancels and cleans without callbacks") { directory ->
        val lifecycle = VideoPickerCopyLifecycle()
        val file = File(directory, "active.mp4")
        val reading = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>()
        var closes = 0
        val input = object : InputStream() {
            override fun read(): Int = error("Use bounded reads")
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                reading.countDown()
                check(closed.await(5, TimeUnit.SECONDS))
                throw IOException("Closed by cancellation")
            }
            override fun close() { closes++; closed.countDown() }
        }
        val worker = Thread {
            try { lifecycle.copy(file) { input } } catch (error: Throwable) { failure.set(error) }
        }
        worker.start()
        try {
            check(reading.await(5, TimeUnit.SECONDS))
            lifecycle.clearCache(directory)
            check(file.exists()) // Cache clearing cannot delete active output.
            lifecycle.destroy().forEach { it.close() }
        } finally {
            closed.countDown()
            worker.join(5000)
        }
        check(!worker.isAlive && failure.get() is IOException)
        check(closes == 1 && !file.exists())
        check(!lifecycle.deliver(file) { error("Callback after destruction") })
    }

    scenario("destruction between copy completion and UI handoff deletes unclaimed file") { directory ->
        val lifecycle = VideoPickerCopyLifecycle()
        val file = File(directory, "unclaimed.mp4")
        lifecycle.copy(file) { ByteArrayInputStream(byteArrayOf(1, 2)) }
        lifecycle.clearCache(directory)
        check(file.exists()) // Queued UI handoff still owns this file.
        lifecycle.destroy().forEach { it.close() }
        check(!file.exists())
        check(!lifecycle.deliver(file) { error("Callback after destruction") })
        check(lifecycle.destroy().isEmpty())
    }

    scenario("destroyed lifecycle refuses new file and input creation") { directory ->
        val lifecycle = VideoPickerCopyLifecycle()
        val file = File(directory, "never-created.mp4")
        lifecycle.destroy()
        try {
            lifecycle.copy(file) { error("Must not open provider") }
            error("Expected cancellation")
        } catch (_: InterruptedIOException) {}
        check(!file.exists())
    }

    scenario("interruption after read closes input and removes output") { directory ->
        val lifecycle = VideoPickerCopyLifecycle()
        val file = File(directory, "interrupted.mp4")
        var closes = 0
        try {
            lifecycle.copy(file) {
                object : ByteArrayInputStream(byteArrayOf(1)) {
                    override fun read(b: ByteArray, off: Int, len: Int): Int {
                        Thread.currentThread().interrupt()
                        return super.read(b, off, len)
                    }
                    override fun close() { closes++ }
                }
            }
            error("Expected interruption")
        } catch (_: InterruptedIOException) {
        } finally {
            Thread.interrupted() // Restore the test thread, not application state.
        }
        check(closes == 1 && !file.exists())
    }

    scenario("destruction during provider open closes the late input") { directory ->
        val lifecycle = VideoPickerCopyLifecycle()
        val file = File(directory, "late-input.mp4")
        val opening = CountDownLatch(1)
        val release = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>()
        var closes = 0
        val worker = Thread {
            try {
                lifecycle.copy(file) {
                    opening.countDown()
                    check(release.await(5, TimeUnit.SECONDS))
                    object : ByteArrayInputStream(byteArrayOf(1)) {
                        override fun close() { closes++ }
                    }
                }
            } catch (error: Throwable) { failure.set(error) }
        }
        worker.start()
        try {
            check(opening.await(5, TimeUnit.SECONDS))
            check(lifecycle.destroy().isEmpty())
        } finally {
            release.countDown()
            worker.join(5000)
        }
        check(!worker.isAlive && failure.get() is InterruptedIOException)
        check(closes == 1 && !file.exists())
    }

    scenario("failed handoff and post-copy failure discard only their own files") { directory ->
        val lifecycle = VideoPickerCopyLifecycle()
        val file = File(directory, "failed-handoff.mp4")
        val other = File(directory, "other.mp4").apply { writeText("preserve") }
        lifecycle.copy(file) { ByteArrayInputStream(byteArrayOf(1)) }
        try {
            lifecycle.deliver(file) { throw IOException("Delivery failed") }
            error("Expected failed handoff")
        } catch (_: IOException) {}
        check(!file.exists() && other.readText() == "preserve")
        lifecycle.copy(file) { ByteArrayInputStream(byteArrayOf(2)) }
        lifecycle.abandon(file)
        lifecycle.abandon(file)
        check(!file.exists() && other.exists())
    }
    println("Native picker lifecycle: $passed/$passed passed")
}
