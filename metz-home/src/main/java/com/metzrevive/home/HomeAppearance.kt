package com.metzrevive.home

data class HomeAppearance(val columns: Int = 5, val titles: String = "auto", val order: String = "HOME,APPS,SETTINGS") {
    fun valid() = columns in 4..6 && titles in listOf("auto", "show", "hide") &&
        order.split(',').let { it.size == 3 && it.toSet() == setOf("HOME", "APPS", "SETTINGS") }
}
