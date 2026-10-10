package com.metzrevive.display

import java.nio.ByteBuffer

/** Counters only: never store image data. Render timestamps are supplied by MediaCodec. */
internal class FrameTelemetry(private val startedNS: Long = System.nanoTime()) {
    private var output = 0L
    private var rendered = 0L
    private var lastRenderedPTS = -1L
    private var lastRenderNS = -1L
    @Synchronized fun output() { output++ }
    @Synchronized fun rendered(pts: Long, nanoTime: Long) {
        if (pts <= lastRenderedPTS || nanoTime < lastRenderNS || rendered >= output) return
        lastRenderedPTS = pts; lastRenderNS = nanoTime; rendered++
    }
    @Synchronized fun report(nowNS: Long): ByteArray = ByteBuffer.allocate(25)
        .put(0x54.toByte()).putLong(output).putLong(rendered)
        .putLong(maxOf(1L, (nowNS - startedNS) / 1000)).array()
}
