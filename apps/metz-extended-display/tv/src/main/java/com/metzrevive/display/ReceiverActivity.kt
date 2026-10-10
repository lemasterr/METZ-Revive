package com.metzrevive.display

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView

class ReceiverActivity : Activity(), SurfaceHolder.Callback {
    companion object { @Volatile var activeReceiver: StreamReceiver? = null }
    private lateinit var surface: SurfaceView
    private lateinit var panel: LinearLayout
    private lateinit var status: TextView
    private lateinit var pin: EditText
    private lateinit var start: Button
    private var receiver: StreamReceiver? = null
    private var shown = false
    private var identityReady = false
    private var sessionID = 0
    private var autoSession = false
    private var pendingTrustedPeer: String? = null
    private var confirmationDialog: AlertDialog? = null
    private val trust get() = getSharedPreferences("ReceiverActivity", MODE_PRIVATE)
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        intent.getStringExtra("peer_pin")?.let {
            if (SessionRequestReceiver.launch.consume(it, android.os.SystemClock.elapsedRealtime())) pendingTrustedPeer = it
        }
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        val root = FrameLayout(this).apply { setBackgroundColor(Color.rgb(11, 18, 32)) }
        surface = SurfaceView(this).apply { isFocusable = false; holder.addCallback(this@ReceiverActivity) }
        root.addView(surface, FrameLayout.LayoutParams(-1, -1))
        panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.rgb(11, 18, 32)); setPadding(dp(64), dp(32), dp(64), dp(32))
        }
        fun text(value: String, size: Float) = TextView(this).apply { text = value; textSize = size; setTextColor(Color.rgb(245, 247, 250)) }
        panel.addView(text("METZ Display", 32f))
        panel.addView(text("Второй экран Mac", 22f))
        val certificate = text("Подготовка ключа подключения…", 16f).apply { isFocusable = false; isClickable = false }
        panel.addView(certificate, LinearLayout.LayoutParams(-1, -2).apply { topMargin = 16 })
        pin = EditText(this).apply {
            id = View.generateViewId()
            isFocusable = true; isFocusableInTouchMode = true
            inputType = android.text.InputType.TYPE_CLASS_TEXT or android.text.InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
            imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_DONE
            setSelectAllOnFocus(true)
            setPadding(dp(16), 0, dp(16), 0)
            background = android.graphics.drawable.StateListDrawable().apply {
                fun shape(focused: Boolean) = android.graphics.drawable.GradientDrawable().apply {
                    setColor(Color.rgb(17, 26, 43)); cornerRadius = dp(12).toFloat()
                    setStroke(dp(if (focused) 2 else 1), if (focused) Color.rgb(47,128,255) else Color.rgb(36,58,88))
                }
                addState(intArrayOf(android.R.attr.state_focused), shape(true)); addState(intArrayOf(), shape(false))
            }
            hint = "Ключ Mac · Manager может заполнить его сам"; textSize = 18f; setSingleLine(true)
            setTextColor(Color.WHITE); setHintTextColor(Color.rgb(174, 184, 199))
            setText(trust.getString("peerPin", ""))
            // Prefill only: an external intent can never silently replace the saved trust anchor.
            intent.getStringExtra("peer_pin")?.takeIf { StreamProtocol.validPin(it) }?.let { setText(it) }
        }
        panel.addView(pin, LinearLayout.LayoutParams(-1, dp(56)).apply { topMargin = dp(16) })
        status = text("Сверьте отпечатки на Mac и ТВ", 18f)
        panel.addView(status)
        start = Button(this).apply {
            id = View.generateViewId()
            text = "Подтвердить и принимать"; isAllCaps = false; isEnabled = false
            isFocusable = true; isFocusableInTouchMode = true; isClickable = true
            setTextColor(Color.WHITE)
            background = android.graphics.drawable.StateListDrawable().apply {
                fun shape(focused: Boolean) = android.graphics.drawable.GradientDrawable().apply {
                    setColor(if (focused) Color.rgb(35, 91, 171) else Color.rgb(23, 43, 71))
                    cornerRadius = dp(10).toFloat()
                    setStroke(dp(if (focused) 3 else 1), if (focused) Color.WHITE else Color.rgb(73, 94, 121))
                }
                addState(intArrayOf(android.R.attr.state_focused), shape(true))
                addState(intArrayOf(), shape(false))
            }
            setOnClickListener {
                if (confirmationDialog?.isShowing == true) return@setOnClickListener
                val fingerprint = pin.text.toString().filter { !it.isWhitespace() && it != ':' && it != '-' }.lowercase()
                if (!StreamProtocol.validPin(fingerprint)) { status.text = "Введите 64 шестнадцатеричных символа отпечатка Mac"; return@setOnClickListener }
                (getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager)
                    .hideSoftInputFromWindow(pin.windowToken, 0)
                if (trust.getString("peerPin", "").equals(fingerprint, ignoreCase = true)) {
                    beginReceiver(fingerprint, automatic = true)
                    return@setOnClickListener
                }
                val dialog = AlertDialog.Builder(this@ReceiverActivity).setTitle("Доверять этому Mac?")
                    .setMessage("$fingerprint\n\nПосле подтверждения этот Mac сможет подключаться из Manager без повторного вопроса. Новый ключ потребует подтверждения.").setPositiveButton("Доверять и принимать") { _, _ ->
                        if (!surface.holder.surface.isValid) { status.text = "Экран ещё не готов"; return@setPositiveButton }
                        if (!trust.edit().putString("peerPin", fingerprint.lowercase()).commit()) {
                            status.text = "Не удалось сохранить доверие"; return@setPositiveButton
                        }
                        beginReceiver(fingerprint, automatic = true)
                    }.setNegativeButton("Отмена", null).create()
                confirmationDialog = dialog
                dialog.setOnDismissListener { confirmationDialog = null; if (shown && receiver?.isRunning != true) focusConfirmation() }
                dialog.setOnShowListener {
                    dialog.window?.setSoftInputMode(android.view.WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN)
                    dialog.getButton(AlertDialog.BUTTON_POSITIVE).requestFocus()
                }
                dialog.show()
            }
        }
        pin.nextFocusDownId = start.id
        start.nextFocusUpId = pin.id
        pin.setOnEditorActionListener { _, action, event ->
            if (action == android.view.inputmethod.EditorInfo.IME_ACTION_DONE ||
                action == android.view.inputmethod.EditorInfo.IME_ACTION_GO ||
                action == android.view.inputmethod.EditorInfo.IME_ACTION_NEXT ||
                (event?.keyCode == android.view.KeyEvent.KEYCODE_ENTER && event.action == android.view.KeyEvent.ACTION_UP)) {
                confirmFromKeyboard(); true
            } else false
        }
        pin.setOnKeyListener { _, key, event ->
            if (key == android.view.KeyEvent.KEYCODE_ENTER || key == android.view.KeyEvent.KEYCODE_NUMPAD_ENTER) {
                if (event.action == android.view.KeyEvent.ACTION_UP) confirmFromKeyboard()
                true
            } else if (key == android.view.KeyEvent.KEYCODE_DPAD_DOWN && event.action == android.view.KeyEvent.ACTION_DOWN && start.isEnabled) {
                focusConfirmation(); true
            } else false
        }
        panel.addView(start, LinearLayout.LayoutParams(dp(360), dp(60)).apply { topMargin = dp(16) })
        root.addView(panel, FrameLayout.LayoutParams(-1, -2, Gravity.CENTER))
        setContentView(root)
        pin.requestFocus()
        Thread({
            val fingerprint = runCatching { StreamIdentity.fingerprint() }.getOrNull()
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                certificate.text = fingerprint?.let { "Отпечаток ТВ — введите его на Mac:\n${it.chunked(32).joinToString("\n")}" } ?: "Ключ подключения недоступен"
                identityReady = fingerprint != null
                start.isEnabled = identityReady
                if (identityReady && StreamProtocol.validPin(pin.text.toString())) focusConfirmation()
                startPendingSession()
            }
        }, "metz-identity").start()
    }
    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra("peer_pin")?.takeIf { StreamProtocol.validPin(it) }?.let {
            if (SessionRequestReceiver.launch.consume(it, android.os.SystemClock.elapsedRealtime())) {
                pendingTrustedPeer = it; startPendingSession(); return
            }
            if (receiver?.isRunning == true && receiver?.trusts(it) == true) return
            // A new identity invalidates the active listener, but trust still requires local confirmation.
            sessionID++; receiver?.stop(); receiver = null; activeReceiver = null
            panel.visibility = View.VISIBLE; start.isEnabled = identityReady
            pin.setText(it)
            if (start.isEnabled) focusConfirmation() else pin.requestFocus()
            status.text = "Ключ Mac получен. Нажмите «Подтвердить и принимать»."
        }
    }
    override fun onStart() {
        super.onStart(); shown = true
        panel.visibility = View.VISIBLE
        start.isEnabled = identityReady
        startPendingSession()
    }
    override fun onStop() { shown = false; confirmationDialog?.dismiss(); sessionID++; receiver?.stop(); receiver = null; activeReceiver = null; super.onStop() }
    override fun surfaceCreated(holder: SurfaceHolder) { startPendingSession() }
    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit
    override fun surfaceDestroyed(holder: SurfaceHolder) { sessionID++; receiver?.stop(); receiver = null; activeReceiver = null; panel.visibility = View.VISIBLE; start.isEnabled = identityReady }
    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent): Boolean {
        if (keyCode == android.view.KeyEvent.KEYCODE_MENU && receiver?.isRunning == true) {
            receiver?.requestKeyframe(); return true
        }
        return super.onKeyDown(keyCode, event)
    }
    @Deprecated("Platform callback for Android11")
    override fun onBackPressed() {
        if (autoSession) { finish() }
        else if (receiver != null) { sessionID++; receiver?.stop(); receiver = null; activeReceiver = null; panel.visibility = View.VISIBLE; start.isEnabled = identityReady; start.requestFocus() }
        else super.onBackPressed()
    }
    private fun focusConfirmation() {
        (getSystemService(INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager)
            .hideSoftInputFromWindow(pin.windowToken, 0)
        pin.clearFocus(); start.requestFocus()
    }
    private fun confirmFromKeyboard() {
        focusConfirmation()
        if (start.isEnabled) start.performClick()
        else status.text = "Ключ ещё готовится. Дождитесь кнопки подтверждения."
    }
    private fun startPendingSession() {
        val peer = pendingTrustedPeer ?: return
        if (!shown || !identityReady || !surface.holder.surface.isValid) return
        pendingTrustedPeer = null
        if (trust.getString("peerPin", "").equals(peer, ignoreCase = true)) beginReceiver(peer, automatic = true)
    }
    private fun beginReceiver(peer: String, automatic: Boolean) {
        if (!shown || !identityReady || !surface.holder.surface.isValid) { status.text = "Экран ещё не готов"; return }
        // A new explicit start retires the previous session even with the same peer.
        // The receiver serializes listener/codec teardown before allocating the next.
        receiver?.stop(); val current = ++sessionID; autoSession = automatic
        receiver = StreamReceiver(surface.holder.surface, peer,
            status = { message -> runOnUiThread {
                if (!shown || current != sessionID) return@runOnUiThread
                status.text = message
                if (message.startsWith("Подключено")) panel.visibility = View.GONE
                else { panel.visibility = View.VISIBLE; start.isEnabled = receiver?.isRunning != true }
            } },
            ended = { runOnUiThread { if (shown && current == sessionID && autoSession) finish() } }
        ).also { activeReceiver = it; it.start() }
        start.isEnabled = false
    }
}
