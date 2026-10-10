package com.metzrevive.home

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.Locale

/** On-demand metadata for the paired ADB Manager, protected by signature DUMP. */
class CatalogReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        Thread({
            try {
                val pm = context.packageManager
                val component = intent.getStringExtra("component")
                val result = if (component != null) {
                    require(component.length < 240)
                    val name = ComponentName.unflattenFromString(component) ?: error("component")
                    val drawable = runCatching { pm.getActivityBanner(name) }.getOrNull()
                        ?: pm.getActivityIcon(name)
                    val bitmap = Bitmap.createBitmap(160, 90, Bitmap.Config.ARGB_8888)
                    val width = drawable.intrinsicWidth.coerceAtLeast(1)
                    val height = drawable.intrinsicHeight.coerceAtLeast(1)
                    val factor = minOf(160f / width, 90f / height)
                    val w = (width * factor).toInt(); val h = (height * factor).toInt()
                    drawable.setBounds((160-w)/2, (90-h)/2, (160+w)/2, (90+h)/2)
                    drawable.draw(Canvas(bitmap))
                    val bytes = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
                    bitmap.recycle()
                    require(bytes.size <= 40000)
                    JSONObject().put("icon", Base64.encodeToString(bytes, Base64.NO_WRAP)).toString()
                } else {
                    val candidates = listOf(Intent.CATEGORY_LEANBACK_LAUNCHER, Intent.CATEGORY_LAUNCHER).flatMap { category ->
                        @Suppress("DEPRECATION")
                        pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(category), 0).map { match ->
                            val info = match.activityInfo; val app = info.applicationInfo
                            AppEntry(info.packageName, info.name, match.loadLabel(pm).toString().take(120),
                                category == Intent.CATEGORY_LEANBACK_LAUNCHER,
                                app.flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP) != 0,
                                info.enabled && info.exported && app.enabled && info.permission == null &&
                                app.flags and ApplicationInfo.FLAG_SUSPENDED == 0)
                        }
                    }
                    JSONArray(arrangeApps(candidates, "", Locale.getDefault()).take(80).map {
                        JSONObject().put("component", it.key).put("title", it.label)
                    }).toString()
                }
                pending.setResult(0, result, null)
            } catch (_: Exception) { pending.setResult(1, "", null) }
            finally { pending.finish() }
        }, "metz-catalog-request").start()
    }
}
