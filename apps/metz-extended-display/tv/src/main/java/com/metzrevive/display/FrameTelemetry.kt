package com.metzrevive.display

import java.nio.ByteBuffer

/** Counters only: never store image data. Render timestamps are supplied by MediaCodec. */
internal class FrameTelemetry(private val startedNS: Long = System.nanoTime()) {
    private var output = 0L
    private var rendered = 0L
    private var lastRenderedPTS = -1L
    private var lastRenderNS = -1L
    private var traceEnabled = false
    private val trace = java.util.ArrayDeque<LongArray>()
    private var omitted = 0L
    @Synchronized fun enableTrace(enabled: Boolean) { traceEnabled = enabled }
    @Synchronized fun admitted(pts: Long, nowNS: Long = System.nanoTime()) { event(0, pts, nowNS) }
    @Synchronized fun output(pts: Long = -1, nowNS: Long = System.nanoTime()) { output++; event(1, pts, nowNS) }
    @Synchronized fun rendered(pts: Long, nanoTime: Long) {
        if (pts <= lastRenderedPTS || nanoTime < lastRenderNS || rendered >= output) return
        lastRenderedPTS = pts; lastRenderNS = nanoTime; rendered++
        event(2, pts, nanoTime)
    }
    @Synchronized fun report(nowNS: Long): ByteArray = ByteBuffer.allocate(25)
        .put(0x54.toByte()).putLong(output).putLong(rendered)
        .putLong(maxOf(1L, (nowNS - startedNS) / 1000)).array()
    private fun event(stage: Long, pts: Long, nowNS: Long) {
        if (!traceEnabled || pts < 0) return
        if (trace.size == 256) { trace.removeFirst(); omitted++ }
        trace.addLast(longArrayOf(stage, pts, maxOf(0L, (nowNS - startedNS) / 1000)))
    }
    @Synchronized fun takeTrace(): ByteArray? {
        if (!traceEnabled || trace.isEmpty()) return null
        val length = 8 + trace.size * 24
        return ByteBuffer.allocate(5 + length).apply {
            put(0x55.toByte()); putInt(length); putLong(omitted)
            while (trace.isNotEmpty()) for (number in trace.removeFirst()) putLong(number)
        }.array()
    }
}
