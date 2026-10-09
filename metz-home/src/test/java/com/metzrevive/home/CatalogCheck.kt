package com.metzrevive.home

import java.util.Locale

fun main() {
    val mobile = AppEntry("video", "Mobile", "Видео", false)
    val tv = AppEntry("video", "Tv", "Видео", true)
    val phoneOnly = AppEntry("phone", "Main", "Браузер", false)
    val own = AppEntry("home", "Home", "METZ Home", true)
    val candidates = listOf(mobile, own, phoneOnly, tv, tv)
    val result = arrangeApps(candidates, "home", Locale.forLanguageTag("ru"))
    check(result == listOf(phoneOnly, tv)) { "TV preference, deduplication or self-exclusion failed" }
    check(arrangeApps(candidates.reversed(), "home", Locale.forLanguageTag("ru")) == result) {
        "Package query order must not affect the grid"
    }
    val ties = listOf(AppEntry("z", "B", "Same", true), AppEntry("a", "A", "Same", true))
    check(arrangeApps(ties, "home", Locale.US).map { it.packageName } == listOf("a", "z"))
    check(arrangeApps(emptyList(), "home", Locale.US).isEmpty())
    check(arrangeApps(listOf(mobile), "home", Locale.US) == listOf(mobile)) {
        "A mobile-only app must remain launchable"
    }
    println("Catalog behavior checks passed")
}
