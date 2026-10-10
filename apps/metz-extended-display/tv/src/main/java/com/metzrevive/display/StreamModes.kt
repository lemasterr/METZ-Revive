package com.metzrevive.display

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import org.json.JSONArray
import org.json.JSONObject

data class StreamMode(val width: Int, val height: Int, val fps: Int) {
    val level get() = if (width == 1366 && fps == 60) "4.2" else if (width == 1366 || (fps >= 50 && width >= 960)) "4.1" else "3.1"
    companion object {
        // Physical panel of this project's METZ 32MTC6000Z is 1366x768;
        // Android's 1280x720 framebuffer is a separate compositor mode.
        val candidates = listOf(854 to 480, 960 to 540, 1280 to 720, 1366 to 768).flatMap { (w, h) ->
            listOf(30, 50, 60).map { StreamMode(w, h, it) }
        }
    }
}
object StreamModes {
    fun decoder(mode: StreamMode): MediaCodecInfo? {
        if (mode !in StreamMode.candidates) return null
        val required = when (mode.level) {
            "4.2" -> MediaCodecInfo.CodecProfileLevel.AVCLevel42
            "4.1" -> MediaCodecInfo.CodecProfileLevel.AVCLevel41
            else -> MediaCodecInfo.CodecProfileLevel.AVCLevel31
        }
        return MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.firstOrNull { info ->
            runCatching {
                !info.isEncoder && info.isHardwareAccelerated && info.supportedTypes.any { it.equals("video/avc", true) } &&
                    info.getCapabilitiesForType("video/avc").let { caps ->
                        caps.videoCapabilities?.areSizeAndRateSupported(mode.width, mode.height, mode.fps.toDouble()) == true &&
                            caps.profileLevels.any { it.profile == MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline && it.level >= required }
                    }
            }.getOrDefault(false)
        }
    }
}
/** Bounded metadata query: no Activity, decoder, capture, listener or background service. */
class StreamModesReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        resultData = JSONArray().apply {
            StreamMode.candidates.filter { StreamModes.decoder(it) != null }.forEach {
                put(JSONObject().put("width", it.width).put("height", it.height).put("fps", it.fps))
            }
        }.toString()
        resultCode = 0
    }
}
