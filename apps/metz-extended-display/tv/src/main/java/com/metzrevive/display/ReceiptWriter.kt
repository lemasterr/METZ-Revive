package com.metzrevive.display

import java.io.IOException
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/** Socket writes never run on the decoder callback thread. One session owns this writer. */
internal class ReceiptWriter(private val write: (ByteArray) -> Unit, private val failed: () -> Unit) {
    private val packets = ArrayBlockingQueue<ByteArray>(32)
    @Volatile private var active = true
    private val worker = Thread({
        try {
            while (active) {
                val packet = packets.poll(1, TimeUnit.SECONDS) ?: continue
                if (active) write(packet)
            }
        } catch (_: InterruptedException) {
            // Closing the socket releases a blocked write; interrupt releases an empty poll.
        } catch (_: Exception) {
            if (active) { active = false; failed() }
        } finally { packets.clear() }
    }, "metz-receipts").apply { start() }

    @Synchronized fun offer(packet: ByteArray) {
        require(packet.isNotEmpty() && packet.size <= 8192)
        // Never wait for Wi-Fi here or discard a reference-frame ACK. A wedged
        // peer ends its session instead of accumulating more than 32 receipts.
        if (!active || !packets.offer(packet)) throw IOException("Receipt queue unavailable")
    }
    @Synchronized fun close() { active = false; packets.clear(); worker.interrupt() }
    fun awaitClosed(milliseconds: Long): Boolean {
        if (worker !== Thread.currentThread()) worker.join(milliseconds)
        return !worker.isAlive
    }
}
