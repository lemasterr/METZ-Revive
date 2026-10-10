package com.metzrevive.display

import android.app.Activity
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Bundle
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

/** One explicit API query, no decoder allocation, capture, network, file output or persistent service. */
class CapabilityActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val report = JSONArray()
        MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            .filter { !it.isEncoder && it.supportedTypes.any { type -> type.equals("video/avc", true) } }
            .take(16).forEach { codec ->
                val result = runCatching {
                    val caps = codec.getCapabilitiesForType("video/avc")
                    val video = requireNotNull(caps.videoCapabilities)
                    JSONObject().put("name", codec.name).put("hardware", codec.isHardwareAccelerated)
                        .put("software", codec.isSoftwareOnly).put("vendor", codec.isVendor)
                        .put("supports720p30", video.areSizeAndRateSupported(1280, 720, 30.0))
                        .put("widthAlignment", video.widthAlignment).put("heightAlignment", video.heightAlignment)
                        .put("maxInstances", caps.maxSupportedInstances)
                        .put("lowLatency", caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency))
                        .put("adaptive", caps.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_AdaptivePlayback))
                        .put("profiles", JSONArray().apply {
                            caps.profileLevels.forEach { put(JSONObject().put("profile", it.profile).put("level", it.level)) }
                        })
                }.getOrElse { JSONObject().put("name", codec.name).put("error", it.javaClass.simpleName) }
                report.put(result)
            }
        // One entry per codec avoids logcat's per-line truncation. No device identifiers are logged.
        for (i in 0 until report.length()) Log.i("METZCapability", report.getJSONObject(i).toString())
        Log.i("METZCapability", "DONE codecs=${report.length()}")
        finish()
    }
}
