package com.metzrevive.display

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock

/** On-demand request from authorized ADB; no socket, service, alarm or persistent worker. */
class SessionRequestReceiver : BroadcastReceiver() {
    companion object { internal val launch = TrustedLaunchGate() }
    override fun onReceive(context: Context, intent: Intent) {
        val saved = context.getSharedPreferences("ReceiverActivity", Context.MODE_PRIVATE).getString("peerPin", "").orEmpty()
        val requested = intent.getStringExtra("peer_pin").orEmpty()
        val trusted = launch.arm(saved, requested, SystemClock.elapsedRealtime())
        setResult(0, if (trusted) "METZ_SESSION_TRUSTED" else "METZ_SESSION_NEEDS_TRUST", null)
    }
}
