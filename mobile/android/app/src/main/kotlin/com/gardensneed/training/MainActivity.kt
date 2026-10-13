package com.gardensneed.training

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.pm.ActivityInfo
import android.os.Build
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager

class MainActivity : FlutterActivity() {
    private val leases = mutableSetOf<Int>()
    private var nextLease = 0
    private var wasSecure = false
    private var fullscreenLease: Int? = null
    private var previousOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
    private var previousUi = 0
    private var statusVisible = true
    private var navigationVisible = true
    private var previousBarsBehavior = 0

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
