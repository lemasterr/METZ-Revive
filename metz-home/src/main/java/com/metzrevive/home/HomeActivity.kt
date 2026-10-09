package com.metzrevive.home

import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.TextUtils
import android.util.LruCache
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.BaseAdapter
import android.widget.AbsListView
import android.widget.Button
import android.widget.FrameLayout
import android.widget.GridView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.roundToInt

class HomeActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())
    private var worker: ExecutorService? = null
    private var visible = false
    private var generation = 0
    private var columns = 4
    private lateinit var grid: GridView
    private lateinit var status: TextView
    private lateinit var adapter: AppAdapter
    private val icons = object : LruCache<String, Bitmap>(2 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
    }
    private val pendingIcons = mutableSetOf<String>()
    private val packagesChanged = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            // Coalesce a replace/remove/add burst while this screen is visible.
            main.removeCallbacks(refreshAfterPackageChange)
            main.postDelayed(refreshAfterPackageChange, 250)
        }
    }
    private val refreshAfterPackageChange = Runnable { if (visible) refreshApps() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        columns = getPreferences(MODE_PRIVATE).getInt("columns", 4).coerceIn(3, 5)
        adapter = AppAdapter()
        buildScreen()
    }

    override fun onStart() {
        super.onStart()
        visible = true
        worker = Executors.newSingleThreadExecutor()
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REMOVED)
            addAction(Intent.ACTION_PACKAGE_CHANGED)
            addDataScheme("package")
        }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(packagesChanged, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(packagesChanged, filter)
        }
        refreshApps()
    }

    override fun onStop() {
        visible = false
        generation++
        main.removeCallbacks(refreshAfterPackageChange)
        unregisterReceiver(packagesChanged)
        worker?.shutdownNow()
        worker = null
        pendingIcons.clear()
        icons.evictAll()
        // Drop image references when video apps cover HOME; retain only small metadata.
        adapter.clearVisibleIcons()
        super.onStop()
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        grid.requestFocus()
    }

    @Deprecated("The Android 11 HOME target uses the platform back callback")
    override fun onBackPressed() {
        if (intent.hasCategory(Intent.CATEGORY_HOME)) {
            grid.setSelection(0)
            grid.requestFocus()
        } else {
            super.onBackPressed()
        }
    }

    private fun buildScreen() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(32), dp(24), dp(32), dp(20))
            setBackgroundColor(getColor(R.color.background))
        }
        val header = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        header.addView(TextView(this).apply {
            setText(R.string.app_name)
            textSize = 30f
            setTextColor(getColor(R.color.text))
            isSingleLine = true
            ellipsize = TextUtils.TruncateAt.END
        }, LinearLayout.LayoutParams(0, dp(56), 1f))
        addButton(header, R.string.refresh) { refreshApps() }
        addButton(header, R.string.settings) { showSettings() }
        addButton(header, R.string.stock_home) { openStockHome() }
        root.addView(header)

        val area = FrameLayout(this)
        grid = GridView(this).apply {
            id = View.generateViewId()
            numColumns = columns
            horizontalSpacing = dp(12)
            verticalSpacing = dp(12)
            stretchMode = GridView.STRETCH_COLUMN_WIDTH
            gravity = Gravity.CENTER
            selector = focusBackground()
            setDrawSelectorOnTop(false)
            isVerticalScrollBarEnabled = false
            setPadding(0, dp(16), 0, dp(8))
            clipToPadding = false
            adapter = this@HomeActivity.adapter
            setOnItemClickListener { _, _, position, _ -> openApp(this@HomeActivity.adapter.entry(position)) }
        }
        status = TextView(this).apply {
            gravity = Gravity.CENTER
            textSize = 20f
            setTextColor(getColor(R.color.muted))
            setPadding(dp(24), 0, dp(24), 0)
            setText(R.string.loading)
        }
        area.addView(grid, FrameLayout.LayoutParams(-1, -1))
        area.addView(status, FrameLayout.LayoutParams(-1, -1))
        grid.emptyView = status
        root.addView(area, LinearLayout.LayoutParams(-1, 0, 1f))
        root.addView(TextView(this).apply {
            setText(R.string.navigation_hint)
            textSize = 14f
            setTextColor(getColor(R.color.muted))
            setPadding(0, dp(8), 0, 0)
        })
        setContentView(root)
    }

    private fun addButton(parent: LinearLayout, text: Int, action: () -> Unit) {
        parent.addView(Button(this).apply {
            setText(text)
            textSize = 16f
            isAllCaps = false
            minWidth = 0
            setTextColor(getColor(R.color.text))
            setPadding(dp(16), dp(8), dp(16), dp(8))
            background = focusBackground()
            stateListAnimator = null
            setOnClickListener { action() }
        }, LinearLayout.LayoutParams(-2, dp(48)).apply { marginStart = dp(12) })
    }

    private fun focusBackground(): StateListDrawable {
        fun shape(focused: Boolean) = GradientDrawable().apply {
            cornerRadius = dp(6).toFloat()
            setColor(getColor(R.color.surface))
            if (focused) setStroke(dp(2), getColor(R.color.focus))
        }
        return StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_pressed), shape(true))
            addState(intArrayOf(android.R.attr.state_focused), shape(true))
            addState(intArrayOf(android.R.attr.state_selected), shape(true))
            addState(intArrayOf(), shape(false))
        }
    }

    private fun refreshApps() {
        if (!visible) return
        val request = ++generation
        val selectedKey = adapter.entries.getOrNull(grid.selectedItemPosition)?.key
        if (adapter.count == 0) status.setText(R.string.loading)
        pendingIcons.clear()
        icons.evictAll()
        worker?.execute {
            val result = runCatching {
                val candidates = mutableListOf<AppEntry>()
                for (category in listOf(Intent.CATEGORY_LEANBACK_LAUNCHER, Intent.CATEGORY_LAUNCHER)) {
                    val query = Intent(Intent.ACTION_MAIN).addCategory(category)
                    @Suppress("DEPRECATION")
                    val activities = packageManager.queryIntentActivities(query, 0)
                    for (match in activities) {
                        if (Thread.currentThread().isInterrupted) return@execute
                        val info = match.activityInfo
                        if (info.enabled && info.exported && info.applicationInfo.enabled) {
                            candidates.add(AppEntry(info.packageName, info.name,
                                match.loadLabel(packageManager).toString(), category == Intent.CATEGORY_LEANBACK_LAUNCHER))
                        }
                    }
                }
                arrangeApps(candidates, packageName, Locale.getDefault())
            }
            main.post {
                if (!visible || generation != request) return@post
                result.onSuccess { entries ->
                    status.setText(R.string.empty)
                    adapter.entries = entries
                    adapter.notifyDataSetChanged()
                    val selected = entries.indexOfFirst { it.key == selectedKey }.coerceAtLeast(0)
                    grid.setSelection(selected)
                    if (currentFocus == null) grid.requestFocus()
                }.onFailure {
                    status.setText(R.string.load_failed)
                    Toast.makeText(this, R.string.load_failed, Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun openApp(entry: AppEntry) {
        val launch = Intent(Intent.ACTION_MAIN).addCategory(
            if (entry.television) Intent.CATEGORY_LEANBACK_LAUNCHER else Intent.CATEGORY_LAUNCHER
        ).setComponent(ComponentName(entry.packageName, entry.activityName))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
        launchSafely(launch, R.string.launch_failed)
    }

    private fun openStockHome() {
        // Explicit package avoids resolving back to METZ Home if it becomes the default.
        launchSafely(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            .setPackage("com.google.android.tvlauncher")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), R.string.stock_failed)
    }

    private fun launchSafely(intent: Intent, failure: Int) {
        try {
            startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            Toast.makeText(this, failure, Toast.LENGTH_LONG).show()
        } catch (_: SecurityException) {
            Toast.makeText(this, failure, Toast.LENGTH_LONG).show()
        }
    }

    private fun showSettings() {
        AlertDialog.Builder(this).setTitle(R.string.settings)
            .setItems(arrayOf(getString(R.string.tv_settings), getString(R.string.choose_home), getString(R.string.grid_size))) { _, choice ->
                when (choice) {
                    0 -> launchSafely(Intent(Settings.ACTION_SETTINGS), R.string.settings_failed)
                    1 -> AlertDialog.Builder(this).setTitle(R.string.choose_home)
                        .setMessage(R.string.enable_home_message)
                        .setPositiveButton(R.string.enable_home) { _, _ ->
                            packageManager.setComponentEnabledSetting(
                                ComponentName(this, "$packageName.HomeEntry"),
                                PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                                PackageManager.DONT_KILL_APP,
                            )
                            launchSafely(Intent(Settings.ACTION_HOME_SETTINGS), R.string.settings_failed)
                        }.setNegativeButton(R.string.cancel, null).show()
                    2 -> AlertDialog.Builder(this).setTitle(R.string.grid_size)
                        .setSingleChoiceItems(arrayOf(getString(R.string.columns_3), getString(R.string.columns_4), getString(R.string.columns_5)), columns - 3) { dialog, item ->
                            columns = item + 3
                            getPreferences(MODE_PRIVATE).edit().putInt("columns", columns).apply()
                            grid.numColumns = columns
                            dialog.dismiss()
                            grid.requestFocus()
                        }.setNegativeButton(R.string.close, null).show()
                }
            }.setNegativeButton(R.string.close, null).show()
    }

    private inner class AppAdapter : BaseAdapter() {
        var entries = emptyList<AppEntry>()
        fun entry(position: Int) = entries[position]
        override fun getCount() = entries.size
        override fun getItem(position: Int) = entry(position)
        override fun getItemId(position: Int) = position.toLong()

        override fun getView(position: Int, convertView: View?, parent: ViewGroup): View {
            val cell = (convertView as? LinearLayout) ?: LinearLayout(this@HomeActivity).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                layoutParams = AbsListView.LayoutParams(-1, dp(120))
                setPadding(dp(12), dp(12), dp(12), dp(8))
                addView(ImageView(this@HomeActivity).apply {
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                    scaleType = ImageView.ScaleType.FIT_CENTER
                }, LinearLayout.LayoutParams(dp(48), dp(48)))
                addView(TextView(this@HomeActivity).apply {
                    textSize = 18f
                    setTextColor(getColor(R.color.text))
                    gravity = Gravity.CENTER
                    maxLines = 2
                    ellipsize = TextUtils.TruncateAt.END
                }, LinearLayout.LayoutParams(-1, -1).apply { topMargin = dp(8) })
            }
            val entry = entry(position)
            cell.tag = entry.key
            cell.contentDescription = entry.label
            (cell.getChildAt(1) as TextView).text = entry.label
            val image = cell.getChildAt(0) as ImageView
            image.setImageResource(android.R.drawable.sym_def_app_icon)
            val cached = icons.get(entry.key)
            if (cached != null) image.setImageBitmap(cached)
            else if (visible && pendingIcons.add(entry.key)) {
                val request = generation
                worker?.execute {
                    val bitmap = runCatching {
                        val drawable = packageManager.getActivityIcon(ComponentName(entry.packageName, entry.activityName))
                        val size = dp(48)
                        Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also {
                            drawable.setBounds(0, 0, size, size)
                            drawable.draw(Canvas(it))
                        }
                    }.getOrNull()
                    main.post {
                        if (!visible || generation != request) return@post
                        pendingIcons.remove(entry.key)
                        if (bitmap != null) {
                            icons.put(entry.key, bitmap)
                            notifyDataSetChanged()
                        }
                    }
                }
            }
            return cell
        }

        fun clearVisibleIcons() {
            for (index in 0 until grid.childCount) {
                val cell = grid.getChildAt(index) as? LinearLayout ?: continue
                (cell.getChildAt(0) as ImageView).setImageDrawable(null)
            }
        }
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).roundToInt()
}
