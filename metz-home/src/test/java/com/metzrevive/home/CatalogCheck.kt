package com.metzrevive.home

import java.util.Locale

fun main() {
    check(HomeAppearance().valid())
    check(!HomeAppearance(order = "HOME,HOME,SETTINGS").valid())
    check(!HomeAppearance(columns = 7).valid())
    for (columns in 4..6) {
        val entries = (0..26).map { AppEntry("pkg$it", "Main", "Item$it", true) }
        check((0 until pageCount(entries.size, columns)).flatMap { appSlice(entries, it, columns) } == entries)
        check(pageEntryIndex(columns + 1, columns * 2, true, columns) == columns)
        check(pageEntryIndex(columns + 1, columns + 2, false, columns) == columns + 1)
    }

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
    val paged = (0 until 12).map { AppEntry("app$it", "Main", "$it", true) }
    check(pageCount(0) == 0 && pageCount(10) == 1 && pageCount(11) == 2)
    check((0 until pageCount(paged.size)).flatMap { appSlice(paged, it) } == paged)
    check(appSlice(paged, 1).size == 2 && appSlice(paged, -1).isEmpty() && appSlice(paged, 2).isEmpty())
    check(pageEntryIndex(4, 10, true) == 0 && pageEntryIndex(9, 10, true) == 5)
    check(pageEntryIndex(5, 7, false) == 6 && pageEntryIndex(9, 2, true) == 0)
    check(pageEntryIndex(0, 0, false) == -1)
    check(moveFavorite(listOf("a", "missing", "b"), "b", -1) == listOf("a", "b", "missing"))
    check(moveFavorite(listOf("a", "b"), "a", -1) == listOf("a", "b"))
    check(moveFavorite(listOf("a", "b"), "unknown", 1) == listOf("a", "b"))
    val display = AppEntry("com.metzrevive.display", "ReceiverActivity", "METZ Display", true)
    check(arrangeApps(listOf(display), "com.metzrevive.home", Locale.US) == listOf(display))
    val dialog = DialogConfirmGate(100L)
    check(dialog.consume(100L, true, 1)) { "Opening hold repeat must not select a menu item" }
    check(dialog.consume(100L, true, 0)) { "Opening gesture stays blocked even if repeat count resets" }
    check(dialog.consume(100L, false, 0)) { "Releasing the opening hold must not select a menu item" }
    check(!dialog.consume(200L, true, 0) && !dialog.consume(200L, false, 0)) {
        "A fresh press and release must select normally"
    }
    check(dialog.consume(300L, false, 0)) { "An orphan release must not select" }
    check(dialog.consume(400L, true, 2) && dialog.consume(400L, false, 0))
    check(!dialog.consume(500L, true, 0) && !dialog.consume(500L, true, 1) && !dialog.consume(500L, false, 0))
    val touchOpenedDialog = DialogConfirmGate(null)
    check(!touchOpenedDialog.consume(600L, true, 0) && !touchOpenedDialog.consume(600L, false, 0))
    println("Catalog, ten-app pagination and opening-hold dialog regression checks passed")
}
