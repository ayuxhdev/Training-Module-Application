package com.gardensneed.training

/** Owns only orientation requests made by fullscreen. Immersive bars are independent. */
internal class FullscreenOrientation {
    private var previousRequest: Int? = null

    fun enter(autoRotate: Boolean, currentRequest: Int, requestLandscape: () -> Unit) {
        // A forced rotation can persist when released back to an unspecified
        // request under rotation lock. Leave the user's locked display alone.
        if (!autoRotate || previousRequest != null) return
        previousRequest = currentRequest
        requestLandscape()
    }

    fun restore(requestOrientation: (Int) -> Unit) {
        val original = previousRequest ?: return
        previousRequest = null
        requestOrientation(original)
    }
}
