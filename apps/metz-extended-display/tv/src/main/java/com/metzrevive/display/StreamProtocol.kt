package com.metzrevive.display

import java.nio.ByteBuffer

data class Header(val type: Int, val flags: Int, val length: Int, val epoch: Long, val pts: Long)
data class VideoSessionParameters(val width: Int, val height: Int, val fps: Int, val epoch: Long, val audio: Boolean)
/** Codec parameter sets may update on an IDR; the session dimensions/epoch/audio must remain stable. */
class VideoSessionGate {
    private var current: VideoSessionParameters? = null
    fun accept(value: VideoSessionParameters): Boolean {
        if (value.epoch !in 1..0xffffffffL || value.fps !in listOf(30, 50, 60) ||
            (value.width to value.height) !in listOf(854 to 480, 960 to 540, 1280 to 720, 1366 to 768)) return false
        if (current != null && current != value) return false
        current = value
        return true
    }
}
object StreamProtocol {
    const val MAX_PAYLOAD = 1_048_576
    fun admissionReceipt(pts: Long): ByteArray {
        require(pts >= 0)
        return ByteBuffer.allocate(9).put(0x46.toByte()).putLong(pts).array()
    }
    fun validPin(value: String) = value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
    fun header(bytes: ByteArray): Header {
        require(bytes.size == 24)
        val buffer = ByteBuffer.wrap(bytes)
        require(buffer.int == 0x4d545a31 && buffer.get().toInt() == 1)
        val type = buffer.get().toInt()
        val flags = buffer.short.toInt() and 0xffff
        val length = buffer.int
        val epoch = buffer.int.toLong() and 0xffffffffL
        val pts = buffer.long
        require(type in 1..4 && flags in 0..1 && length in 0..MAX_PAYLOAD && epoch != 0L && pts >= 0)
        require(type == 2 || length <= 65_536)
        require(type != 4 || (flags == 0 && length in 4..8192 && length % 4 == 0))
        return Header(type, flags, length, epoch, pts)
    }
    fun hasIDR(bytes: ByteArray): Boolean {
        for (i in 0 until bytes.size - 4) {
            if (bytes[i] == 0.toByte() && bytes[i + 1] == 0.toByte() && bytes[i + 2] == 0.toByte() &&
                bytes[i + 3] == 1.toByte() && (bytes[i + 4].toInt() and 31) == 5) return true
        }
        return false
    }
}
