package com.metzrevive.display

/** A one-shot launch request; only the DUMP-protected receiver may arm the app instance. */
internal class TrustedLaunchGate {
    private var peer = ""
    private var requestedAt = 0L
    @Synchronized fun arm(saved: String, requested: String, now: Long): Boolean {
        peer = ""
        if (!StreamProtocol.validPin(saved) || !StreamProtocol.validPin(requested) ||
            !saved.equals(requested, ignoreCase = true)) return false
        peer = saved.lowercase(); requestedAt = now
        return true
    }
    @Synchronized fun consume(requested: String, now: Long): Boolean {
        val accepted = peer.isNotEmpty() && peer.equals(requested, ignoreCase = true) &&
            now >= requestedAt && now - requestedAt <= 10_000
        peer = ""
        return accepted
    }
}
