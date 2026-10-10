package com.metzrevive.display

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import org.json.JSONObject

/** Read-only readiness query for the authorized ADB shell; never starts or trusts a peer. */
class ReceiverStatusReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val receiver = ReceiverActivity.activeReceiver
        val peer = intent.getStringExtra("peer_pin").orEmpty()
        val saved = context.getSharedPreferences("ReceiverActivity", Context.MODE_PRIVATE).getString("peerPin", "").orEmpty()
        setResult(0, JSONObject().put("listening", receiver?.listening == true)
            .put("trusted", StreamProtocol.validPin(peer) && saved.equals(peer, ignoreCase = true))
            .put("lastError", receiver?.lastError.orEmpty()).toString(), null)
    }
}
