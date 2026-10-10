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
    val youtube = AppEntry("com.google.android.youtube.tv", "Tv", "YouTube", true, system = true)
    val twitch = AppEntry("tv.twitch.android.app", "Tv", "Twitch", true)
    val browser = AppEntry("com.aengix.tvbrowser", "Main", "No BS", true)
    val internal = AppEntry("vendor.factory", "Tool", "Factory", true, system = true)
    val disabled = phoneOnly.copy(enabled = false)
    val helper = AppEntry("dev.vodik7.atvtoolsserver", "Main", "Helper", false)
    val curated = arrangeApps(listOf(youtube, twitch, browser, internal, disabled, helper), "home", Locale.US)
    check(curated.toSet() == setOf(youtube, twitch, browser)) {
        "Preinstalled YouTube must remain; system tools, disabled apps and helper must be hidden"
    }
    val defaults = initialFavorites(curated)
    check(defaults == listOf(youtube.packageName, twitch.packageName, browser.packageName))
    check(initialFavorites(listOf(phoneOnly)).isEmpty())
    check(favoriteApps(curated, defaults) == listOf(youtube, twitch, browser))
    check(favoriteApps(curated, emptyList()).isEmpty()) { "Removing every favorite must not reseed defaults" }
    check(favoriteApps(curated, listOf("missing", twitch.packageName, twitch.packageName)) == listOf(twitch))
    check(toggleFavorite(toggleFavorite(defaults, youtube.packageName), youtube.packageName) ==
        listOf(twitch.packageName, browser.packageName, youtube.packageName))
    check(searchApps(curated, "  yOuTuBe  ") == listOf(youtube))
    check(searchApps(listOf(phoneOnly), "брауз") == listOf(phoneOnly))
    check(searchApps(curated, "NO bs") == listOf(browser))
    check(searchApps(curated, "missing").isEmpty())
    check(searchApps(curated, " ") == curated)
    println("Catalog behavior checks passed")
}
