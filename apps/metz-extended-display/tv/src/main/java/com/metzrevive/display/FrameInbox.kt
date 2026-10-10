package com.metzrevive.display

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

internal data class EncodedFrame(val bytes: ByteArray, val pts: Long)

/** Preserve H.264 reference frames and bound memory while the decoder catches up. */
internal class FrameInbox {
    private val frames = ArrayBlockingQueue<EncodedFrame>(2)

    fun offer(frame: EncodedFrame, timeoutMillis: Long = 500): Boolean =
        frames.offer(frame, timeoutMillis, TimeUnit.MILLISECONDS)

    fun poll(timeoutMillis: Long = 4): EncodedFrame? = frames.poll(timeoutMillis, TimeUnit.MILLISECONDS)
    fun clear() = frames.clear()
}
