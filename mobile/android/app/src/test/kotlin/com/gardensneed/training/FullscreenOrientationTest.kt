package com.gardensneed.training

/** Standalone JVM regressions. No Android activity or device is required. */
fun main() {
    val orientation = FullscreenOrientation()
    val requests = mutableListOf<Int>()
    val unspecified = -1
    val portrait = 1
    val landscape = 6

    orientation.enter(false, unspecified) { requests.add(landscape) }
    orientation.restore { requests.add(it) }
    check(requests.isEmpty())
    println("PASS: fullscreen leaves a rotation-locked display and its request alone")

    orientation.enter(true, unspecified) { requests.add(landscape) }
    orientation.enter(true, landscape) { requests.add(landscape) }
    orientation.restore { requests.add(it) }
    orientation.restore { requests.add(it) }
    check(requests == listOf(landscape, unspecified))
    println("PASS: auto-rotate enters landscape and restores the original policy exactly once")

    requests.clear()
    orientation.enter(true, portrait) { requests.add(landscape) }
    orientation.restore { requests.add(it) }
    check(requests == listOf(landscape, portrait))
    println("PASS: a later fullscreen lease restores its own explicit orientation policy")
    println("3 fullscreen orientation tests passed")
}
