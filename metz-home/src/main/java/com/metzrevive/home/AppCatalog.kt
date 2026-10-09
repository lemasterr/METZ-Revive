package com.metzrevive.home

import java.text.Collator
import java.util.Locale

data class AppEntry(
    val packageName: String,
    val activityName: String,
    val label: String,
    val television: Boolean,
) {
    val key: String get() = "$packageName/$activityName"
}

/** Prefer the TV entry point, keep one tile per package, and use stable tie breakers. */
fun arrangeApps(candidates: List<AppEntry>, ownPackage: String, locale: Locale): List<AppEntry> {
    val collator = Collator.getInstance(locale)
    val unique = candidates.filter { it.packageName != ownPackage }
        .sortedWith(compareBy<AppEntry>({ !it.television }, { it.activityName }))
        .distinctBy { it.packageName }
    return unique.sortedWith { left, right ->
        val comparison = collator.compare(left.label, right.label)
        if (comparison != 0) comparison else left.key.compareTo(right.key)
    }
}
