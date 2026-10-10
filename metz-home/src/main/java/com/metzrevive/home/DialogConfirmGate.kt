package com.metzrevive.home

/** A dialog must not turn the gesture that opened it into a selection. */
class DialogConfirmGate(private val openingDownTime: Long?) {
    private var selectionDownTime: Long? = null

    fun consume(downTime: Long, down: Boolean, repeatCount: Int): Boolean {
        if (downTime == openingDownTime) return true
        if (down) {
            if (repeatCount == 0) {
                selectionDownTime = downTime
                return false
            }
            return selectionDownTime != downTime
        }
        val orphanRelease = selectionDownTime != downTime
        selectionDownTime = null
        return orphanRelease
    }
}
