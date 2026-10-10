package com.metzrevive.home

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.util.Base64
import android.view.Gravity
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/** Unicode goes directly to the current editor; text is never stored or logged. */
class MacKeyboard : InputMethodService() {
    private val commands = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val connection = currentInputConnection
            val editor = currentInputEditorInfo
            if (connection == null || editor == null || !isInputViewShown) { resultCode = 2; return }
            var textCommitted = false
            val ok = when (intent.getStringExtra("operation")) {
                "text" -> {
                    val encoded = intent.getStringExtra("text64") ?: ""
                    if (encoded.length > 8192) false else runCatching {
                        val text = String(Base64.decode(encoded, Base64.NO_WRAP), Charsets.UTF_8)
                        text.length <= 2048 && connection.commitText(text, 1)
                    }.getOrDefault(false)
                }
                "delete" -> connection.deleteSurroundingTextInCodePoints(1, 0)
                "clear" -> {
                    connection.beginBatchEdit()
                    try { connection.performContextMenuAction(android.R.id.selectAll) && connection.commitText("", 1) }
                    finally { connection.endBatchEdit() }
                }
                "search" -> {
                    val encoded = intent.getStringExtra("text64").orEmpty()
                    val committed = encoded.isEmpty() || (encoded.length <= 8192 && runCatching {
                        val text = String(Base64.decode(encoded, Base64.NO_WRAP), Charsets.UTF_8)
                        text.length <= 2048 && connection.commitText(text, 1)
                    }.getOrDefault(false))
                    textCommitted = committed && encoded.isNotEmpty()
                    committed && connection.performEditorAction(EditorInfo.IME_ACTION_SEARCH)
                }
                "enter" -> {
                    val action = editor.imeOptions and EditorInfo.IME_MASK_ACTION
                    if (action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED)
                        connection.performEditorAction(action)
                    else { sendKeyChar('\n'); true }
                }
                else -> false
            }
            resultCode = if (ok || textCommitted) 0 else 3
            resultData = if (ok) "METZ_TEXT_OK" else if (textCommitted) "METZ_TEXT_COMMITTED" else "METZ_TEXT_FAILED"
        }
    }
    override fun onCreate() {
        super.onCreate()
        val filter = IntentFilter("com.metzrevive.home.KEYBOARD")
        // Only Android shell/system can send this broadcast; installed apps lack DUMP.
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(commands, filter, "android.permission.DUMP", null, Context.RECEIVER_EXPORTED)
        else @Suppress("UnspecifiedRegisterReceiverFlag") registerReceiver(commands, filter, "android.permission.DUMP", null)
    }
    override fun onDestroy() { unregisterReceiver(commands); super.onDestroy() }
    override fun onEvaluateFullscreenMode() = false
    override fun onCreateInputView(): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
        setPadding(32, 16, 32, 16); setBackgroundColor(0xff111a2b.toInt())
        addView(TextView(context).apply {
            text = "Клавиатура Mac · введите текст в METZ Manager"; textSize = 20f; setTextColor(0xfff5f7fa.toInt())
        }, LinearLayout.LayoutParams(0, -2, 1f))
        addView(Button(context).apply {
            text = "Клавиатура ТВ"; isAllCaps = false
            setOnClickListener { (getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager).showInputMethodPicker() }
        })
    }
}
