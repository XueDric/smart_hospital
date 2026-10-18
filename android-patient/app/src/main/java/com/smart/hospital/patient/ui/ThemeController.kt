package com.smart.hospital.patient.ui

import android.app.Activity
import android.content.Context
import android.content.res.ColorStateList
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.view.ContextThemeWrapper
import android.view.View
import android.view.ViewGroup
import android.widget.CompoundButton
import android.widget.ImageView
import android.widget.TextView
import com.smart.hospital.patient.R

/** Changes appearance in place: no Activity recreation, navigation or network work. */
object ThemeController {
    enum class Mode(val value: String) { AUTO("auto"), LIGHT("light"), DARK("dark") }

    private const val PREFERENCES = "app_theme"
    private const val KEY_MODE = "theme_mode"

    fun currentMode(context: Context): Mode {
        val value = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(KEY_MODE, "auto")
        return Mode.values().firstOrNull { it.value == value } ?: Mode.AUTO
    }

    fun setMode(context: Context, mode: Mode) {
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().putString(KEY_MODE, mode.value).apply()
    }

    /** The application context retains the system setting even when an Activity overrides it. */
    fun attachContext(base: Context): Context {
        val system = (base.applicationContext ?: base).resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
        val night = when (currentMode(base)) {
            Mode.AUTO -> system
            Mode.LIGHT -> Configuration.UI_MODE_NIGHT_NO
            Mode.DARK -> Configuration.UI_MODE_NIGHT_YES
        }
        if ((base.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == night) return base
        val configuration = Configuration(base.resources.configuration)
        configuration.uiMode = (configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or night
        return base.createConfigurationContext(configuration)
    }

    fun dialogContext(activity: Activity): Context = ContextThemeWrapper(attachContext(activity), R.style.AppTheme)

    /** Track the stroke because Android exposes no public GradientDrawable stroke getter. */
    fun rounded(fill: Int, stroke: Int?, radiusPx: Float, strokeWidthPx: Int): GradientDrawable =
        ThemeShape(fill, stroke, radiusPx, strokeWidthPx)

    private class ThemeShape(
        private var fill: Int,
        private var stroke: Int?,
        radius: Float,
        private val width: Int
    ) : GradientDrawable() {
        init {
            cornerRadius = radius
            paintColors()
        }
        private fun paintColors() {
            setColor(fill)
            stroke?.takeIf { it != Color.TRANSPARENT }?.let { setStroke(width, it) }
        }
        fun recolor(map: (Int) -> Int) {
            fill = map(fill)
            stroke = stroke?.let(map)
            paintColors()
        }
    }

    fun refresh(activity: Activity, root: View, previousPalette: HarmonyUi.Palette?): HarmonyUi.Palette {
        val next = HarmonyUi.palette(activity)
        if (previousPalette != null && previousPalette != next) {
            recolorTree(root, previousPalette, next)
        }
        activity.window.statusBarColor = next.bg
        activity.window.navigationBarColor = next.surface
        activity.window.setBackgroundDrawable(ColorDrawable(next.bg))
        val dark = (attachContext(activity).resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        val flags = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
        val current = activity.window.decorView.systemUiVisibility
        activity.window.decorView.systemUiVisibility = if (dark) current and flags.inv() else current or flags
        return next
    }

    private fun recolorTree(view: View, before: HarmonyUi.Palette, after: HarmonyUi.Palette) {
        fun background(color: Int): Int = mapColor(color, before, after, false)
        fun foreground(color: Int): Int = mapColor(color, before, after, true)
        when (val drawable = view.background) {
            is ThemeShape -> drawable.recolor(::background)
            is ColorDrawable -> drawable.color = background(drawable.color)
            is GradientDrawable -> drawable.color?.let { drawable.setColor(mapStates(it, ::background)) }
        }
        view.backgroundTintList?.let { view.backgroundTintList = mapStates(it, ::background) }
        if (view is TextView) {
            view.setTextColor(mapStates(view.textColors, ::foreground))
            view.hintTextColors?.let { view.setHintTextColor(mapStates(it, ::foreground)) }
            view.linkTextColors?.let { view.setLinkTextColor(mapStates(it, ::foreground)) }
            view.compoundDrawableTintList?.let { view.compoundDrawableTintList = mapStates(it, ::foreground) }
            view.highlightColor = after.primarySoft
        }
        if (view is CompoundButton) view.buttonTintList?.let { view.buttonTintList = mapStates(it, ::foreground) }
        if (view is ImageView) view.imageTintList?.let { view.imageTintList = mapStates(it, ::foreground) }
        if (view is ViewGroup) for (index in 0 until view.childCount) recolorTree(view.getChildAt(index), before, after)
        view.invalidate()
    }

    private fun mapColor(color: Int, before: HarmonyUi.Palette, after: HarmonyUi.Palette, text: Boolean): Int {
        // Light surface and primary-button text are both white; their roles differ.
        if (color == Color.TRANSPARENT) return color
        if (text && color == before.onPrimary) return after.onPrimary
        val old = intArrayOf(before.bg, before.surface, before.surfaceAlt, before.primary, before.primaryDark,
            before.primarySoft, before.ink, before.secondary, before.border, before.danger, before.dangerSoft,
            before.warning, before.warningSoft, before.success, before.successSoft, before.info, before.infoSoft,
            before.disabled)
        val new = intArrayOf(after.bg, after.surface, after.surfaceAlt, after.primary, after.primaryDark,
            after.primarySoft, after.ink, after.secondary, after.border, after.danger, after.dangerSoft,
            after.warning, after.warningSoft, after.success, after.successSoft, after.info, after.infoSoft,
            after.disabled)
        val index = old.indexOf(color)
        return if (index >= 0) new[index] else color
    }

    private fun mapStates(colors: ColorStateList, map: (Int) -> Int): ColorStateList {
        if (!colors.isStateful) return ColorStateList.valueOf(map(colors.defaultColor))
        // Preserve common native control states instead of flattening disabled/selected colors.
        val states = arrayOf(intArrayOf(-android.R.attr.state_enabled), intArrayOf(android.R.attr.state_pressed),
            intArrayOf(android.R.attr.state_checked), intArrayOf(android.R.attr.state_selected),
            intArrayOf(android.R.attr.state_focused), intArrayOf())
        return ColorStateList(states, states.map { map(colors.getColorForState(it, colors.defaultColor)) }.toIntArray())
    }
}
