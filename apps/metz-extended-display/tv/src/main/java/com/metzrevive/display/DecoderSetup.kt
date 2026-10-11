package com.metzrevive.display

/** A documented optional request can be rejected even when a codec accepts AVC itself. */
internal object DecoderSetup {
    fun <T> create(active: () -> Boolean, configure: (Boolean) -> T): T {
        try { return configure(true) }
        catch (first: Exception) {
            if (!active()) throw first
            return configure(false)
        }
    }
}
