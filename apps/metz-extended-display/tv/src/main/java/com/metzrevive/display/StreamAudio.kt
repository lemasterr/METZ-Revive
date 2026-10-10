package com.metzrevive.display

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack

class StreamAudioFailure : Exception()

/** Session-owned PCM sink. No decoder, worker thread or unbounded application queue. */
class StreamAudio {
    private val minimum = AudioTrack.getMinBufferSize(48000, AudioFormat.CHANNEL_OUT_STEREO, AudioFormat.ENCODING_PCM_16BIT)
    private val track: AudioTrack
    private var firstAccepted = false
    init {
        check(minimum > 0)
        track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(48000).setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setBufferSizeInBytes(maxOf(minimum, 15360)) // ~80 ms, never enlarge on a slow sink.
            .setTransferMode(AudioTrack.MODE_STREAM).build()
        try { check(track.state == AudioTrack.STATE_INITIALIZED); track.play() }
        catch (error: Exception) { track.release(); throw error }
    }
    fun write(bytes: ByteArray) {
        require(bytes.isNotEmpty() && bytes.size <= 8192 && bytes.size % 4 == 0)
        // A full sink drops raw PCM instead of blocking the video reader.
        val written = track.write(bytes, 0, bytes.size, AudioTrack.WRITE_NON_BLOCKING)
        check(written >= 0)
        if (written > 0 && !firstAccepted) {
            firstAccepted = true
            android.util.Log.i("METZStream", "AUDIO_PCM_ACCEPTED")
        }
    }
    fun close() { runCatching { track.pause() }; runCatching { track.flush() }; runCatching { track.release() } }
}
