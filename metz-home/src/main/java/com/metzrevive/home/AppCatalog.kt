package com.metzrevive.home

import java.text.Collator
import java.util.Locale

data class AppEntry(
    val packageName: String,
    val activityName: String,
    val label: String,
    val television: Boolean,
    val system: Boolean = false,
    val enabled: Boolean = true,
) {
    val key: String get() = "$packageName/$activityName"
}

/** Prefer the TV entry point, keep one tile per package, and use stable tie breakers. */
fun arrangeApps(candidates: List<AppEntry>, ownPackage: String, locale: Locale): List<AppEntry> {
    val collator = Collator.getInstance(locale)
    val unique = candidates.filter { isUserApp(it, ownPackage) }
        .sortedWith(compareBy<AppEntry>({ !it.television }, { it.activityName }))
        .distinctBy { it.packageName }
    return unique.sortedWith { left, right ->
        val comparison = collator.compare(left.label, right.label)
        if (comparison != 0) comparison else left.key.compareTo(right.key)
    }
}

// A system flag alone would also hide preinstalled YouTube. Only known consumer
// apps are admitted from the system image; vendor tools remain outside the grid.
private val consumerSystemApps = setOf(
    "com.google.android.youtube.tv", "com.google.android.youtube",
    "com.android.vending", "com.netflix.ninja", "com.amazon.amazonvideo.livingroom",
    "com.disney.disneyplus", "com.spotify.tv.android", "tv.twitch.android.app",
    "com.kick.mobile", "com.phlox.tvwebbrowser", "com.aengix.tvbrowser",
)
private val internalApps = setOf(
    "com.google.android.tvlauncher", "com.google.android.tvrecommendations",
    "dev.vodik7.atvtoolsserver", "com.android.settings", "com.android.tv.settings",
    "com.google.android.tv.settings", "com.google.android.apps.mediashell",
)

fun isUserApp(entry: AppEntry, ownPackage: String): Boolean = entry.enabled &&
    entry.packageName != ownPackage && entry.packageName !in internalApps &&
    (!entry.system || entry.packageName in consumerSystemApps)

fun initialFavorites(entries: List<AppEntry>): List<String> {
    val available = entries.map { it.packageName }.toSet()
    val browser = listOf("com.aengix.tvbrowser", "net.mrowser", "com.phlox.tvwebbrowser")
        .firstOrNull { it in available }
    return listOfNotNull("com.google.android.youtube.tv", "tv.twitch.android.app", browser)
        .filter { it in available }.distinct()
}

/** An empty saved list is deliberate. Missing apps are hidden, not deleted from preferences. */
fun favoriteApps(entries: List<AppEntry>, favorites: List<String>): List<AppEntry> {
    val available = entries.associateBy { it.packageName }
    return favorites.distinct().mapNotNull { available[it] }
}

fun toggleFavorite(favorites: List<String>, packageName: String): List<String> =
    if (packageName in favorites) favorites.filterNot { it == packageName }
    else favorites.distinct() + packageName

fun searchApps(entries: List<AppEntry>, query: String): List<AppEntry> {
    val terms = query.trim().split(Regex("\\s+")).filter { it.isNotEmpty() }
    return entries.filter { entry -> terms.all { entry.label.contains(it, ignoreCase = true) } }
}

/** Two rows of five; empty and out-of-range pages never duplicate apps. */
const val APPS_PER_PAGE = 10
fun pageCount(size: Int, columns: Int = 5): Int {
    require(columns in 4..6)
    return (size.coerceAtLeast(0) + columns * 2 - 1) / (columns * 2)
}
fun appSlice(entries: List<AppEntry>, page: Int, columns: Int = 5): List<AppEntry> =
    if (page < 0 || page >= pageCount(entries.size, columns)) emptyList() else entries.drop(page * columns * 2).take(columns * 2)

/** Preserve the row when crossing a page edge; clamp sparse last pages. */
fun pageEntryIndex(sourceIndex: Int, count: Int, forward: Boolean, columns: Int = 5): Int {
    require(columns in 4..6)
    if (count <= 0) return -1
    val row = (sourceIndex.coerceAtLeast(0) / columns).coerceAtMost((count - 1) / columns)
    return if (forward) row * columns else minOf(row * columns + columns - 1, count - 1)
}

/** Move without losing missing saved apps or changing the rest of the order. */
fun moveFavorite(favorites: List<String>, name: String, delta: Int): List<String> {
    val index = favorites.indexOf(name)
    val target = index + delta
    if (index < 0 || target !in favorites.indices) return favorites
    return favorites.toMutableList().apply { val item = removeAt(index); add(target, item) }
}
