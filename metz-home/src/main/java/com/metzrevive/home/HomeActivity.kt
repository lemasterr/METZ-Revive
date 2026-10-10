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
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.net.Uri
import android.provider.Settings
import android.text.Editable
import android.text.TextUtils
import android.text.TextWatcher
import android.util.LruCache
import android.view.KeyEvent
import android.view.MotionEvent
import android.graphics.drawable.LayerDrawable
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
import android.widget.TextClock
import android.widget.Toast
import org.json.JSONArray
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import kotlin.math.roundToInt

class HomeActivity : Activity() {
    private val main = Handler(Looper.getMainLooper())
    private var heldConfirmDownTime: Long? = null
    private var worker: ExecutorService? = null
    private var visible = false
    private var catalogGeneration = 0
    private var pageGeneration = 0
    private var rebuilding = false
    private var appearance = HomeAppearance()
    private val columns get() = appearance.columns
    private val appearanceChanged = android.content.SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
        if (key == "config" && visible) {
            cancelPageWork(); readAppearance(); appPage = 0; buildScreen(); renderPage()
        }
    }
    private fun readAppearance() {
        appearance = runCatching {
            val value = org.json.JSONObject(getSharedPreferences("appearance", MODE_PRIVATE).getString("config", "{}"))
            HomeAppearance(value.optInt("columns", 5), value.optString("titles", "auto"), value.optString("order", "HOME,APPS,SETTINGS"))
        }.getOrDefault(HomeAppearance()).takeIf { it.valid() } ?: HomeAppearance()
    }
    private var appPage = 0
    private var searchQuery = ""
    private var touchStartX = 0f
    private var touchStartY = 0f
    private lateinit var pageCounter: TextView
    private lateinit var pager: LinearLayout
    private enum class Page { HOME, APPS, SETTINGS }
    private var page = Page.HOME
    private val allAppsPage get() = page == Page.APPS
    private var catalog = emptyList<AppEntry>()
    private var favorites = emptyList<String>()
    private lateinit var grid: GridLayout
    private lateinit var scroll: ScrollView
    private lateinit var status: TextView
    private lateinit var search: EditText
    private lateinit var homeTab: Button
    private lateinit var appsTab: Button
    private lateinit var settingsTab: Button
    private lateinit var pageContent: LinearLayout
    private lateinit var utilityScroll: ScrollView
    private lateinit var pageArea: FrameLayout
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
        appPage = savedInstanceState?.getInt("appPage") ?: 0
        searchQuery = savedInstanceState?.getString("search") ?: ""
        page = savedInstanceState?.getString("page")?.let { saved ->
            Page.entries.firstOrNull { it.name == saved }
        } ?: if (savedInstanceState?.getBoolean("allAppsPage") == true) Page.APPS else Page.HOME
        readAppearance(); buildScreen()

    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putString("page", page.name)
        outState.putString("search", searchQuery)
        outState.putInt("appPage", appPage)
        super.onSaveInstanceState(outState)
    }

    override fun onStart() {
        super.onStart()
        visible = true
        val previousAppearance = appearance
        readAppearance()
        if (appearance != previousAppearance) { cancelPageWork(); appPage = 0; buildScreen() }
        getSharedPreferences("appearance", MODE_PRIVATE).registerOnSharedPreferenceChangeListener(appearanceChanged)
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
        getSharedPreferences("appearance", MODE_PRIVATE).unregisterOnSharedPreferenceChangeListener(appearanceChanged)
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
        if (intent.hasCategory(Intent.CATEGORY_HOME)) showPage(Page.HOME)
        if (page == Page.HOME || page == Page.APPS) focusFirstApp()
    }

    @Deprecated("Android 11 uses the platform back callback")
    override fun onBackPressed() {
        if (page != Page.HOME) {
            showPage(Page.HOME)
            focusFirstApp()
        } else if (intent.hasCategory(Intent.CATEGORY_HOME)) {
            scroll.smoothScrollTo(0, 0)
            focusFirstApp()
        } else super.onBackPressed()
    }

    private fun buildScreen() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(48), dp(48), dp(48), dp(48))
            background = HomeBackdrop()
        }
        val header = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        val navigation = LinearLayout(this).apply { gravity = Gravity.CENTER }
        header.addView(View(this), LinearLayout.LayoutParams(dp(132), dp(48)))
        header.addView(navigation, LinearLayout.LayoutParams(0, dp(56), 1f))
        homeTab = pageButton(R.string.home_page) { showPage(Page.HOME) }
        appsTab = pageButton(R.string.apps_page) { showPage(Page.APPS) }
        settingsTab = pageButton(R.string.settings) { showPage(Page.SETTINGS) }
        appearance.order.split(',').forEach { name ->
            navigation.addView(when (name) { "APPS" -> appsTab; "SETTINGS" -> settingsTab; else -> homeTab }, buttonParams())
        }
        header.addView(iconButton(R.drawable.ic_search, getString(R.string.search_apps)) { openSearch() },
            LinearLayout.LayoutParams(dp(48), dp(48)).apply { marginStart = dp(12) })
        header.addView(TextClock(this).apply {
            format12Hour = "h:mm a"
            format24Hour = "HH:mm"
            textSize = 18f
            setTextColor(getColor(R.color.text))
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            setPadding(dp(20), 0, 0, 0)
        }, LinearLayout.LayoutParams(-2, dp(48)))
        root.addView(header)
        search = EditText(this).apply {
            id = View.generateViewId()
            hint = getString(R.string.search_apps)
            textSize = 20f
            setTextColor(getColor(R.color.text))
            setSingleLine(true)
            inputType = android.text.InputType.TYPE_CLASS_TEXT
            imeOptions = android.view.inputmethod.EditorInfo.IME_ACTION_SEARCH
        }
        pageArea = FrameLayout(this)
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
            setPadding(0, dp(4), 0, 0)
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
        pageContent = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        utilityScroll = ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            addView(pageContent, FrameLayout.LayoutParams(-1, -2))
        }
        pageArea.addView(scroll, FrameLayout.LayoutParams(-1, -1))
        pageArea.addView(status, FrameLayout.LayoutParams(-1, -1))
        pageArea.addView(utilityScroll, FrameLayout.LayoutParams(-1, -1))
        root.addView(pageArea, LinearLayout.LayoutParams(-1, 0, 1f).apply { topMargin = dp(20) })
        pager = LinearLayout(this).apply { gravity = Gravity.CENTER_VERTICAL }
        pager.addView(iconButton(R.drawable.ic_previous, getString(R.string.previous_page)) { changeAppPage(-1) },
            LinearLayout.LayoutParams(dp(48), dp(48)))
        pageCounter = TextView(this).apply {
            textSize = 16f
            gravity = Gravity.CENTER
            setTextColor(getColor(R.color.muted))
        }
        pager.addView(pageCounter, LinearLayout.LayoutParams(0, dp(48), 1f))
        pager.addView(iconButton(R.drawable.ic_next, getString(R.string.next_page)) { changeAppPage(1) },
            LinearLayout.LayoutParams(dp(48), dp(48)))
        root.addView(pager)
        setContentView(root)
        updateTabs()
        if (page == Page.SETTINGS) renderPage()
    }

    private fun pageButton(label: Int, action: () -> Unit) = Button(this).apply {
        id = View.generateViewId()
        setText(label)
        textSize = 18f
        isAllCaps = false
        minWidth = 0
        setTextColor(android.content.res.ColorStateList(
            arrayOf(intArrayOf(android.R.attr.state_focused), intArrayOf(android.R.attr.state_selected), intArrayOf()),
            intArrayOf(getColor(R.color.text), getColor(R.color.focus_soft), getColor(R.color.muted))
        ))
        setPadding(dp(16), 0, dp(16), 0)
        background = underlineBackground()
        stateListAnimator = null
        setOnClickListener { action() }
        setOnFocusChangeListener { _, focused ->
            if (focused && !rebuilding) action()
            updateTabs()
        }
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

    private fun underlineBackground(panel: Boolean = false): StateListDrawable {
        fun shape(active: Boolean, pressed: Boolean = false): android.graphics.drawable.Drawable {
            val fill = GradientDrawable().apply {
                cornerRadius = dp(12).toFloat()
                setColor(if (panel) getColor(R.color.surface) else android.graphics.Color.TRANSPARENT)
                if (pressed) alpha = 170
            }
            if (!active) return fill
            val line = GradientDrawable().apply { setColor(getColor(R.color.focus)) }
            return LayerDrawable(arrayOf(fill, line)).apply {
                setLayerHeight(1, dp(2))
                setLayerGravity(1, Gravity.BOTTOM)
                setLayerInset(1, dp(16), 0, dp(16), 0)
            }
        }
        return StateListDrawable().apply {
            addState(intArrayOf(android.R.attr.state_pressed), shape(true, true))
            addState(intArrayOf(android.R.attr.state_focused), shape(true))
            addState(intArrayOf(android.R.attr.state_selected), shape(true))
            addState(intArrayOf(), shape(false))
        }
    }

    private fun focusBackground(radius: Int = 20, navigation: Boolean = false) = underlineBackground(panel = true)

    private fun updateTabs() {
        pager.visibility = if (page == Page.SETTINGS) View.GONE else View.VISIBLE
        homeTab.isSelected = page == Page.HOME
        appsTab.isSelected = allAppsPage
        settingsTab.isSelected = page == Page.SETTINGS
        listOf(homeTab, appsTab, settingsTab).forEach {
            it.typeface = Typeface.create("sans-serif", if (it.isSelected || it.hasFocus()) Typeface.BOLD else Typeface.NORMAL)
        }
    }

    private fun showPage(target: Page) {
        if (page == target) return
        main.removeCallbacks(filterAfterTyping)
        page = target
        appPage = 0
        (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager)
            .hideSoftInputFromWindow(search.windowToken, 0)
        updateTabs()
        scroll.scrollTo(0, 0)
        utilityScroll.scrollTo(0, 0)
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
        if (catalog.isEmpty() && (page == Page.HOME || page == Page.APPS)) setStatus(R.string.loading)
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
                    if (page == Page.HOME || page == Page.APPS || pageContent.childCount == 0) renderPage()
                    if (currentFocus == null && (page == Page.HOME || page == Page.APPS)) focusFirstApp()
                }.onFailure {
                    if (page == Page.HOME || page == Page.APPS) setStatus(R.string.load_failed)
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
        utilityScroll.visibility = View.GONE
        (pageCounter.parent as View).visibility = if (page == Page.SETTINGS) View.GONE else View.VISIBLE
    }

    private fun renderPage() {
        // Removing a focused child makes Android search for another focus target.
        // Do not let that temporary header focus switch the current page.
        rebuilding = true
        try { renderPageContents() } finally { rebuilding = false }
    }

    private fun renderPageContents() {
        val focusedTile = tiles.firstOrNull { it.view.hasFocus() }
        val focusKey = focusedTile?.entry?.key
        val starFocused = focusedTile?.star?.hasFocus() == true
        cancelPageWork()
        grid.removeAllViews()
        tiles.clear()
        pageContent.removeAllViews()
        utilityScroll.visibility = View.GONE
        if (page == Page.SETTINGS) {
            status.visibility = View.GONE
            scroll.visibility = View.GONE
            utilityScroll.visibility = View.VISIBLE
            pageCounter.text = ""
            renderUtilityPage()
            return
        }
        grid.columnCount = columns
        val matching = if (allAppsPage) searchApps(catalog, searchQuery) else favoriteApps(catalog, favorites)
        val totalPages = pageCount(matching.size, columns)
        appPage = appPage.coerceIn(0, (totalPages - 1).coerceAtLeast(0))
        val entries = appSlice(matching, appPage, columns)
        pageCounter.text = if (totalPages > 0) getString(R.string.page_number, appPage + 1, totalPages) else ""
        pageCounter.contentDescription = pageCounter.text
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
                width = tileWidth(if (grid.width > 0) grid.width else resources.displayMetrics.widthPixels - dp(96))
                height = width * 9 / 16
                setMargins(if (index % columns == 0) 0 else dp(20), 0, 0, dp(20))
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
            val down = if (index < columns && tiles.size > columns) tiles.getOrNull(minOf(index + columns, tiles.lastIndex)) else null
            tile.view.nextFocusUpId = up?.view?.id ?: if (allAppsPage) appsTab.id else homeTab.id
            tile.view.nextFocusDownId = down?.view?.id ?: tile.view.id
            tile.star?.nextFocusUpId = up?.star?.id ?: appsTab.id
            tile.star?.nextFocusDownId = down?.star?.id ?: tile.star.id
        }
        val previous = tiles.firstOrNull { it.entry.key == focusKey }
        if (previous != null) (if (starFocused) previous.star ?: previous.view else previous.view).requestFocus()
        else if (focusKey != null) focusFirstApp()
        grid.post { loadVisibleIcons() }
    }

    // Keep a short favorites row compact instead of stretching three icons across the TV.
    private fun tileWidth(availableWidth: Int) = ((availableWidth - dp(20) * (columns - 1)) / columns).coerceAtLeast(dp(48))

    private fun resizeTiles(availableWidth: Int) {
        tiles.forEach { tile ->
            tile.view.layoutParams = tile.view.layoutParams.apply { width = tileWidth(availableWidth); height = width * 9 / 16 }
        }
    }

    private fun makeTile(entry: AppEntry): Tile {
        val cell = FrameLayout(this).apply {
            id = View.generateViewId()
            isFocusable = true
            isClickable = true
            descendantFocusability = ViewGroup.FOCUS_BEFORE_DESCENDANTS
            contentDescription = displayLabel(entry)
            setOnClickListener { openApp(entry) }
        }
        cell.background = null
        cell.setOnFocusChangeListener { view, focused ->
            val scale = if (focused) 1.045f else 1f
            view.animate().cancel()
            val duration = if (Settings.Global.getFloat(contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f) 0L else 150L
            view.animate().scaleX(scale).scaleY(scale).alpha(if (focused) 1f else .88f).setDuration(duration).start()
            if (focused) pageCounter.text = "${displayLabel(entry)}  ·  ${appPage + 1} / ${pageCount(if (allAppsPage) searchApps(catalog, searchQuery).size else favoriteApps(catalog, favorites).size, columns)}  ·  удерживайте OK для избранного"
        }
        val image = ImageView(this).apply {
            scaleType = ImageView.ScaleType.FIT_CENTER
            setPadding(0, 0, 0, 0)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        cell.addView(image, FrameLayout.LayoutParams(-1, -1))
        val label = TextView(this).apply {
            text = displayLabel(entry); textSize = 17f; gravity = Gravity.CENTER
            setTextColor(getColor(R.color.text)); setPadding(dp(8), 0, dp(8), 0)
            isSingleLine = true; ellipsize = TextUtils.TruncateAt.END
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        cell.addView(label, FrameLayout.LayoutParams(-1, -1))
        image.tag = label
        fun editFavorite() {
            val openingDownTime = heldConfirmDownTime
            val confirmation = DialogConfirmGate(openingDownTime)
            val actions = mutableListOf(getString(if (entry.packageName in favorites)
                R.string.remove_favorite else R.string.add_favorite, displayLabel(entry)))
            val favoriteIndex = favorites.indexOf(entry.packageName)
            if (favoriteIndex > 0) actions.add("Переместить левее")
            if (favoriteIndex >= 0 && favoriteIndex < favorites.lastIndex) actions.add("Переместить правее")
            actions.add("О приложении")
            val dialog = AlertDialog.Builder(this).setTitle(displayLabel(entry)).setItems(actions.toTypedArray()) { _, index ->
                when (actions[index]) {
                    "Переместить левее" -> favorites = moveFavorite(favorites, entry.packageName, -1)
                    "Переместить правее" -> favorites = moveFavorite(favorites, entry.packageName, 1)
                    "О приложении" -> launchSafely(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:${entry.packageName}")), R.string.settings_failed)
                    else -> favorites = toggleFavorite(favorites, entry.packageName)
                }
                saveFavorites(); renderPage()
            }.setNegativeButton(R.string.cancel, null).create()
            dialog.setOnKeyListener { _, key, event ->
                if (isConfirmKey(key) && (event.action == KeyEvent.ACTION_DOWN || event.action == KeyEvent.ACTION_UP)) {
                    if (event.action == KeyEvent.ACTION_UP && event.downTime == openingDownTime) heldConfirmDownTime = null
                    confirmation.consume(event.downTime, event.action == KeyEvent.ACTION_DOWN, event.repeatCount)
                } else false
            }
            dialog.setOnDismissListener { if (heldConfirmDownTime == openingDownTime) heldConfirmDownTime = null }
            dialog.show()
        }
        cell.setOnLongClickListener { editFavorite(); true }
        cell.setOnKeyListener { _, key, event ->
            if (event.action != KeyEvent.ACTION_DOWN) false
            else when {
                key == KeyEvent.KEYCODE_MENU -> { editFavorite(); true }
                key == KeyEvent.KEYCODE_DPAD_RIGHT && tiles.indexOfFirst { it.view == cell }.let { it >= 0 && (it % columns == columns - 1 || it == tiles.lastIndex) } ->
                    changeAppPage(1, sourceIndex = tiles.indexOfFirst { it.view == cell })
                key == KeyEvent.KEYCODE_DPAD_LEFT && tiles.indexOfFirst { it.view == cell }.let { it >= 0 && it % columns == 0 } ->
                    changeAppPage(-1, last = true, sourceIndex = tiles.indexOfFirst { it.view == cell })
                else -> false
            }
        }
        val star: ImageButton? = null
        return Tile(entry, cell, image, star)
    }

    private fun focusFirstApp() {
        (tiles.firstOrNull()?.view ?: appsTab).requestFocus()
    }

    private fun applyTileTitle(tile: Tile, bitmap: Bitmap) {
        val label = tile.image.tag as TextView
        val show = appearance.titles == "show" || (appearance.titles == "auto" && bitmap.width <= bitmap.height)
        label.visibility = if (show) View.VISIBLE else View.GONE
        label.gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
        label.setPadding(dp(4), 0, dp(4), dp(2))
        tile.image.setPadding(0, 0, 0, if (show) dp(24) else 0)
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
            if (cached != null) {
                tile.image.setImageBitmap(cached)
                applyTileTitle(tile, cached)
                continue
            }
            if (!pendingIcons.add(key)) continue
            worker?.submit {
                if (Thread.currentThread().isInterrupted) return@submit
                val bitmap = runCatching {
                    val component = ComponentName(tile.entry.packageName, tile.entry.activityName)
                    val banner = runCatching { packageManager.getActivityBanner(component) }.getOrNull()
                    val drawable = banner ?: packageManager.getActivityIcon(component)
                    val height = dp(if (banner != null) 108 else 58)
                    val aspect = if (drawable.intrinsicWidth > 0 && drawable.intrinsicHeight > 0)
                        drawable.intrinsicWidth.toFloat() / drawable.intrinsicHeight else 1f
                    val width = (height * aspect.coerceIn(0.5f, 16f / 9f)).roundToInt()
                    Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
                        drawable.setBounds(0, 0, width, height)
                        drawable.draw(Canvas(it))
                    }
                }.getOrNull()
                main.post {
                    if (!visible || pageGeneration != page) return@post
                    pendingIcons.remove(key)
                    if (bitmap != null) {
                        icons.put(key, bitmap)
                        tile.image.setImageBitmap(bitmap)
                        applyTileTitle(tile, bitmap)
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

    private fun displayLabel(entry: AppEntry): String = if (entry.packageName in
        setOf("com.aengix.tvbrowser", "net.mrowser", "com.phlox.tvwebbrowser")) getString(R.string.browser) else if (entry.packageName == "com.metzrevive.display") "METZ Display"
        else entry.label.ifBlank { entry.packageName.substringAfterLast('.') }

    private fun utilityAction(label: Int, icon: Int = R.drawable.ic_settings, action: () -> Unit) {
        pageContent.addView(Button(this).apply {
            id = View.generateViewId()
            setText(label)
            textSize = 18f
            isAllCaps = false
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
            setTextColor(getColor(R.color.text))
            setPadding(dp(24), 0, dp(24), 0)
            setCompoundDrawablesRelativeWithIntrinsicBounds(icon, 0, 0, 0)
            compoundDrawablePadding = dp(20)
            background = focusBackground()
            stateListAnimator = null
            setOnClickListener { action() }
        }, LinearLayout.LayoutParams(-1, dp(64)).apply { bottomMargin = dp(6) })
    }

    private fun renderUtilityPage() {
        utilityAction(R.string.cast_settings) {
            val enabled = runCatching { packageManager.getApplicationInfo("com.google.android.apps.mediashell", 0).enabled }.getOrDefault(false)
            if (enabled) AlertDialog.Builder(this).setTitle(R.string.cast_page)
                .setMessage(R.string.cast_help).setPositiveButton(R.string.cast_settings) { _, _ ->
                    launchSafely(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                        Uri.parse("package:com.google.android.apps.mediashell")), R.string.settings_failed)
                }.setNegativeButton(R.string.close, null).show()
            else Toast.makeText(this, R.string.cast_unavailable, Toast.LENGTH_LONG).show()
        }
        utilityAction(R.string.tv_settings) { launchSafely(Intent(Settings.ACTION_SETTINGS), R.string.settings_failed) }
        utilityAction(R.string.choose_home) {
            AlertDialog.Builder(this).setTitle(R.string.choose_home)
                        .setMessage(R.string.enable_home_message)
                        .setPositiveButton(R.string.enable_home) { _, _ ->
                            packageManager.setComponentEnabledSetting(ComponentName(this, "$packageName.HomeEntry"),
                                PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP)
                            launchSafely(Intent(Settings.ACTION_HOME_SETTINGS), R.string.settings_failed)
                        }.setNegativeButton(R.string.cancel, null).show()
        }
        utilityAction(R.string.mac_keyboard) {
            launchSafely(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS), R.string.settings_failed)
        }
        utilityAction(R.string.edit_favorites, R.drawable.ic_home) {
            val names = catalog.map { displayLabel(it) }.toTypedArray()
            val checked = catalog.map { it.packageName in favorites }.toBooleanArray()
            var edited = favorites.toList()
            AlertDialog.Builder(this).setTitle(R.string.edit_favorites)
                .setMultiChoiceItems(names, checked) { _, index, selected ->
                    val name = catalog[index].packageName
                    edited = if (selected) (edited + name).distinct() else edited.filterNot { it == name }
                }.setPositiveButton("Сохранить") { _, _ -> favorites = edited; saveFavorites(); renderPage() }
                .setNegativeButton(R.string.cancel, null).show()
        }
        utilityAction(R.string.refresh, R.drawable.ic_refresh) { refreshApps() }
        utilityAction(R.string.stock_home, R.drawable.ic_home) { openStockHome() }
    }

    private fun openSearch() {
        (search.parent as? ViewGroup)?.removeView(search)
        search.setText(searchQuery)
        search.setSelectAllOnFocus(true)
        search.setHintTextColor(getColor(R.color.muted))
        search.setPadding(dp(20), dp(12), dp(20), dp(12))
        search.background = GradientDrawable().apply { cornerRadius = dp(12).toFloat(); setColor(getColor(R.color.surface)); setStroke(dp(2), getColor(R.color.focus)) }
        val container = LinearLayout(this).apply { setPadding(dp(24), dp(16), dp(24), dp(16)); addView(search, LinearLayout.LayoutParams(-1, dp(60))) }
        val dialog = AlertDialog.Builder(this).setTitle("Поиск приложений").setView(container)
            .setPositiveButton(R.string.find, null).setNeutralButton(R.string.clear_search, null)
            .setNegativeButton(R.string.cancel, null).create()
        fun applyQuery(value: String) {
            searchQuery = value
            dialog.dismiss()
            showPage(Page.APPS); appPage = 0; renderPage(); focusFirstApp()
        }
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener { applyQuery(search.text.toString().trim()) }
            dialog.getButton(AlertDialog.BUTTON_NEUTRAL).setOnClickListener { applyQuery("") }
            search.requestFocus()
            search.setOnEditorActionListener { _, _, _ -> applyQuery(search.text.toString().trim()); true }
        }
        dialog.show()
    }

    private fun changeAppPage(delta: Int, last: Boolean = false, sourceIndex: Int = 0): Boolean {
        if (page == Page.SETTINGS) return false
        val entries = if (allAppsPage) searchApps(catalog, searchQuery) else favoriteApps(catalog, favorites)
        val next = appPage + delta
        if (next !in 0 until pageCount(entries.size, columns)) return false
        appPage = next
        renderPage()
        rebuilding = true
        try { tiles.getOrNull(pageEntryIndex(sourceIndex, tiles.size, !last, columns))?.view?.requestFocus() }
        finally { rebuilding = false }
        return true
    }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            touchStartX = event.x
            touchStartY = event.y
        } else if (event.actionMasked == MotionEvent.ACTION_UP &&
            kotlin.math.abs(event.x - touchStartX) > dp(70) &&
            kotlin.math.abs(event.x - touchStartX) > kotlin.math.abs(event.y - touchStartY) * 1.5f) {
            val cancel = MotionEvent.obtain(event).apply { action = MotionEvent.ACTION_CANCEL }
            super.dispatchTouchEvent(cancel)
            cancel.recycle()
            changeAppPage(if (event.x < touchStartX) 1 else -1)
            return true
        }
        return super.dispatchTouchEvent(event)
    }

    private fun isConfirmKey(key: Int) = key == KeyEvent.KEYCODE_DPAD_CENTER ||
        key == KeyEvent.KEYCODE_ENTER || key == KeyEvent.KEYCODE_NUMPAD_ENTER || key == KeyEvent.KEYCODE_SPACE

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (isConfirmKey(event.keyCode)) {
            if (event.action == KeyEvent.ACTION_DOWN) heldConfirmDownTime = event.downTime
            else if (event.action == KeyEvent.ACTION_UP) heldConfirmDownTime = null
        }
        return super.dispatchKeyEvent(event)
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).roundToInt()
}
