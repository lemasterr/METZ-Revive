package com.metzrevive.home

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONObject

/** Only the authorized shell can access this endpoint (manifest DUMP permission). */
class AppearanceReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val prefs = context.getSharedPreferences("appearance", Context.MODE_PRIVATE)
        if (intent.getStringExtra("operation") == "set") {
            val value = HomeAppearance(intent.getIntExtra("columns", 0), intent.getStringExtra("titles").orEmpty(),
                intent.getStringExtra("order").orEmpty())
            if (!value.valid()) { setResult(3, "METZ_CONFIG_INVALID", null); return }
            // One atomic value means the visible Home never observes a partially updated configuration.
            prefs.edit().putString("config", JSONObject().put("columns", value.columns)
                .put("titles", value.titles).put("order", value.order).toString()).apply()
        } else if (intent.getStringExtra("operation") != "get") { setResult(3, "METZ_CONFIG_INVALID", null); return }
        setResult(0, prefs.getString("config", "{\"columns\":5,\"titles\":\"auto\",\"order\":\"HOME,APPS,SETTINGS\"}"), null)
    }
}
