package com.metzrevive.home

import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.Editable
import android.text.TextUtils
import android.text.TextWatcher
import android.util.LruCache
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.GridLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import org.json.JSONArray
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import kotlin.math.roundToInt

class HomeActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())
    private var worker: ExecutorService? = null
    private var visible = false
    private var catalogGeneration = 0
    private var pageGeneration = 0
    private var columns = 5
    private var allAppsPage = false
    private var catalog = emptyList<AppEntry>()
    private var favorites = emptyList<String>()
    private lateinit var grid: GridLayout
    private lateinit var scroll: ScrollView
    private lateinit var status: TextView
    private lateinit var search: EditText
    private lateinit var homeTab: Button
    private lateinit var appsTab: Button
    private val tiles = mutableListOf<Tile>()
    private val iconTasks = mutableListOf<Future<*>>()
    private val pendingIcons = mutableSetOf<String>()
    private val icons = object : LruCache<String, Bitmap>(2 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
    }
    private class Tile(val entry: AppEntry, val view: FrameLayout, val image: ImageView,
                       val star: ImageButton?)
    private val refreshAfterPackageChange = Runnable { if (visible) refreshApps() }
    private val filterAfterTyping = Runnable { if (visible && allAppsPage) renderPage() }
    private val packagesChanged = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            main.removeCallbacks(refreshAfterPackageChange)
            main.postDelayed(refreshAfterPackageChange, 250)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_FULLSCREEN or
            View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
        columns = getPreferences(MODE_PRIVATE).getInt("columns", 5).coerceIn(3, 5)
        allAppsPage = savedInstanceState?.getBoolean("allAppsPage") ?: false
        buildScreen()
        savedInstanceState?.getString("search")?.let { search.setText(it) }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean("allAppsPage", allAppsPage)
        outState.putString("search", search.text.toString())
        super.onSaveInstanceState(outState)
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
        catalogGeneration++
        cancelPageWork()
        main.removeCallbacks(refreshAfterPackageChange)
        main.removeCallbacks(filterAfterTyping)
        unregisterReceiver(packagesChanged)
        worker?.shutdownNow()
        worker = null
        icons.evictAll()
        tiles.forEach { it.image.setImageDrawable(null) }
        super.onStop()
    }

    override fun onDestroy() {
        main.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.hasCategory(Intent.CATEGORY_HOME)) showPage(false)
        focusFirstApp()
    }

    @Deprecated("Android 11 uses the platform back callback")
    override fun onBackPressed() {
        if (allAppsPage) {
            showPage(false)
            focusFirstApp()
        } else if (intent.hasCategory(Intent.CATEGORY_HOME)) {
            scroll.smoothScrollTo(0, 0)
            focusFirstApp()
        } else super.onBackPressed()
    }

    private fun buildScreen() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(32), dp(20), dp(32), dp(20))
            setBackgroundColor(getColor(R.color.background))
        }
        val header = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        header.addView(TextView(this).apply {
            setText(R.string.app_name)
            textSize = 24f
            setTextColor(getColor(R.color.text))
            isSingleLine = true
            ellipsize = TextUtils.TruncateAt.END
            gravity = Gravity.CENTER_VERTICAL
        }, LinearLayout.LayoutParams(0, dp(56), 1f))
        homeTab = pageButton(R.string.home_page) { showPage(false) }
        appsTab = pageButton(R.string.apps_page) { showPage(true) }
        header.addView(homeTab, buttonParams())
        header.addView(appsTab, buttonParams())
        addIcon(header, R.drawable.ic_refresh, R.string.refresh) { refreshApps() }
        addIcon(header, R.drawable.ic_settings, R.string.settings) { showSettings() }
        addIcon(header, R.drawable.ic_home, R.string.stock_home) { openStockHome() }
        root.addView(header)
        search = EditText(this).apply {
            id = View.generateViewId()
            hint = getString(R.string.search_apps)
            contentDescription = getString(R.string.search_apps)
            textSize = 18f
            setTextColor(getColor(R.color.text))
            setHintTextColor(getColor(R.color.muted))
            setSingleLine(true)
            inputType = android.text.InputType.TYPE_CLASS_TEXT
            imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH
            setPadding(dp(16), 0, dp(16), 0)
            background = focusBackground()
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                    main.removeCallbacks(filterAfterTyping)
                    if (visible && allAppsPage) main.postDelayed(filterAfterTyping, 100)
                }
                override fun afterTextChanged(s: Editable?) {}
            })
            setOnEditorActionListener { _, action, _ ->
                if (action == android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH) {
                    main.removeCallbacks(filterAfterTyping)
                    renderPage()
                    (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager)
                        .hideSoftInputFromWindow(windowToken, 0)
                    focusFirstApp()
                    true
                } else false
            }
        }
        root.addView(search, LinearLayout.LayoutParams(-1, dp(48)).apply { topMargin = dp(12) })
        val area = FrameLayout(this)
        grid = GridLayout(this).apply {
            columnCount = columns
            useDefaultMargins = false
            alignmentMode = GridLayout.ALIGN_MARGINS
            descendantFocusability = ViewGroup.FOCUS_AFTER_DESCENDANTS
            addOnLayoutChangeListener { _, left, _, right, _, oldLeft, _, oldRight, _ ->
                if (right - left != oldRight - oldLeft) resizeTiles(right - left)
            }
        }
        scroll = ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            clipToPadding = false
            setPadding(0, dp(16), 0, 0)
            addView(grid, FrameLayout.LayoutParams(-1, -2))
            viewTreeObserver.addOnScrollChangedListener { loadVisibleIcons() }
        }
        status = TextView(this).apply {
            gravity = Gravity.CENTER
            textSize = 20f
            setTextColor(getColor(R.color.muted))
            setPadding(dp(24), 0, dp(24), 0)
            setText(R.string.loading)
        }
        area.addView(scroll, FrameLayout.LayoutParams(-1, -1))
        area.addView(status, FrameLayout.LayoutParams(-1, -1))
        root.addView(area, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(root)
        updateTabs()
    }

    private fun pageButton(label: Int, action: () -> Unit) = Button(this).apply {
        id = View.generateViewId()
        setText(label)
        textSize = 17f
        isAllCaps = false
        minWidth = 0
        setTextColor(getColor(R.color.text))
        setPadding(dp(16), 0, dp(16), 0)
        background = focusBackground()
        stateListAnimator = null
        setOnClickListener { action() }
    }

    private fun buttonParams() = LinearLayout.LayoutParams(-2, dp(48)).apply { marginStart = dp(8) }

    private fun iconButton(icon: Int, description: String, action: () -> Unit) = ImageButton(this).apply {
        id = View.generateViewId()
        setImageResource(icon)
        contentDescription = description
        scaleType = ImageView.ScaleType.CENTER_INSIDE
        setPadding(dp(12), dp(12), dp(12), dp(12))
        background = focusBackground()
        stateListAnimator = null
        setOnClickListener { action() }
    }

    private fun addIcon(parent: LinearLayout, icon: Int, description: Int, action: () -> Unit) {
        parent.addView(iconButton(icon, getString(description), action),
            LinearLayout.LayoutParams(dp(48), dp(48)).apply { marginStart = dp(8) })
    }

    private fun focusBackground(): StateListDrawable {
        fun shape(stroke: Int) = GradientDrawable().apply {
            cornerRadius = dp(12).toFloat()
            setColor(getColor(R.color.surface))
            if (stroke > 0) setStroke(dp(stroke), getColor(R.color.focus))
        }
        return StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_pressed), shape(2))
            addState(intArrayOf(android.R.attr.state_focused), shape(2))
            addState(intArrayOf(android.R.attr.state_selected), shape(1))
            addState(intArrayOf(), shape(0))
        }
    }

    private fun updateTabs() {
        homeTab.isSelected = !allAppsPage
        appsTab.isSelected = allAppsPage
        search.visibility = if (allAppsPage) View.VISIBLE else View.GONE
    }

    private fun showPage(all: Boolean) {
        if (allAppsPage == all) return
        main.removeCallbacks(filterAfterTyping)
        allAppsPage = all
        (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager)
            .hideSoftInputFromWindow(search.windowToken, 0)
        updateTabs()
        scroll.scrollTo(0, 0)
        renderPage()
    }

    private fun cancelPageWork() {
        pageGeneration++
        iconTasks.forEach { it.cancel(true) }
        iconTasks.clear()
        pendingIcons.clear()
    }

    private fun refreshApps() {
        if (!visible) return
        val request = ++catalogGeneration
        cancelPageWork()
        icons.evictAll()
        if (catalog.isEmpty()) setStatus(R.string.loading)
        worker?.execute {
            val result = runCatching {
                val candidates = mutableListOf<AppEntry>()
                for (category in listOf(Intent.CATEGORY_LEANBACK_LAUNCHER, Intent.CATEGORY_LAUNCHER)) {
                    @Suppress("DEPRECATION")
                    val activities = packageManager.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(category), 0)
                    for (match in activities) {
                        if (Thread.currentThread().isInterrupted) return@execute
                        val info = match.activityInfo
                        val app = info.applicationInfo
                        val enabled = info.enabled && info.exported && app.enabled &&
                            info.permission == null && (app.flags and ApplicationInfo.FLAG_SUSPENDED) == 0
                        val system = (app.flags and (ApplicationInfo.FLAG_SYSTEM or ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0
                        val entry = AppEntry(info.packageName, info.name, "", category == Intent.CATEGORY_LEANBACK_LAUNCHER, system, enabled)
                        if (isUserApp(entry, packageName)) {
                            candidates.add(entry.copy(label = match.loadLabel(packageManager).toString()))
                        }
                    }
                }
                arrangeApps(candidates, packageName, Locale.getDefault())
            }
            main.post {
                if (!visible || catalogGeneration != request) return@post
                result.onSuccess { entries ->
                    catalog = entries
                    val prefs = getPreferences(MODE_PRIVATE)
                    if (!prefs.contains("favorites")) {
                        favorites = initialFavorites(entries)
                        saveFavorites()
                    } else {
                        favorites = runCatching {
                            val saved = JSONArray(prefs.getString("favorites", "[]"))
                            (0 until saved.length()).map { saved.getString(it) }.distinct()
                        }.getOrDefault(emptyList())
                    }
                    renderPage()
                    if (currentFocus == null) focusFirstApp()
                }.onFailure {
                    setStatus(R.string.load_failed)
                    Toast.makeText(this, R.string.load_failed, Toast.LENGTH_LONG).show()
                }
            }
        }
    }

    private fun saveFavorites() {
        getPreferences(MODE_PRIVATE).edit().putString("favorites", JSONArray(favorites).toString()).apply()
    }

    private fun setStatus(text: Int) {
        status.setText(text)
        status.visibility = View.VISIBLE
        scroll.visibility = View.GONE
    }

    private fun renderPage() {
        val focusedTile = tiles.firstOrNull { it.view.hasFocus() }
        val focusKey = focusedTile?.entry?.key
        val starFocused = focusedTile?.star?.hasFocus() == true
        cancelPageWork()
        grid.removeAllViews()
        tiles.clear()
        grid.columnCount = columns
        val entries = if (allAppsPage) searchApps(catalog, search.text.toString()) else favoriteApps(catalog, favorites)
        if (entries.isEmpty()) {
            setStatus(if (!allAppsPage) R.string.no_favorites else if (catalog.isEmpty()) R.string.empty else R.string.no_search_results)
            if (focusKey != null) (if (allAppsPage) search else appsTab).requestFocus()
            return
        }
        status.visibility = View.GONE
        scroll.visibility = View.VISIBLE
        entries.forEachIndexed { index, entry ->
            val tile = makeTile(entry)
            tiles.add(tile)
            grid.addView(tile.view, GridLayout.LayoutParams(
                GridLayout.spec(index / columns), GridLayout.spec(index % columns)
            ).apply {
                width = tileWidth(if (grid.width > 0) grid.width else resources.displayMetrics.widthPixels - dp(64))
                height = dp(112 + ((resources.configuration.fontScale - 1f).coerceAtLeast(0f) * 40).roundToInt())
                setMargins(if (index % columns == 0) 0 else dp(8), 0, 0, dp(8))
                setGravity(Gravity.START)
            })
        }
        // Native focus IDs connect the app and its star without a long-press gesture.
        tiles.forEachIndexed { index, tile ->
            val left = tiles.getOrNull(index - 1)?.takeIf { index % columns != 0 }
            val right = tiles.getOrNull(index + 1)?.takeIf { index % columns != columns - 1 }
            tile.view.nextFocusLeftId = left?.star?.id ?: left?.view?.id ?: tile.view.id
            tile.view.nextFocusRightId = tile.star?.id ?: right?.view?.id ?: tile.view.id
            tile.star?.nextFocusLeftId = tile.view.id
            tile.star?.nextFocusRightId = right?.view?.id ?: tile.star.id
            val up = tiles.getOrNull(index - columns)
            val down = tiles.getOrNull(index + columns)
            tile.view.nextFocusUpId = up?.view?.id ?: if (allAppsPage) search.id else homeTab.id
            tile.view.nextFocusDownId = down?.view?.id ?: tile.view.id
            tile.star?.nextFocusUpId = up?.star?.id ?: search.id
            tile.star?.nextFocusDownId = down?.star?.id ?: tile.star.id
        }
        val previous = tiles.firstOrNull { it.entry.key == focusKey }
        if (previous != null) (if (starFocused) previous.star ?: previous.view else previous.view).requestFocus()
        else if (focusKey != null) focusFirstApp()
        grid.post { loadVisibleIcons() }
    }

    // Keep a short favorites row compact instead of stretching three icons across the TV.
    private fun tileWidth(availableWidth: Int) = ((availableWidth - dp(8) * (columns - 1)) / columns).coerceAtLeast(dp(48))

    private fun resizeTiles(availableWidth: Int) {
        tiles.forEach { tile ->
            tile.view.layoutParams = tile.view.layoutParams.apply { width = tileWidth(availableWidth) }
        }
    }

    private fun makeTile(entry: AppEntry): Tile {
        val cell = FrameLayout(this).apply {
            id = View.generateViewId()
            isFocusable = true
            isClickable = true
            descendantFocusability = ViewGroup.FOCUS_BEFORE_DESCENDANTS
            contentDescription = entry.label
            background = focusBackground()
            setOnClickListener { openApp(entry) }
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(8), dp(12), dp(8), dp(8))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
        }
        val image = ImageView(this).apply {
            scaleType = ImageView.ScaleType.FIT_CENTER
            setImageResource(android.R.drawable.sym_def_app_icon)
        }
        content.addView(image, LinearLayout.LayoutParams(dp(40), dp(40)))
        content.addView(TextView(this).apply {
            text = entry.label
            textSize = 17f
            setTextColor(getColor(R.color.text))
            gravity = Gravity.CENTER
            maxLines = 2
            ellipsize = TextUtils.TruncateAt.END
        }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(8) })
        cell.addView(content, FrameLayout.LayoutParams(-1, -1))
        val star = if (allAppsPage) iconButton(
            if (entry.packageName in favorites) R.drawable.ic_star_filled else R.drawable.ic_star,
            getString(if (entry.packageName in favorites) R.string.remove_favorite else R.string.add_favorite, entry.label)
        ) {
            favorites = toggleFavorite(favorites, entry.packageName)
            saveFavorites()
            renderPage()
        }.also {
            cell.addView(it, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.TOP or Gravity.END))
        } else null
        return Tile(entry, cell, image, star)
    }

    private fun focusFirstApp() {
        (tiles.firstOrNull()?.view ?: appsTab).requestFocus()
    }

    private fun loadVisibleIcons() {
        if (!visible || scroll.visibility != View.VISIBLE) return
        val viewport = Rect()
        scroll.getDrawingRect(viewport)
        viewport.offset(0, scroll.scrollY)
        val page = pageGeneration
        for (tile in tiles) {
            val bounds = Rect(tile.view.left, tile.view.top, tile.view.right, tile.view.bottom)
            if (!Rect.intersects(viewport, bounds)) continue
            val key = tile.entry.key
            val cached = icons.get(key)
            if (cached != null) { tile.image.setImageBitmap(cached); continue }
            if (!pendingIcons.add(key)) continue
            worker?.submit {
                if (Thread.currentThread().isInterrupted) return@submit
                val bitmap = runCatching {
                    val drawable = packageManager.getActivityIcon(ComponentName(tile.entry.packageName, tile.entry.activityName))
                    val size = dp(40)
                    Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also {
                        drawable.setBounds(0, 0, size, size)
                        drawable.draw(Canvas(it))
                    }
                }.getOrNull()
                main.post {
                    if (!visible || pageGeneration != page) return@post
                    pendingIcons.remove(key)
                    if (bitmap != null) {
                        icons.put(key, bitmap)
                        tile.image.setImageBitmap(bitmap)
                    }
                }
            }?.let { iconTasks.add(it) }
        }
        iconTasks.removeAll { it.isDone }
    }

    private fun openApp(entry: AppEntry) {
        launchSafely(Intent(Intent.ACTION_MAIN).addCategory(
            if (entry.television) Intent.CATEGORY_LEANBACK_LAUNCHER else Intent.CATEGORY_LAUNCHER
        ).setComponent(ComponentName(entry.packageName, entry.activityName))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED), R.string.launch_failed)
    }

    private fun openStockHome() {
        launchSafely(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME)
            .setPackage("com.google.android.tvlauncher").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), R.string.stock_failed)
    }

    private fun launchSafely(intent: Intent, failure: Int) {
        try { startActivity(intent) }
        catch (_: ActivityNotFoundException) { Toast.makeText(this, failure, Toast.LENGTH_LONG).show() }
        catch (_: SecurityException) { Toast.makeText(this, failure, Toast.LENGTH_LONG).show() }
    }

    private fun showSettings() {
        AlertDialog.Builder(this).setTitle(R.string.settings)
            .setItems(arrayOf(getString(R.string.tv_settings), getString(R.string.choose_home), getString(R.string.grid_size))) { _, choice ->
                when (choice) {
                    0 -> launchSafely(Intent(Settings.ACTION_SETTINGS), R.string.settings_failed)
                    1 -> AlertDialog.Builder(this).setTitle(R.string.choose_home)
                        .setMessage(R.string.enable_home_message)
                        .setPositiveButton(R.string.enable_home) { _, _ ->
                            packageManager.setComponentEnabledSetting(ComponentName(this, "$packageName.HomeEntry"),
                                PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
                            launchSafely(Intent(Settings.ACTION_HOME_SETTINGS), R.string.settings_failed)
                        }.setNegativeButton(R.string.cancel, null).show()
                    2 -> AlertDialog.Builder(this).setTitle(R.string.grid_size)
                        .setSingleChoiceItems(arrayOf(getString(R.string.columns_3), getString(R.string.columns_4), getString(R.string.columns_5)), columns - 3) { dialog, item ->
                            columns = item + 3
                            getPreferences(MODE_PRIVATE).edit().putInt("columns", columns).apply()
                            renderPage()
                            dialog.dismiss()
                            focusFirstApp()
                        }.setNegativeButton(R.string.close, null).show()
                }
            }.setNegativeButton(R.string.close, null).show()
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).roundToInt()
}
