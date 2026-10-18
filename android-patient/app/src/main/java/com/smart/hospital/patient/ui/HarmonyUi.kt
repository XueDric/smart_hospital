package com.smart.hospital.patient.ui

import android.content.Context
import com.smart.hospital.patient.R

/** Android dp/sp equivalents of common-core Theme.ets, including the saved theme preference. */
object HarmonyUi {
    const val PAGE_PADDING = 16
    const val CARD_PADDING = 20
    const val CARD_RADIUS = 8
    const val CONTROL_RADIUS = 8
    const val GAP = 12
    const val SECTION_GAP = 20
    const val HEADER_HEIGHT = 56
    const val NAV_HEIGHT = 64
    // Android touch targets remain 48dp even though Harmony's minimum is 40vp.
    const val TOUCH_MIN = 48
    const val CONTROL_HEIGHT = 48
    const val DISPLAY = 30f
    const val TITLE = 24f
    const val HEADING = 18f
    const val BODY = 16f
    const val CAPTION = 13f
    const val MICRO = 12f

    data class Palette(
        val bg: Int, val surface: Int, val surfaceAlt: Int,
        val primary: Int, val primaryDark: Int, val primarySoft: Int,
        val ink: Int, val secondary: Int, val border: Int,
        val danger: Int, val dangerSoft: Int, val warning: Int, val warningSoft: Int,
        val success: Int, val successSoft: Int, val info: Int, val infoSoft: Int,
        val disabled: Int, val onPrimary: Int
    )

    // Resolve after Activity attachment; never read Context during an Activity field initializer.
    fun palette(base: Context): Palette {
        val context = ThemeController.attachContext(base)
        return Palette(
            context.getColor(R.color.background), context.getColor(R.color.surface), context.getColor(R.color.surface_alt),
            context.getColor(R.color.primary), context.getColor(R.color.primary_dark), context.getColor(R.color.primary_soft),
            context.getColor(R.color.text), context.getColor(R.color.text_secondary), context.getColor(R.color.border),
            context.getColor(R.color.danger), context.getColor(R.color.danger_soft), context.getColor(R.color.warning),
            context.getColor(R.color.warning_soft), context.getColor(R.color.success), context.getColor(R.color.success_soft),
            context.getColor(R.color.info), context.getColor(R.color.info_soft), context.getColor(R.color.disabled),
            context.getColor(R.color.on_primary)
        )
    }
}
