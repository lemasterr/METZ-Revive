package com.metzrevive.display

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Returns public certificate metadata only to the authorized shell/system. */
class PairingInfoReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        Thread({
            try { pending.setResult(0, StreamIdentity.fingerprint(), null) }
            catch (_: Exception) { pending.setResult(1, "", null) }
            finally { pending.finish() }
        }, "metz-pairing-info").start()
    }
}
