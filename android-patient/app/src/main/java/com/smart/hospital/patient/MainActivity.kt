package com.smart.hospital.patient

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Build
import android.net.Uri
import android.text.Editable
import android.text.TextWatcher
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import android.widget.*
import com.smart.hospital.patient.data.*
import com.smart.hospital.patient.model.*
import com.smart.hospital.patient.ui.HarmonyUi
import com.smart.hospital.patient.ui.ThemeController
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : Activity() {
    // Resource colors are resolved after attachment and may change without rebuilding views.
    private val palette get() = HarmonyUi.palette(this)
    private val bg get() = palette.bg
    private val surface get() = palette.surface
    private val primary get() = palette.primary
    private val primaryDark get() = palette.primaryDark
    private val primarySoft get() = palette.primarySoft
    private val ink get() = palette.ink
    private val secondary get() = palette.secondary
    private val border get() = palette.border
    private val danger get() = palette.danger
    private val dangerSoft get() = palette.dangerSoft
    private val warning get() = palette.warning
    private val warningSoft get() = palette.warningSoft
    private val success get() = palette.success
    private val successSoft get() = palette.successSoft
    private val info get() = palette.info
    private val infoSoft get() = palette.infoSoft
    private var themePalette: HarmonyUi.Palette? = null
    private val main = FrameLayout.LayoutParams(-1, -1)
    private lateinit var session: SessionStore
    private lateinit var repo: PatientRepository
    private lateinit var api: ApiClient
    private lateinit var content: FrameLayout
    private val executor: ExecutorService = Executors.newFixedThreadPool(3)
    // ⚠ 必须 lazy：字段初始化发生在 Activity 构造期，那时 attachBaseContext 还没执行，
    //   getMainLooper() 返回 null，直接 new Handler(mainLooper) 会抛
    //   NullPointerException: Attempt to invoke ... Context.getMainLooper() on a null object reference
    //   → Unable to instantiate activity（启动即崩，编译期不报错）。
    private val ui: android.os.Handler by lazy { android.os.Handler(mainLooper) }
    private val stack = ArrayDeque<Screen>()
    private var current = Screen.LOGIN
    private var triageResult: TriageResult? = null
    private var selectedSchedule: Schedule? = null
    private var previsit: PrevisitSession? = null
    private var attachPrevisit = false
    private var previsitValue: EditText? = null
    private var triageDraft = ""
    private var bookingDate = ""
    private var bookingDepartment = ""
    private var bookingDoctor = ""
    private var bookingPeriod = ""
    private var profileAddressDraft: String? = null
    private var previsitDraft = ""
    private var loginNotice = ""
    private var loginBusy = false
    private var loginButton: Button? = null
    private var loginMessage: TextView? = null
    private var renderVersion = 0
    private var recordAppointmentId = 0L
    private var backCallback: OnBackInvokedCallback? = null
    private var lastBackAt = 0L
    private var cooldownBanner: TextView? = null
    private var logoutBusy = false
    private val networkButtons = mutableListOf<NetworkButton>()
    private var appointmentOutcome = ""
    private var appointmentOutcomeWarning = false

    private enum class Screen { LOGIN, HOME, TRIAGE, PREVISIT, BOOKING, APPOINTMENTS, RECORDS, RECORD_DETAIL, PROFILE, NOTICES }

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(ThemeController.attachContext(newBase))
    }

    private fun refreshTheme() {
        if (this::content.isInitialized) themePalette = ThemeController.refresh(this, content, themePalette)
    }

    override fun onResume() {
        super.onResume()
        refreshTheme()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        refreshTheme()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        themePalette = palette
        session = SessionStore(this)
        api = ApiClient(session)
        repo = PatientRepository(api, session)
        if (session.isLoggedIn() && session.role == "doctor") {
            startActivity(Intent(this, DoctorActivity::class.java)); finish(); return
        }
        content = FrameLayout(this).apply { setBackgroundColor(bg) }
        setContentView(content)
        applySafeAreaInsets()
        if (Build.VERSION.SDK_INT >= 33) {
            backCallback = OnBackInvokedCallback { handleBack() }.also {
                onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, it)
            }
        }
        if (session.isLoggedIn()) {
            show(Screen.HOME, true)
            // The server renews online tokens. An old local expiry is not authoritative.
            runAsync({ repo.me() }, { render() }, { error -> toast(userMessage(error)) })
        } else { session.clearLogin(); show(Screen.LOGIN, true) }
    }

    private fun applySafeAreaInsets() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            content.setOnApplyWindowInsetsListener { view, insets ->
                // Absolute padding avoids accumulating insets across renders/IME changes.
                val safe = insets.getInsets(WindowInsets.Type.systemBars() or
                    WindowInsets.Type.displayCutout() or WindowInsets.Type.ime())
                view.setPadding(safe.left, safe.top, safe.right, safe.bottom)
                WindowInsets.CONSUMED
            }
            content.requestApplyInsets()
        }
        // Older versions retain the framework's fitted window and adjustResize behavior.
    }

    @Deprecated("Legacy Android back callback")
    override fun onBackPressed() = handleBack()
    private fun handleBack() {
        if (logoutBusy) { toast(getString(R.string.logout_pending)); return }
        if (stack.size > 1) { stack.removeLast(); current = stack.last(); render() }
        else if (current != Screen.LOGIN && current != Screen.HOME) show(Screen.HOME, true)
        else if (System.currentTimeMillis() - lastBackAt < 2000) finish()
        else { lastBackAt = System.currentTimeMillis(); toast(getString(R.string.back_exit_again)) }
    }

    override fun onDestroy() {
        if (Build.VERSION.SDK_INT >= 33) backCallback?.let { onBackInvokedDispatcher.unregisterOnBackInvokedCallback(it) }
        ui.removeCallbacksAndMessages(null)
        executor.shutdownNow(); super.onDestroy()
    }

    private fun show(screen: Screen, reset: Boolean = false) {
        if (logoutBusy && screen != Screen.LOGIN) { toast(getString(R.string.logout_pending)); return }
        if (reset) { stack.clear(); stack.addLast(screen) } else if (stack.lastOrNull() != screen) stack.addLast(screen)
        current = screen; render()
    }
    private fun render() {
        renderVersion++
        networkButtons.clear()
        loginButton = null; loginMessage = null
        content.removeAllViews()
        val page = when (current) {
            Screen.LOGIN -> loginView()
            Screen.HOME -> homeView()
            Screen.TRIAGE -> triageView()
            Screen.PREVISIT -> previsitView()
            Screen.BOOKING -> bookingView()
            Screen.APPOINTMENTS -> appointmentsView()
            Screen.PROFILE -> profileView()
            Screen.RECORDS -> recordsView()
            Screen.RECORD_DETAIL -> recordDetailView()
            Screen.NOTICES -> noticesView()
        }
        val wrapper = vertical()
        if (session.mockMode) wrapper.addView(banner(getString(R.string.demo_notice), warningSoft, warning), lp(-1, -2))
        cooldownBanner = banner("", warningSoft, warning).apply { id = R.id.cooldown_banner; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }.also { wrapper.addView(it, lp(-1, -2)) }
        wrapper.addView(page, lp(-1, 0).also { it.weight = 1f })
        content.addView(wrapper, main)
        updateCooldownBanner(renderVersion)
    }

    private fun loginView(): View {
        val scroll = ScrollView(this).apply { isFillViewport = true }
        val box = bodyColumn().apply { setPadding(dp(HarmonyUi.PAGE_PADDING), 0, dp(HarmonyUi.PAGE_PADDING), dp(32)) }
        val brand = vertical().apply {
            setPadding(0, dp(72), 0, dp(32)); gravity = Gravity.CENTER_HORIZONTAL
            addView(textView(getString(R.string.app_name), HarmonyUi.DISPLAY, ink, true))
            addView(textView(getString(R.string.ui_patient_role), HarmonyUi.BODY, primaryDark), spaced(6))
            addView(textView(getString(R.string.ui_patient_services), HarmonyUi.CAPTION, secondary).apply {
                gravity = Gravity.CENTER
            }, spaced(HarmonyUi.GAP))
        }
        box.addView(brand, lp(-1, -2))
        val form = cardColumn()
        val modeRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(3), dp(3), dp(3), dp(3))
            background = rounded(surface_alt(), Color.TRANSPARENT, HarmonyUi.CONTROL_RADIUS)
        }
        modeRow.addView(textView(getString(R.string.online_mode_label), HarmonyUi.CAPTION, primaryDark).apply {
            gravity = Gravity.CENTER
            background = rounded(primarySoft, Color.TRANSPARENT, HarmonyUi.CONTROL_RADIUS)
            minHeight = dp(HarmonyUi.TOUCH_MIN)
        }, LinearLayout.LayoutParams(0, -2, 1f))
        form.addView(modeRow, lp(-1, -2))
        val name = edit(getString(R.string.login_name_hint), session.lastLoginName).apply { id = R.id.login_name; isSingleLine = true }
        remember(name) { session.lastLoginName = it }
        val password = edit(getString(R.string.login_password_hint)).apply {
            id = R.id.login_password
            isSingleLine = true; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setSaveEnabled(false)
        }
        form.addView(fieldLabel(getString(R.string.ui_login_account), name, true), spaced(HarmonyUi.SECTION_GAP))
        form.addView(name, lp(-1, dp(HarmonyUi.CONTROL_HEIGHT)))
        form.addView(fieldLabel(getString(R.string.ui_login_password), password, true), spaced(HarmonyUi.GAP))
        form.addView(password, lp(-1, dp(HarmonyUi.CONTROL_HEIGHT)))
        val message = messageView(loginNotice, dangerSoft, danger).apply { id = R.id.login_message }
        form.addView(message, spaced(HarmonyUi.GAP))
        val submit = networkButton(getString(R.string.login_action), true).apply { id = R.id.login_submit }
        form.addView(submit, lp(-1, dp(HarmonyUi.CONTROL_HEIGHT)).also { it.topMargin = dp(HarmonyUi.SECTION_GAP) })
        loginButton = submit; loginMessage = message
        if (BuildConfig.DEBUG) {
            val demo = button(getString(R.string.demo_enter), false)
            demo.text = getString(R.string.ui_demo_mode_action)
            demo.contentDescription = getString(R.string.demo_enter)
            demo.textSize = HarmonyUi.CAPTION
            modeRow.addView(demo, LinearLayout.LayoutParams(0, dp(HarmonyUi.CONTROL_HEIGHT), 1f).also { it.marginStart = dp(4) })
            demo.setOnClickListener {
                if (loginBusy) return@setOnClickListener
                clearPatientState(); session.switchMode(true); session.saveLogin(repo.enterDemo())
                password.text?.clear(); loginNotice = ""; show(Screen.HOME, true)
            }
        }
        form.addView(button(getString(R.string.ui_doctor_entry), false).apply {
            setOnClickListener { if (!loginBusy) { startActivity(Intent(this@MainActivity,DoctorActivity::class.java)); finish() } }
        }, spaced(HarmonyUi.GAP))
        val address = button(getString(R.string.service_address_setup), false); form.addView(address, spaced(HarmonyUi.GAP))
        address.setOnClickListener { if (!loginBusy) editServiceAddress() }
        form.addView(textView(getString(R.string.login_mode_note), HarmonyUi.MICRO, secondary), spaced(HarmonyUi.GAP))
        box.addView(form, lp(-1, -2))
        box.addView(banner(getString(R.string.ui_emergency_notice), warningSoft, warning), spaced(HarmonyUi.SECTION_GAP))
        submit.setOnClickListener {
            if (api.isCoolingDown()) { updateLoginCooldown(); return@setOnClickListener }
            val loginName = name.text.toString().trim(); val secret = password.text.toString()
            if (loginName.isBlank() || secret.isBlank()) { message.text = getString(R.string.login_required); return@setOnClickListener }
            loginBusy = true; loginNotice = ""; message.text = ""; updateLoginCooldown()
            runAsync({
                val result = repo.login(loginName, secret)
                val address = session.baseUrl
                session.saveLogin(result)
                try {
                    val identity = repo.me()
                    if (identity.role != "patient" || identity.userId != result.userId || identity.patientId != result.patientId)
                        throw ApiException(403, "FORBIDDEN_ROLE", getString(R.string.login_patient_required))
                    result
                } catch (error: Exception) {
                    session.clearLoginIfCurrent(result.token, address)
                    throw error
                }
            }, { _ ->
                password.text?.clear(); clearPatientState(); show(Screen.HOME, true)
            }, { error ->
                loginBusy = false; password.text?.clear(); loginNotice = userMessage(error)
                message.text = loginNotice; updateLoginCooldown()
            })
        }
        updateLoginCooldown(); scroll.addView(box); return scroll
    }

    private fun homeView(): View {
        val root = vertical()
        val body = bodyColumn()
        body.addView(textView(getString(R.string.home_greeting, session.displayName.ifBlank { getString(R.string.patient_fallback) }), HarmonyUi.TITLE, ink, true), spaced(HarmonyUi.GAP))
        body.addView(textView(getString(R.string.home_subtitle), HarmonyUi.BODY, secondary), spaced(6))
        val visit = cardColumn()
        visit.addView(textView(getString(R.string.ui_next_visit), HarmonyUi.CAPTION, secondary))
        val notice = textView(getString(R.string.appointments_syncing), HarmonyUi.BODY, ink)
        visit.addView(notice, spaced(HarmonyUi.GAP)); body.addView(visit, spaced(HarmonyUi.SECTION_GAP))
        addPendingBookings(body)
        val retry = networkButton(getString(R.string.sync_retry), false); visit.addView(retry, spaced(HarmonyUi.GAP))
        val quick = vertical(); quick.addView(sectionTitle(getString(R.string.ui_common_services)))
        val actions = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val quickLabels = listOf(R.string.triage_title, R.string.previsit_title, R.string.booking_title, R.string.records_title)
        val quickDescriptions = listOf(R.string.ui_quick_triage, R.string.ui_quick_previsit, R.string.ui_quick_booking, R.string.ui_quick_records)
        listOf(Screen.TRIAGE, Screen.PREVISIT, Screen.BOOKING, Screen.RECORDS).forEachIndexed { index, target ->
            val label = getString(quickLabels[index])
            val action = vertical().apply {
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(dp(4), dp(HarmonyUi.GAP), dp(4), dp(HarmonyUi.GAP))
                minimumHeight = dp(128)
                isFocusable = true; isClickable = true
                contentDescription = "$label，${getString(quickDescriptions[index])}"
                addView(textView(listOf("诊", "问", "约", "档")[index], 20f, primaryDark, true).apply {
                    gravity = Gravity.CENTER
                    background = rounded(primarySoft, Color.TRANSPARENT, 24)
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                }, lp(dp(HarmonyUi.TOUCH_MIN), dp(HarmonyUi.TOUCH_MIN)))
                addView(textView(label, HarmonyUi.CAPTION, ink, true).apply { gravity = Gravity.CENTER; importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }, spaced(8))
                addView(textView(getString(quickDescriptions[index]), HarmonyUi.MICRO, secondary).apply { gravity = Gravity.CENTER; importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }, spaced(4))
            }
            actions.addView(action, LinearLayout.LayoutParams(0, -2, 1f))
            action.setOnClickListener { show(target) }
        }
        quick.addView(actions, lp(-1, -2))
        body.addView(quick, spaced(HarmonyUi.SECTION_GAP)); val appointments = vertical(); body.addView(appointments, spaced(HarmonyUi.SECTION_GAP))
        fun load() {
            retry.isEnabled = false; notice.text = getString(R.string.appointments_syncing)
            appointments.removeAllViews()
            runAsync({ repo.appointments(false) }, { items ->
                retry.isEnabled = true
                val next = HomeAppointmentSelector.select(items)
                notice.text = if (next == null) getString(R.string.appointments_pending_empty)
                    else getString(R.string.ui_next_visit_summary, next.visitDate, periodText(next.period), appointmentStatusText(next))
                next?.let { appointments.addView(appointmentCard(it, false)) }
            }, { error -> retry.isEnabled = true; notice.text = userMessage(error) })
        }
        val noticeHeader = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        noticeHeader.addView(sectionTitle(getString(R.string.align_notices_title)), LinearLayout.LayoutParams(0, -2, 1f))
        noticeHeader.addView(button(getString(R.string.align_notices_all), false).apply { setOnClickListener { show(Screen.NOTICES) } })
        body.addView(noticeHeader, spaced(HarmonyUi.SECTION_GAP))
        if (session.mockMode) body.addView(textView(getString(R.string.demo_notices_source), HarmonyUi.CAPTION, secondary))
        val notices = vertical(); body.addView(notices, spaced(HarmonyUi.GAP))
        val noticeMessage = textView("", HarmonyUi.CAPTION, secondary); body.addView(noticeMessage, spaced(6))
        val noticeRetry = networkButton(getString(R.string.align_notices_retry), false); body.addView(noticeRetry, spaced(6))
        fun loadNotices() {
            notices.removeAllViews(); noticeMessage.text = getString(R.string.align_notices_loading); noticeRetry.isEnabled = false
            runAsync({ repo.notices() }, { rows ->
                noticeRetry.isEnabled = true
                noticeMessage.text = if (rows.isEmpty()) getString(R.string.align_notices_empty) else ""
                rows.take(2).forEach { notices.addView(noticeCard(it), spaced(HarmonyUi.GAP)) }
            }, { error -> noticeRetry.isEnabled = true; noticeMessage.text = userMessage(error) })
        }
        noticeRetry.setOnClickListener { loadNotices() }; loadNotices()
        retry.setOnClickListener { load() }; load(); addBody(root, body, Screen.HOME); return root
    }
    private fun noticeCard(item: PatientNotice): View = cardColumn().apply {
        addView(textView("${item.category} · ${item.date}", HarmonyUi.CAPTION, secondary))
        addView(textView(item.title, HarmonyUi.HEADING, ink, true), spaced(HarmonyUi.GAP))
        addView(textView(item.body, HarmonyUi.BODY, secondary).apply { setTextIsSelectable(true) }, spaced(HarmonyUi.GAP))
    }

    private fun noticesView(): View {
        val root = vertical(); root.addView(header(getString(R.string.align_notices_title), getString(R.string.align_notices_subtitle), true))
        val body = bodyColumn()
        if (session.mockMode) body.addView(banner(getString(R.string.demo_notices_source), infoSoft, info))
        val message = textView("", HarmonyUi.CAPTION, secondary); body.addView(message, spaced(6))
        val retry = networkButton(getString(R.string.align_notices_retry), false); body.addView(retry, spaced(HarmonyUi.GAP))
        val list = vertical(); body.addView(list, spaced(HarmonyUi.GAP))
        fun load() {
            list.removeAllViews(); message.text = getString(R.string.align_notices_loading); retry.isEnabled = false
            runAsync({ repo.notices() }, { rows ->
                retry.isEnabled = true; message.text = if (rows.isEmpty()) getString(R.string.align_notices_empty) else ""
                rows.forEach { list.addView(noticeCard(it), spaced(HarmonyUi.GAP)) }
            }, { error -> retry.isEnabled = true; message.text = userMessage(error) })
        }
        retry.setOnClickListener { load() }; load(); addBody(root, body); return root
    }

    private fun triageView(): View {
        val root = vertical(); root.addView(header(getString(R.string.triage_title), getString(R.string.align_triage_subtitle), true))
        val body = bodyColumn(); val form = cardColumn()
        form.addView(sectionTitle(getString(R.string.align_triage_question)))
        val input = edit(getString(R.string.align_triage_hint), triageDraft).apply { filters = arrayOf(android.text.InputFilter.LengthFilter(500)); setText(triageDraft); minLines = 3; gravity = Gravity.TOP }
        triageDraft = input.text.toString()
        val count = textView(getString(R.string.align_triage_count, triageDraft.length), 12f, secondary)
        remember(input) { triageDraft = it; count.text = getString(R.string.align_triage_count, it.length) }
        form.addView(fieldLabel(getString(R.string.ui_symptom_description), input, true), spaced(6))
        form.addView(input, lp(-1, dp(120))); form.addView(count, spaced(4))
        form.addView(textView(getString(R.string.align_triage_caption), HarmonyUi.CAPTION, secondary), spaced(6))
        val message = messageView("", dangerSoft, danger); form.addView(message, spaced(HarmonyUi.GAP))
        val submit = networkButton(if (triageResult == null) getString(R.string.triage_start) else getString(R.string.triage_restart), true); form.addView(submit, lp(-1, dp(HarmonyUi.CONTROL_HEIGHT)).also { it.topMargin = dp(HarmonyUi.GAP) })
        body.addView(form, lp(-1, -2))
        val resultBox = vertical(); body.addView(resultBox, spaced(HarmonyUi.SECTION_GAP))
        fun renderResult(result: TriageResult) {
            resultBox.removeAllViews()
            if(result.requestId.isNotBlank()) resultBox.addView(textView("请求编号：${result.requestId}",12f,secondary))
            if (result.truncated) resultBox.addView(banner(getString(R.string.triage_truncated), warningSoft, warning), spaced(8))
            if (result.redFlag) {
                resultBox.addView(banner(result.patientNote.ifBlank { getString(R.string.triage_emergency_note) }, dangerSoft, danger), spaced(8))
                val dial = button(getString(R.string.emergency_dial), true)
                dial.setOnClickListener { runCatching { startActivity(Intent(Intent.ACTION_DIAL, Uri.parse("tel:120"))) }.onFailure { toast(getString(R.string.emergency_dial_fallback)) } }
                resultBox.addView(dial, spaced(10)); return
            }
            resultBox.addView(banner(result.patientNote.ifBlank { getString(R.string.triage_matched) }, infoSoft, info))
            if (result.aiNote.isNotBlank()) resultBox.addView(textView(result.aiNote, 13f, secondary), spaced(8))
            // ai_reason can contain upstream diagnostics and must not be exposed to patients.
            if (result.options.isEmpty()) {
                val reason = when (result.reasonCode) {
                    "NEED_CLARIFY", "NO_COMPLAINT" -> getString(R.string.triage_clarify)
                    "RED_FLAG" -> getString(R.string.triage_emergency)
                    else -> getString(R.string.triage_slots_empty)
                }
                resultBox.addView(textView(reason, 14f, secondary), spaced(12))
            }
            result.options.forEach { option ->
                val card = cardColumn()
                card.addView(textView(getString(R.string.provider_label, option.departmentName.ifBlank { getString(R.string.department_fallback, option.departmentId) }, option.doctorName.ifBlank { getString(R.string.doctor_fallback, option.doctorId) }), 16f, ink, true))
                card.addView(textView(getString(R.string.triage_slot_summary, option.workDate, periodText(option.period), option.remainNum), 13f, secondary), spaced(6))
                val choose = button(getString(R.string.triage_choose), false).apply { isEnabled = option.remainNum > 0 }
                card.addView(choose, lp(-1, dp(HarmonyUi.CONTROL_HEIGHT)).also { it.topMargin = dp(10) })
                choose.setOnClickListener {
                    selectedSchedule = Schedule(option.scheduleId, option.doctorId, option.departmentId, option.workDate, option.period, option.remainNum, option.remainNum, true, option.departmentName, option.doctorName, option.doctorTitle)
                    bookingDate = option.workDate; bookingDepartment = option.departmentId.toString(); bookingDoctor = option.doctorId.toString(); bookingPeriod = option.period; show(Screen.BOOKING)
                }
                resultBox.addView(card, spaced(10))
            }
        }
        triageResult?.let { renderResult(it) }
        submit.setOnClickListener {
            val value = input.text.toString().trim()
            if (value.isBlank()) { message.text = getString(R.string.triage_required); return@setOnClickListener }
            submit.isEnabled = false; submit.text = getString(R.string.triage_pending); message.text = ""
            runAsync({ repo.triage(value) }, { result ->
                triageResult = result; renderResult(result); submit.isEnabled = true; submit.text = getString(R.string.triage_restart)
            }, { error -> message.text = userMessage(error); submit.isEnabled = true; submit.text = getString(R.string.triage_restart) })
        }
        addBody(root, body, Screen.TRIAGE); return root
    }

    private fun bookingView(): View {
        val root = vertical(); root.addView(header(getString(R.string.booking_title), getString(R.string.align_booking_subtitle), true)); val body = bodyColumn()
        val filters = cardColumn(); filters.addView(sectionTitle(getString(R.string.align_booking_filters)))
        val attach=CheckBox(this).apply { text="读取可提交的预问诊单…";isEnabled=false;isChecked=attachPrevisit;setTextColor(ink);textSize=HarmonyUi.CAPTION;minHeight=dp(HarmonyUi.TOUCH_MIN);buttonTintList=android.content.res.ColorStateList.valueOf(primaryDark) }
        filters.addView(attach)
        runAsync({repo.preparePrevisit()}, {state ->
            previsit=state
            attach.isEnabled=state.complete && state.appointmentId==0L
            if(!attach.isEnabled) {attachPrevisit=false;attach.isChecked=false}
            attach.text=when {state.appointmentId>0 -> "该预问诊单已交给预约 #${state.appointmentId}";state.complete -> "将这份预问诊交给本次预约\n"+state.form.entries.joinToString(" · ") {it.value};else -> "没有已完成且待提交的预问诊单"}
        }, {attach.text="预问诊单暂未读取，可返回预问诊页核对";attachPrevisit=false;attach.isChecked=false})
        attach.setOnCheckedChangeListener {_,checked->attachPrevisit=checked}
        val department = edit(getString(R.string.align_department_hint), bookingDepartment).apply { isSingleLine = true; inputType = InputType.TYPE_CLASS_NUMBER }
        val doctor = edit(getString(R.string.align_doctor_hint), bookingDoctor).apply { isSingleLine = true; inputType = InputType.TYPE_CLASS_NUMBER }
        val date = edit(getString(R.string.booking_date_hint), bookingDate.ifBlank { selectedSchedule?.workDate.orEmpty() }).apply { isSingleLine = true }
        filters.addView(fieldLabel(getString(R.string.align_department_label), department), spaced(HarmonyUi.GAP)); filters.addView(department, lp(-1, dp(HarmonyUi.CONTROL_HEIGHT)))
        filters.addView(fieldLabel(getString(R.string.align_doctor_label), doctor), spaced(HarmonyUi.GAP)); filters.addView(doctor, lp(-1, dp(HarmonyUi.CONTROL_HEIGHT)))
        filters.addView(fieldLabel(getString(R.string.ui_visit_date), date), spaced(HarmonyUi.GAP)); filters.addView(date, lp(-1, dp(HarmonyUi.CONTROL_HEIGHT)))
        filters.addView(textView(getString(R.string.align_period_label), HarmonyUi.CAPTION, secondary), spaced(HarmonyUi.GAP))
        val periods = RadioGroup(this).apply { orientation = RadioGroup.HORIZONTAL }
        val choices = listOf("" to R.string.align_period_all, "AM" to R.string.period_am, "PM" to R.string.period_pm)
        val periodIds = linkedMapOf<Int, String>()
        choices.forEach { (value, label) ->
            val option = RadioButton(this).apply {
                id = View.generateViewId(); text = getString(label); textSize = HarmonyUi.CAPTION; setTextColor(ink)
                buttonTintList = android.content.res.ColorStateList.valueOf(primaryDark); minHeight = dp(HarmonyUi.TOUCH_MIN)
            }
            periodIds[option.id] = value; periods.addView(option, RadioGroup.LayoutParams(0, -2, 1f))
            if (value == bookingPeriod) option.isChecked = true
        }
        if (periods.checkedRadioButtonId == -1) { bookingPeriod = ""; periods.check(periodIds.keys.first()) }
        filters.addView(periods, lp(-1, -2))
        val query = networkButton(getString(R.string.booking_query), true); filters.addView(query, lp(-1, dp(HarmonyUi.CONTROL_HEIGHT)).also { it.topMargin = dp(HarmonyUi.GAP) })
        val message = messageView("", dangerSoft, danger); filters.addView(message, spaced(HarmonyUi.GAP)); body.addView(filters, lp(-1, -2))
        val list = vertical(); body.addView(list, spaced(HarmonyUi.SECTION_GAP))
        var filterRevision = 0
        fun invalidateFilter() { filterRevision++; list.removeAllViews(); message.text = getString(R.string.align_filters_changed) }
        bookingDate = date.text.toString()
        remember(date) { bookingDate = it; invalidateFilter() }
        remember(department) { bookingDepartment = it; invalidateFilter() }
        remember(doctor) { bookingDoctor = it; invalidateFilter() }
        fun parseId(value: String, label: String): Long {
            if (value.isBlank()) return 0
            return value.trim().toLongOrNull()?.takeIf { it > 0 }
                ?: throw IllegalArgumentException(getString(R.string.align_invalid_filter_id, label))
        }
        fun load() {
            val requestedDate = date.text.toString().trim()
            val requestedDepartment = department.text.toString()
            val requestedDoctor = doctor.text.toString()
            val requestedPeriod = bookingPeriod
            val requestedRevision = filterRevision
            query.isEnabled = false; query.text = getString(R.string.booking_query_pending); message.text = ""; list.removeAllViews()
            runAsync({
                val depId = parseId(requestedDepartment, getString(R.string.align_department_label))
                val doctorId = parseId(requestedDoctor, getString(R.string.align_doctor_label))
                val target = if (requestedDate.isBlank()) repo.hospitalToday() else requestedDate
                val schedules = repo.schedules(target, depId, doctorId, requestedPeriod)
                val appointments = runCatching { repo.appointments(false) }
                val badgeError = appointments.exceptionOrNull() as? ApiException
                if (badgeError != null && (badgeError.status == 401 ||
                    badgeError.code == "FORBIDDEN_ROLE" || badgeError.code == "SESSION_CHANGED")) throw badgeError
                Triple(target, schedules, appointments)
            }, { (target, schedules, appointmentResult) ->
                query.isEnabled = true; query.text = getString(R.string.booking_query)
                if (filterRevision != requestedRevision) return@runAsync
                if (requestedDate.isBlank()) { date.setText(target); message.text = "" }
                val occupied = appointmentResult.getOrNull().orEmpty().filterNot { isTerminal(it.status) }.map { it.scheduleId }.toSet()
                if (appointmentResult.isFailure) message.text = getString(R.string.align_booking_badges_unconfirmed)
                if (schedules.isEmpty()) list.addView(banner(getString(R.string.booking_slots_empty), infoSoft, info))
                schedules.sortedByDescending { it.id == selectedSchedule?.id }.forEach { list.addView(scheduleCard(it, it.id in occupied) { load() }, spaced(10)) }
                if ((appointmentResult.exceptionOrNull() as? ApiException)?.status == 429) refreshCooldownControls()
            }, { error ->
                query.isEnabled = true; query.text = getString(R.string.booking_query_retry)
                if (filterRevision == requestedRevision) message.text = userMessage(error)
            })
        }
        periods.setOnCheckedChangeListener { _, checked ->
            bookingPeriod = periodIds[checked].orEmpty(); invalidateFilter()
            if (query.isEnabled) load()
        }
        query.setOnClickListener { load() }; load(); addBody(root, body, Screen.BOOKING); return root
    }

    private fun scheduleLabel(schedule: Schedule): String {
        val department = schedule.departmentName.ifBlank { selectedSchedule?.takeIf { it.departmentId == schedule.departmentId }?.departmentName.orEmpty().ifBlank { getString(R.string.department_fallback, schedule.departmentId) } }
        val doctor = schedule.doctorName.ifBlank { selectedSchedule?.takeIf { it.doctorId == schedule.doctorId }?.doctorName.orEmpty().ifBlank { getString(R.string.doctor_fallback, schedule.doctorId) } }
        return getString(R.string.provider_label, department, doctor)
    }

    private fun scheduleCard(schedule: Schedule, occupied: Boolean, refresh: () -> Unit): View {
        val card = cardColumn(); val selected = selectedSchedule?.id == schedule.id
        card.addView(textView((if (selected) getString(R.string.booking_selected_prefix) else "") + scheduleLabel(schedule), 16f, ink, true))
        if (schedule.doctorTitle.isNotBlank()) card.addView(textView(schedule.doctorTitle, 13f, secondary), spaced(4))
        card.addView(textView(getString(R.string.booking_slot_summary, schedule.workDate, periodText(schedule.period), schedule.totalNum, schedule.remainNum), 13f, secondary), spaced(6))
        val confirm = networkButton(if (occupied) getString(R.string.align_booking_already_booked) else if (schedule.remainNum > 0 && schedule.enabled) (if (selected) getString(R.string.booking_confirm_selected) else getString(R.string.booking_confirm)) else getString(R.string.booking_unavailable), false)
        confirm.isEnabled = !occupied && schedule.remainNum > 0 && schedule.enabled
        card.addView(confirm, lp(-1, dp(HarmonyUi.CONTROL_HEIGHT)).also { it.topMargin = dp(10) })
        confirm.setOnClickListener {
            if (occupied) return@setOnClickListener
            selectedSchedule = schedule
            val chosenIntake=previsit?.takeIf {attachPrevisit && it.complete && it.appointmentId==0L}?.sessionId.orEmpty()
            AlertDialog.Builder(ThemeController.dialogContext(this)).setTitle(if (session.mockMode) getString(R.string.booking_demo_confirm) else getString(R.string.booking_confirm))
                .setMessage(getString(R.string.booking_confirm_summary, schedule.workDate, periodText(schedule.period), scheduleLabel(schedule)) +
                    (if(chosenIntake.isNotBlank()) "\n提交已选择的预问诊摘要" else "\n本次未选择提交预问诊") +
                    (if (session.mockMode) getString(R.string.booking_demo_confirm_note) else ""))
                .setNegativeButton(getString(R.string.dialog_reconsider), null).setPositiveButton(getString(R.string.dialog_confirm)) { _, _ ->
                    confirm.isEnabled = false; confirm.text = getString(R.string.booking_pending)
                    runAsync({ repo.bookWithPrevisit(schedule.id,chosenIntake) }, { item ->
                        appointmentOutcome = when {
                            session.mockMode -> getString(R.string.demo_booking_success, item.seqNo)
                            item.replayed -> getString(R.string.booking_replayed, item.seqNo, appointmentStatusText(item))
                            item.status == "booked" -> getString(R.string.booking_success, item.seqNo)
                            else -> getString(R.string.booking_result_status, appointmentStatusText(item))
                        }
                        appointmentOutcomeWarning = item.status != "booked"
                        appointmentOutcome += if(item.previsitBound) "\n预问诊摘要已交给本次接诊医生" else "\n本次未提交预问诊"
                        show(Screen.APPOINTMENTS, true)
                    }, { error ->
                        toast(userMessage(error))
                        if ((error as? ApiException)?.status in listOf(404, 409)) refresh()
                        else {
                            appointmentOutcome="预约结果尚未确认，请继续确认同一预约。\n"+userMessage(error)
                            appointmentOutcomeWarning=true;show(Screen.APPOINTMENTS,true)
                        }
                    })
                }.show()
        }
        return card
    }
    private fun appointmentsView(): View {
        val root = vertical(); root.addView(header(getString(R.string.appointments_title), getString(R.string.appointments_subtitle), true)); val body = bodyColumn()
        addPendingBookings(body)
        body.addView(banner(appointmentOutcome, if (appointmentOutcomeWarning) warningSoft else successSoft, if (appointmentOutcomeWarning) warning else success).apply {
            id = R.id.appointment_outcome
            visibility = if (appointmentOutcome.isBlank()) View.GONE else View.VISIBLE
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }, spaced(8))
        val message = textView(getString(R.string.booking_orders_syncing), 13f, secondary); body.addView(message)
        val retry = networkButton(getString(R.string.appointments_refresh), false); body.addView(retry, spaced(8)); val list = vertical(); body.addView(list, spaced(12))
        fun load() {
            retry.isEnabled = false; list.removeAllViews(); message.text = getString(R.string.booking_orders_syncing)
            runAsync({ repo.appointments(true) }, { items ->
                retry.isEnabled = true; message.text = if (items.isEmpty()) getString(R.string.appointments_empty) else ""
                val active = items.filterNot { isTerminal(it.status) }
                val history = items.filter { isTerminal(it.status) }
                if (active.isNotEmpty()) {
                    list.addView(sectionTitle(getString(R.string.align_current_appointments)))
                    active.forEach { list.addView(appointmentCard(it, true), spaced(10)) }
                }
                if (history.isNotEmpty()) {
                    list.addView(sectionTitle(getString(R.string.align_history_appointments)), spaced(HarmonyUi.SECTION_GAP))
                    history.forEach { list.addView(appointmentCard(it, true), spaced(10)) }
                }
            }, { error -> retry.isEnabled = true; message.text = userMessage(error) })
        }
        retry.setOnClickListener { load() }; load(); addBody(root, body, Screen.APPOINTMENTS); return root
    }

    private fun addPendingBookings(body: LinearLayout) {
        session.pendingBookings().forEach { pending ->
            val card=cardColumn()
            card.addView(banner("有一次预约结果尚未确认 · 排班 #${pending.scheduleId}",warningSoft,warning))
            val notice=textView("继续确认会复用原请求编号，不另建一次预约意图。",13f,secondary);card.addView(notice)
            val lookup=networkButton("查询本次预约",false);card.addView(lookup,spaced(8))
            val retry=networkButton("继续确认同一预约",true);card.addView(retry,spaced(8))
            fun done(item:Appointment) {appointmentOutcome="预约已确认：${item.seqNo} 号 · ${appointmentStatusText(item)}";appointmentOutcomeWarning=false;show(Screen.APPOINTMENTS,true)}
            lookup.setOnClickListener {
                lookup.isEnabled=false;retry.isEnabled=false
                runAsync({repo.confirmBooking(pending)}, {item->
                    lookup.isEnabled=true;retry.isEnabled=true
                    if(item!=null) done(item) else notice.text="尚未查到可确认的预约。请继续确认，仍将复用原请求编号。"
                }, {error->lookup.isEnabled=true;retry.isEnabled=true;notice.text=userMessage(error)})
            }
            retry.setOnClickListener {
                retry.isEnabled=false;lookup.isEnabled=false
                runAsync({repo.bookWithPrevisit(pending.scheduleId,pending.previsitId)}, {done(it)}, {error->
                    retry.isEnabled=true;lookup.isEnabled=true;notice.text="预约结果仍未确认。\n"+userMessage(error)
                })
            }
            body.addView(card,spaced(10))
        }
    }

    private fun appointmentCard(item: Appointment, allowActions: Boolean): View {
        val card = cardColumn(); card.addView(textView(getString(R.string.appointment_date_summary, item.visitDate, periodText(item.period)), 16f, ink, true))
        card.addView(textView(getString(R.string.appointment_provider_summary, item.seqNo, item.departmentName.ifBlank { getString(R.string.department_fallback, item.departmentId) }, item.doctorName.ifBlank { getString(R.string.doctor_fallback, item.doctorId) }), 13f, secondary), spaced(6))
        card.addView(banner(appointmentStatusText(item), statusBackground(item.status), statusColor(item.status)), spaced(10))
        val stages=listOf("已预约" to item.createdAt,"已到院" to item.arrivedAt,"候诊中" to item.waitingAt,"接诊中" to item.startedAt,"已完成" to item.finishedAt)
        stages.filter {it.second>0}.forEach { (name,at) -> card.addView(textView("$name · "+SimpleDateFormat("MM-dd HH:mm",Locale.CHINA)
            .apply {timeZone=java.util.TimeZone.getTimeZone("Asia/Shanghai")}.format(Date(at*1000)),12f,secondary),spaced(4)) }
        if(item.status=="booked") card.addView(textView("请到${item.departmentName.ifBlank { "相应科室" }}分诊台报到，由医护确认到院",13f,secondary),spaced(6))
        if(item.previsitBound) card.addView(textView("本次已提交预问诊摘要",13f,primaryDark),spaced(4))
        if (allowActions && item.status == "booked") {
            val cancel = networkButton(getString(R.string.cancel_action), false); card.addView(cancel, lp(-1, dp(HarmonyUi.CONTROL_HEIGHT)).also { it.topMargin = dp(10) })
            cancel.setOnClickListener {
                AlertDialog.Builder(ThemeController.dialogContext(this)).setTitle(getString(R.string.cancel_title))
                    .setMessage(if (session.mockMode) getString(R.string.cancel_demo_note) else getString(R.string.cancel_note))
                    .setNegativeButton(getString(R.string.dialog_reconsider), null).setPositiveButton(getString(R.string.cancel_confirm)) { _, _ ->
                        cancel.isEnabled = false
                        runAsync({ repo.cancel(item.appointmentId) }, { result ->
                            appointmentOutcome = when {
                                result.status != "cancelled" -> getString(R.string.cancel_incomplete)
                                session.mockMode -> getString(R.string.cancel_demo_success)
                                result.slotRestored -> getString(R.string.cancel_success)
                                else -> result.warning.ifBlank { getString(R.string.cancel_restore_unconfirmed) }
                            }
                            appointmentOutcomeWarning = result.status != "cancelled" || (!session.mockMode && !result.slotRestored)
                            show(Screen.APPOINTMENTS, true)
                        }, { error ->
                            cancel.isEnabled = true
                            appointmentOutcome = userMessage(error); appointmentOutcomeWarning = true
                            show(Screen.APPOINTMENTS, true)
                        })
                    }.show()
            }
        } else if (allowActions && item.status == "done") {
            val records = button(getString(R.string.record_open), false); card.addView(records, lp(-1, dp(HarmonyUi.CONTROL_HEIGHT)).also { it.topMargin = dp(10) })
            records.setOnClickListener { recordAppointmentId = item.appointmentId; show(Screen.RECORD_DETAIL) }
        } else if (allowActions && !isTerminal(item.status)) {
            card.addView(textView(getString(R.string.align_cancel_blocked, appointmentStatusText(item)), HarmonyUi.CAPTION, secondary), spaced(HarmonyUi.GAP))
        }
        return card
    }

    private fun previsitView(): View {
        val root = vertical(); val pageHeader = header(getString(R.string.previsit_title), getString(R.string.align_previsit_initial), true)
        root.addView(pageHeader); val body = bodyColumn()
        val stage = textView(getString(R.string.align_previsit_initial), HarmonyUi.CAPTION, secondary); body.addView(stage, spaced(6))
        val conversation = cardColumn()
        val question = textView(getString(R.string.previsit_initial_question), HarmonyUi.HEADING, ink, true); conversation.addView(question)
        conversation.addView(textView(getString(R.string.previsit_answer_note), HarmonyUi.CAPTION, secondary), spaced(6))
        val assistant = textView("", HarmonyUi.CAPTION, secondary); conversation.addView(assistant, spaced(6))
        body.addView(conversation, lp(-1, -2))
        val form = cardColumn(); body.addView(form, spaced(HarmonyUi.SECTION_GAP))
        val answer = edit(getString(R.string.previsit_answer_hint), previsitDraft).apply { minLines = 4; gravity = Gravity.TOP }
        form.addView(fieldLabel(getString(R.string.ui_current_answer), answer, true))
        previsitValue = answer; remember(answer) { previsitDraft = it }; form.addView(answer, lp(-1, dp(120)).also { it.topMargin = dp(6) })
        val message = messageView("", dangerSoft, danger); form.addView(message, spaced(HarmonyUi.GAP))
        val send = networkButton(getString(R.string.previsit_submit), true); form.addView(send, lp(-1, dp(HarmonyUi.CONTROL_HEIGHT)).also { it.topMargin = dp(HarmonyUi.GAP) })
        val progress = textView("", HarmonyUi.CAPTION, secondary); form.addView(progress, spaced(HarmonyUi.GAP))
        val retry = networkButton(getString(R.string.previsit_load_retry), false).apply { visibility = View.GONE }; form.addView(retry, spaced(HarmonyUi.GAP))
        val restart = button(getString(R.string.previsit_restart), false).apply { visibility = View.GONE }; form.addView(restart, spaced(HarmonyUi.GAP))
        var loaded = false
        fun display(result: PrevisitSession) {
            val previous = previsit
            if ((previous != null && (previous.sessionId != result.sessionId || previous.nextSlot != result.nextSlot)) ||
                (previous == null && result.sessionId.isNotBlank() && result.nextSlot != "chief")) answer.text?.clear()
            previsit = result; loaded = true
            question.text = when { result.complete -> getString(R.string.previsit_complete); result.sessionId.isBlank() -> getString(R.string.previsit_initial_question); else -> result.nextQuestion.ifBlank { getString(R.string.previsit_question_fallback) } }
            val slotNames=mapOf("chief" to "主诉","duration" to "持续时间","severity" to "影响程度","associated" to "伴随症状","history" to "既往史","allergy" to "过敏史")
            assistant.text = (if (result.assistantText.isBlank()) "" else getString(R.string.previsit_assistant_note, result.assistantText)) +
                if(result.complete) "\n"+result.form.entries.joinToString("\n") {"${slotNames[it.key] ?: it.key}：${it.value}"} else ""
            progress.text = if (result.sessionId.isBlank()) getString(R.string.previsit_not_started) else getString(R.string.previsit_progress, result.filled, result.totalSlots)
            stage.text = if (result.complete) getString(R.string.align_previsit_complete) else if (result.sessionId.isBlank()) getString(R.string.align_previsit_initial) else progress.text
            pageHeader.findViewWithTag<TextView>("page_subtitle")?.text = stage.text
            send.isEnabled = !result.complete; answer.isEnabled = !result.complete; send.text = if (result.complete) getString(R.string.status_done) else getString(R.string.previsit_submit)
            restart.visibility = if (result.complete) View.VISIBLE else View.GONE; retry.visibility = View.GONE
            if (result.expired) { answer.text?.clear(); message.text = getString(R.string.previsit_expired) }
        }
        fun load() {
            send.isEnabled = false; retry.isEnabled = false; message.text = getString(R.string.previsit_recovering)
            runAsync({ repo.preparePrevisit() }, { result -> message.text = ""; retry.isEnabled = true; display(result) }, { error ->
                loaded = false; send.isEnabled = false; retry.isEnabled = true; retry.visibility = View.VISIBLE; message.text = userMessage(error)
            })
        }
        retry.setOnClickListener { load() }
        restart.setOnClickListener { repo.resetPrevisit(); previsit = null; previsitDraft = ""; show(Screen.PREVISIT, true) }
        if (session.previsitSessionId.isNotBlank()) load() else { loaded = true; previsit = null; progress.text = getString(R.string.previsit_not_started) }
        send.setOnClickListener {
            if (!loaded) return@setOnClickListener
            val value = answer.text.toString().trim()
            if (value.isBlank()) { message.text = getString(R.string.previsit_answer_required); return@setOnClickListener }
            send.isEnabled = false; send.text = getString(R.string.previsit_saving); message.text = ""; val state = previsit
            runAsync({ if (state == null || state.sessionId.isBlank()) repo.startPrevisit(value) else repo.answerPrevisit(state.sessionId, state.nextSlot, value) }, { result ->
                answer.text?.clear(); display(result)
            }, { error ->
                message.text = userMessage(error); send.text = getString(R.string.previsit_submit_retry)
                if ((error as? ApiException)?.status == 404) {
                    repo.resetPrevisit(); answer.text?.clear()
                    display(PrevisitSession("", 0, 0, 0, false, "chief", getString(R.string.previsit_chief_required), expired = true))
                } else if ((state == null || state.sessionId.isBlank()) && session.previsitSessionId.isNotBlank()) {
                    loaded = false; send.isEnabled = false; retry.visibility = View.VISIBLE; retry.isEnabled = true
                } else send.isEnabled = true
            })
        }
        addBody(root, body); return root
    }

    private fun recordsView(): View {
        val root = vertical(); root.addView(header(getString(R.string.records_title), getString(R.string.records_subtitle), true)); val body = bodyColumn()
        val message = textView(getString(R.string.records_loading), 13f, secondary); body.addView(message)
        val retry = networkButton(getString(R.string.records_refresh), false); body.addView(retry, spaced(8)); val list = vertical(); body.addView(list, spaced(12))
        fun load() {
            retry.isEnabled = false
            runAsync({ repo.medicalRecords() }, { records ->
                retry.isEnabled = true; message.text = if (records.isEmpty()) getString(R.string.records_empty) else ""; list.removeAllViews()
                records.forEach { record ->
                    val card = cardColumn(); card.addView(textView(record.visitDate.ifBlank { getString(R.string.record_visit_fallback, record.appointmentId) }, 16f, ink, true))
                    card.addView(textView(getString(R.string.provider_label, record.departmentName.ifBlank { getString(R.string.department_fallback, record.departmentId) }, record.doctorName.ifBlank { getString(R.string.doctor_fallback, record.doctorId) }), 13f, secondary), spaced(6))
                    card.addView(banner(if (record.locked) getString(R.string.record_locked) else getString(R.string.record_draft), if (record.locked) successSoft else warningSoft, if (record.locked) success else warning), spaced(8))
                    val open = button(getString(R.string.record_open), false).apply { isEnabled = record.locked }
                    open.setOnClickListener { recordAppointmentId = record.appointmentId; show(Screen.RECORD_DETAIL) }; card.addView(open, spaced(10)); list.addView(card, spaced(10))
                }
            }, { error -> retry.isEnabled = true; message.text = userMessage(error) })
        }
        retry.setOnClickListener { load() }; load(); addBody(root, body); return root
    }

    private fun recordDetailView(): View {
        val root = vertical(); root.addView(header(getString(R.string.record_detail_title), getString(R.string.record_detail_subtitle, recordAppointmentId), true)); val body = bodyColumn()
        val message = textView(getString(R.string.record_detail_loading), 13f, secondary); body.addView(message)
        val retry = networkButton(getString(R.string.record_reload), false); body.addView(retry, spaced(8)); val details = vertical(); body.addView(details, spaced(12))
        fun load() {
            retry.isEnabled = false
            runAsync({ repo.medicalRecord(recordAppointmentId) }, { record ->
                retry.isEnabled = true; message.text = ""; details.removeAllViews(); details.addView(banner(getString(R.string.record_locked_notice), successSoft, success))
                record.sections.forEach { section ->
                    val card = cardColumn(); card.addView(textView(section.label, 16f, ink, true))
                    card.addView(textView(section.value.ifBlank { getString(R.string.record_value_empty) }, 14f, secondary).apply { setTextIsSelectable(true) }, spaced(8)); details.addView(card, spaced(10))
                }
            }, { error -> retry.isEnabled = true; message.text = if ((error as? ApiException)?.status == 404) getString(R.string.record_unavailable) else userMessage(error) })
        }
        retry.setOnClickListener { load() }; load(); addBody(root, body); return root
    }
    private fun profileView(): View {
        val root = vertical(); root.addView(header(getString(R.string.profile_title), getString(R.string.profile_subtitle), true)); val body = bodyColumn()
        val identity = cardColumn(); identity.addView(textView(session.displayName.ifBlank { getString(R.string.patient_fallback) }, 24f, ink, true))
        identity.addView(textView(getString(R.string.profile_identity, session.patientId, formatEpoch(session.expiresAt)), 13f, secondary), spaced(6))
        val sync = networkButton(getString(R.string.identity_sync), false); identity.addView(sync, spaced(12))
        sync.setOnClickListener {
            if (logoutBusy) return@setOnClickListener
            sync.isEnabled = false
            val expectedToken = session.token; val expectedAddress = session.baseUrl
            val expectedUserId = session.userId; val expectedPatientId = session.patientId
            runAsync({
                val identity = repo.me()
                if (identity.role != "patient" || identity.userId != expectedUserId || identity.patientId != expectedPatientId) {
                    session.clearLoginIfCurrent(expectedToken, expectedAddress)
                    throw ApiException(403, "FORBIDDEN_ROLE", getString(R.string.identity_changed))
                }
                identity
            }, {
                // Keep the logout callback's render version alive until it completes.
                if (!logoutBusy) { render(); toast(getString(R.string.identity_synced)) }
            }, { error ->
                if (!logoutBusy) { sync.isEnabled = true; toast(userMessage(error)) }
            })
        }
        body.addView(identity)
        val appearance = cardColumn(); appearance.addView(sectionTitle(getString(R.string.theme_appearance)))
        val themeRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        val themeButtons = mutableListOf<Pair<ThemeController.Mode, Button>>()
        fun showThemeSelection() {
            themeButtons.forEach { (mode, button) ->
                val selected = ThemeController.currentMode(this) == mode
                button.setTextColor(if (selected) primaryDark else secondary)
                button.background = rounded(if (selected) primarySoft else palette.surfaceAlt, Color.TRANSPARENT, HarmonyUi.CONTROL_RADIUS)
            }
        }
        listOf(ThemeController.Mode.AUTO to R.string.theme_auto, ThemeController.Mode.LIGHT to R.string.theme_light, ThemeController.Mode.DARK to R.string.theme_dark).forEach { (mode, label) ->
            val action = button(getString(label), false)
            themeButtons += mode to action; themeRow.addView(action, LinearLayout.LayoutParams(0, -2, 1f))
            action.setOnClickListener {
                if (!logoutBusy) {
                    ThemeController.setMode(this, mode); refreshTheme(); showThemeSelection()
                }
            }
        }
        showThemeSelection(); appearance.addView(themeRow)
        appearance.addView(textView(getString(R.string.align_theme_note), HarmonyUi.CAPTION, secondary), spaced(HarmonyUi.GAP))
        body.addView(appearance, spaced(HarmonyUi.SECTION_GAP))
        val settings = cardColumn(); settings.addView(sectionTitle(getString(R.string.ui_data_source)))
        settings.addView(banner(if (session.mockMode) getString(R.string.demo_mode_label) else getString(R.string.online_mode_label), primarySoft, primaryDark), spaced(6))
        if (BuildConfig.DEBUG) {
            val mode = button(if (session.mockMode) getString(R.string.demo_exit) else getString(R.string.demo_switch_enter), false); settings.addView(mode, spaced(10))
            mode.setOnClickListener {
                if (logoutBusy) return@setOnClickListener
                val targetDemo = !session.mockMode
                AlertDialog.Builder(ThemeController.dialogContext(this)).setTitle(getString(R.string.mode_switch_title)).setMessage(getString(R.string.mode_switch_note))
                    .setNegativeButton(getString(R.string.dialog_cancel), null).setPositiveButton(getString(R.string.mode_switch_action)) { _, _ ->
                        clearPatientState(); session.switchMode(targetDemo)
                        if (targetDemo) { session.saveLogin(repo.enterDemo()); show(Screen.HOME, true) }
                        else { loginNotice = getString(R.string.demo_exited); show(Screen.LOGIN, true) }
                    }.show()
            }
        }
        val addressValue = edit(getString(R.string.service_address_title), profileAddressDraft ?: session.baseUrl).apply { isSingleLine = true }
        remember(addressValue) { profileAddressDraft = it }
        settings.addView(fieldLabel(getString(R.string.ui_service_address), addressValue), spaced(HarmonyUi.GAP)); settings.addView(addressValue, lp(-1, -2))
        val addressMessage = messageView("", dangerSoft, danger); settings.addView(addressMessage, spaced(HarmonyUi.GAP))
        val address = button(getString(R.string.align_address_save), false); settings.addView(address, spaced(HarmonyUi.GAP))
        address.setOnClickListener {
            if (logoutBusy) return@setOnClickListener
            val before = session.baseUrl
            runCatching { session.baseUrl = addressValue.text.toString() }.onFailure {
                addressMessage.text = it.message ?: getString(R.string.service_address_invalid)
            }.onSuccess {
                profileAddressDraft = session.baseUrl
                if (before != session.baseUrl) { clearPatientState(); loginNotice = getString(R.string.service_address_changed); show(Screen.LOGIN, true) }
                else { addressMessage.text = ""; toast(getString(R.string.service_address_saved)) }
            }
        }
        settings.addView(textView(getString(R.string.service_address_note), HarmonyUi.CAPTION, warning), spaced(HarmonyUi.GAP)); body.addView(settings, spaced(18))
        val records = button(getString(R.string.records_title), false); records.setOnClickListener { show(Screen.RECORDS) }; body.addView(records, spaced(12))
        val logout = button(getString(R.string.logout_action), true); body.addView(logout, lp(-1, dp(HarmonyUi.CONTROL_HEIGHT)).also { it.topMargin = dp(20) })
        logout.setOnClickListener {
            logout.isEnabled = false; logoutBusy = true
            runAsync({ repo.logout() }, { clearPatientState(); loginNotice = getString(R.string.logout_success); show(Screen.LOGIN, true) }, {
                clearPatientState(); loginNotice = getString(R.string.logout_local_success); show(Screen.LOGIN, true)
            })
        }
        addBody(root, body, Screen.PROFILE); return root
    }

    private fun editServiceAddress() {
        val value = edit(getString(R.string.service_address_title), session.baseUrl).apply { isSingleLine = true }
        val dialog = AlertDialog.Builder(ThemeController.dialogContext(this)).setTitle(getString(R.string.service_address_title)).setView(value)
            .setMessage(getString(R.string.service_address_note))
            .setNegativeButton(getString(R.string.dialog_cancel), null).setPositiveButton(getString(R.string.dialog_save), null).create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val before = session.baseUrl
                runCatching { session.baseUrl = value.text.toString() }.onFailure { value.error = it.message ?: getString(R.string.service_address_invalid) }.onSuccess {
                    dialog.dismiss()
                    if (before != session.baseUrl) { clearPatientState(); loginNotice = getString(R.string.service_address_changed); show(Screen.LOGIN, true) }
                    else toast(getString(R.string.service_address_saved))
                }
            }
        }
        dialog.show()
    }

    private fun clearPatientState() {
        attachPrevisit=false
        triageDraft = ""; triageResult = null; selectedSchedule = null; bookingDate = ""
        bookingDepartment = ""; bookingDoctor = ""; bookingPeriod = ""; profileAddressDraft = null
        previsitDraft = ""; previsit = null; previsitValue = null; recordAppointmentId = 0; loginBusy = false; logoutBusy = false
        appointmentOutcome = ""; appointmentOutcomeWarning = false
        repo.resetTransientState()
    }

    private fun updateLoginCooldown() {
        if (current != Screen.LOGIN) return
        val remaining = api.remainingCooldownSeconds()
        loginButton?.isEnabled = !loginBusy && remaining == 0
        loginButton?.text = when { loginBusy -> getString(R.string.login_pending); remaining > 0 -> getString(R.string.login_cooldown_action, remaining); else -> getString(R.string.login_action) }
        if (remaining > 0) {
            loginMessage?.text = getString(R.string.cooldown_error, remaining)
            val version = renderVersion
            ui.postDelayed({ if (version == renderVersion && !isDestroyed) updateLoginCooldown() }, 1000)
        } else if (!loginBusy) {
            if (loginNotice.startsWith(getString(R.string.cooldown_error_prefix))) loginNotice = getString(R.string.login_cooldown_finished)
            loginMessage?.text = loginNotice
        }
    }

    private fun updateCooldownBanner(version: Int) {
        if (isDestroyed || version != renderVersion) return
        refreshCooldownControls()
        ui.postDelayed({ updateCooldownBanner(version) }, 1000)
    }

    private fun refreshCooldownControls() {
        val remaining = api.remainingCooldownSeconds()
        // onCreate can render before window attachment; retain views in the current content tree.
        networkButtons.removeAll { button ->
            var ancestor: View? = button
            while (ancestor != null && ancestor !== content) ancestor = ancestor.parent as? View
            ancestor !== content
        }
        networkButtons.forEach { it.setCoolingDown(remaining > 0 && !session.mockMode) }
        cooldownBanner?.visibility = if (remaining > 0 && !session.mockMode) View.VISIBLE else View.GONE
        cooldownBanner?.text = getString(R.string.cooldown_notice, remaining)
        cooldownBanner?.contentDescription = cooldownBanner?.text
    }

    private fun remember(edit: EditText, change: (String) -> Unit) {
        edit.setSaveEnabled(false)
        edit.addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { change(s?.toString().orEmpty()) }
            override fun afterTextChanged(s: Editable?) = Unit
        })
    }
    private fun edit(hintText: String, value: String = "") = EditText(this).apply {
        hint = hintText; setText(value); setTextColor(ink); setHintTextColor(secondary)
        textSize = HarmonyUi.BODY
        minHeight = dp(HarmonyUi.CONTROL_HEIGHT)
        setPadding(dp(HarmonyUi.GAP), dp(10), dp(HarmonyUi.GAP), dp(10))
        background = rounded(palette.surfaceAlt, Color.TRANSPARENT, HarmonyUi.CONTROL_RADIUS)
        backgroundTintList = null
    }
    private fun addBody(root: LinearLayout, body: View, nav: Screen? = null) {
        root.addView(ScrollView(this).apply { isFillViewport = true; addView(body) }, lp(-1, 0).also { it.weight = 1f })
        if (nav != null) root.addView(bottomNav(nav))
    }
    private fun bodyColumn() = vertical().apply { setPadding(dp(HarmonyUi.PAGE_PADDING), dp(HarmonyUi.GAP), dp(HarmonyUi.PAGE_PADDING), dp(24)) }
    private fun spaced(top: Int) = lp(-1, -2).also { it.topMargin = dp(top) }
    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    private fun bottomNav(selected: Screen): View {
        val nav = vertical()
        nav.addView(View(this).apply { setBackgroundColor(border) }, lp(-1, dp(1)))
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; setBackgroundColor(surface)
            setPadding(dp(4), 0, dp(4), dp(4))
        }
        val tabs = listOf(
            Triple(R.string.nav_home, "⌂", Screen.HOME),
            Triple(R.string.nav_triage, "◎", Screen.TRIAGE),
            Triple(R.string.nav_booking, "＋", Screen.BOOKING),
            Triple(R.string.nav_appointments, "□", Screen.APPOINTMENTS),
            Triple(R.string.ui_nav_profile, "人", Screen.PROFILE)
        )
        tabs.forEach { (labelRes, glyph, target) ->
            val label = getString(labelRes)
            val color = if (selected == target) primaryDark else secondary
            val item = vertical().apply {
                gravity = Gravity.CENTER; isFocusable = true; isClickable = true
                isSelected = selected == target; contentDescription = label
                addView(textView(glyph, 22f, color).apply {
                    gravity = Gravity.CENTER; includeFontPadding = false
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                }, lp(-1, dp(26)))
                addView(textView(label, HarmonyUi.MICRO, color).apply {
                    gravity = Gravity.CENTER; includeFontPadding = false
                    importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
                }, spaced(2))
                setOnClickListener { if (target != selected) show(target, true) }
            }
            row.addView(item, LinearLayout.LayoutParams(0, -1, 1f))
        }
        nav.addView(row, lp(-1, dp(HarmonyUi.NAV_HEIGHT) - dp(1)))
        return nav
    }
    private fun header(title: String, subtitle: String, back: Boolean = false): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(HarmonyUi.HEADER_HEIGHT)
            setPadding(dp(if (back) 4 else HarmonyUi.PAGE_PADDING), dp(4), dp(HarmonyUi.PAGE_PADDING), dp(4))
            setBackgroundColor(bg)
        }
        if (back) {
            val action = textView("‹", 32f, ink).apply {
                gravity = Gravity.CENTER; contentDescription = getString(R.string.nav_back)
                isFocusable = true; setOnClickListener { handleBack() }
            }
            row.addView(action, lp(dp(HarmonyUi.TOUCH_MIN), dp(HarmonyUi.TOUCH_MIN)))
        }
        val box = vertical()
        box.addView(textView(title, HarmonyUi.TITLE, ink, true))
        if (subtitle.isNotBlank()) box.addView(textView(subtitle, HarmonyUi.CAPTION, secondary).apply { tag = "page_subtitle" }, spaced(4))
        row.addView(box, LinearLayout.LayoutParams(0, -2, 1f))
        return row
    }
    private fun <T> runAsync(work: () -> T, success: (T) -> Unit, failure: (Throwable) -> Unit) {
        val version = renderVersion
        val requestedBaseUrl = session.baseUrl
        val requestedToken = session.token
        executor.execute {
            val result = runCatching { work() }
            ui.post {
                if (isFinishing || isDestroyed) return@post
                val error = result.exceptionOrNull() as? ApiException
                // A request from a previous page can still start a cooldown for the current page.
                if (error?.status == 429) { refreshCooldownControls(); updateLoginCooldown() }
                if (version != renderVersion) {
                    // Auth invalidation belongs to the account, not the view that started the request.
                    if (requestedToken.isNotBlank() && session.token.isBlank() && !session.mockMode &&
                        session.baseUrl == requestedBaseUrl && current != Screen.LOGIN &&
                        (error?.status == 401 || (error?.status == 403 && error.code == "FORBIDDEN_ROLE"))) {
                        error?.let { dispatchFailure(it, failure) }
                    }
                    return@post
                }
                result.fold({ value -> runCatching { success(value) }.onFailure { dispatchFailure(it, failure) } }, { dispatchFailure(it, failure) })
            }
        }
    }
    private fun dispatchFailure(error: Throwable, failure: (Throwable) -> Unit) {
        val e = error as? ApiException
        if (e?.status == 429) { refreshCooldownControls(); updateLoginCooldown() }
        if (current != Screen.LOGIN && (e?.status == 401 || (e?.status == 403 && e.code == "FORBIDDEN_ROLE" && !session.isLoggedIn()))) {
            session.clearLogin(); clearPatientState()
            loginNotice = if (e?.status == 401) getString(R.string.login_expired) else getString(R.string.patient_role_required)
            show(Screen.LOGIN, true); toast(loginNotice); return
        }
        failure(error)
    }
    // This function only formats a message; navigation is owned by dispatchFailure.
    private fun userMessage(error: Throwable): String {
        val e = error as? ApiException ?: return if (error is IllegalArgumentException) error.message ?: getString(R.string.input_invalid) else getString(R.string.request_failed)
        val message = when {
            e.status == 401 && current == Screen.LOGIN && e.code == "AUTH_BAD_CREDENTIALS" -> getString(R.string.login_bad_credentials)
            e.status == 401 -> getString(R.string.login_expired)
            e.status == 403 && e.code == "FORBIDDEN_ROLE" && !session.isLoggedIn() -> getString(R.string.patient_role_required)
            e.status == 429 -> getString(R.string.cooldown_error, api.remainingCooldownSeconds().coerceAtLeast(1))
            e.status >= 500 -> getString(R.string.service_unavailable)
            else -> e.message
        }
        return message+if(e.requestId.isNotBlank()) "\n请求编号：${e.requestId}" else ""
    }
    private fun periodText(p: String) = when (p.trim().uppercase(Locale.ROOT)) {
        "AM" -> getString(R.string.period_am); "PM" -> getString(R.string.period_pm); "NIGHT" -> getString(R.string.period_night); "" -> getString(R.string.period_unknown); else -> getString(R.string.period_other, p.trim())
    }
    private fun appointmentStatusText(item: Appointment) = item.statusLabel.ifBlank { statusText(item.status) }
    private fun isTerminal(status: String) = status in setOf("done", "cancelled", "no_show")
    private fun statusText(s: String) = mapOf("booked" to getString(R.string.ui_status_booked), "arrived" to getString(R.string.ui_status_arrived), "waiting" to getString(R.string.ui_status_waiting), "visiting" to getString(R.string.ui_status_visiting), "done" to getString(R.string.status_done), "cancelled" to getString(R.string.ui_status_cancelled), "no_show" to getString(R.string.ui_status_no_show))[s] ?: s.ifBlank { getString(R.string.status_unknown) }
    private fun statusColor(s: String) = when (s) { "booked" -> info; "visiting" -> primaryDark; "done" -> success; "cancelled", "no_show" -> danger; else -> secondary }
    private fun statusBackground(s: String) = when (s) { "cancelled", "no_show" -> dangerSoft; "done" -> successSoft; else -> primarySoft }
    private fun formatEpoch(value: Long) = if (value <= 0) getString(R.string.time_unknown) else SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()).format(Date(value * 1000))
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun lp(w: Int, h: Int) = LinearLayout.LayoutParams(w, h)
    private fun vertical(gap: Int = 0) = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; if (gap > 0) setPadding(dp(gap), dp(gap), dp(gap), dp(gap)) }
    private fun column(gap: Int) = vertical(gap)
    private fun cardColumn() = vertical(HarmonyUi.CARD_PADDING).apply { background = rounded(surface, Color.TRANSPARENT, HarmonyUi.CARD_RADIUS) }
    private fun sectionTitle(value: String) = textView(value, HarmonyUi.HEADING, ink, true).apply {
        setPadding(0, dp(4), 0, dp(HarmonyUi.GAP))
    }
    private fun fieldLabel(value: String, field: View, required: Boolean = false): TextView {
        if (field.id == View.NO_ID) field.id = View.generateViewId()
        return textView(if (required) "$value *" else value, HarmonyUi.CAPTION, secondary).apply {
            labelFor = field.id; setPadding(0, 0, 0, dp(6))
        }
    }
    private fun messageView(value: String, background: Int, foreground: Int) = banner(value, background, foreground).apply {
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        visibility = if (value.isBlank()) View.GONE else View.VISIBLE
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) = Unit
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                visibility = if (s.isNullOrBlank()) View.GONE else View.VISIBLE
                contentDescription = s
            }
            override fun afterTextChanged(s: Editable?) = Unit
        })
    }
    private fun textView(value: String, size: Float, color: Int, bold: Boolean = false) = TextView(this).apply { text = value; textSize = size; setTextColor(color); if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD) }
    private fun button(label: String, filled: Boolean) = Button(this).apply { styleButton(label, filled) }
    private fun Button.styleButton(label: String, filled: Boolean) {
        text = label; contentDescription = label; textSize = HarmonyUi.BODY; isAllCaps = false
        setTextColor(if (filled) palette.onPrimary else primaryDark)
        background = rounded(if (filled) primary else primarySoft, if (filled) Color.TRANSPARENT else primary, HarmonyUi.CONTROL_RADIUS)
        backgroundTintList = null
        minHeight = dp(HarmonyUi.CONTROL_HEIGHT); minimumHeight = dp(HarmonyUi.CONTROL_HEIGHT)
        setPadding(dp(HarmonyUi.GAP), dp(6), dp(HarmonyUi.GAP), dp(6))
    }
    // Business state and server cooldown are independent: expiration must never revive a busy or completed action.
    private inner class NetworkButton : Button(this@MainActivity) {
        private var businessEnabled = true
        private var coolingDown = false
        override fun setEnabled(enabled: Boolean) {
            businessEnabled = enabled
            super.setEnabled(enabled && !coolingDown)
            alpha = if (isEnabled) 1f else 0.45f
        }
        fun setCoolingDown(value: Boolean) {
            coolingDown = value
            super.setEnabled(businessEnabled && !value)
            alpha = if (isEnabled) 1f else 0.45f
        }
    }
    private fun networkButton(label: String, filled: Boolean) = NetworkButton().apply {
        styleButton(label, filled)
        networkButtons.add(this)
        setCoolingDown(!session.mockMode && api.isCoolingDown())
    }
    private fun banner(value: String, background: Int, foreground: Int) = TextView(this).apply { text = value; contentDescription = value; textSize = 14f; setTextColor(foreground); setPadding(dp(12), dp(12), dp(12), dp(12)); this.background = rounded(background, Color.TRANSPARENT, 8) }
    private fun rounded(fill: Int, stroke: Int, radius: Int) = ThemeController.rounded(fill, stroke.takeUnless { it == Color.TRANSPARENT }, dp(radius).toFloat(), dp(1))
    // 同上：取自 R.color.surface_alt，不再硬编码（原 Color.rgb(234,243,242) 与 colors.xml 重复）。
    private fun surface_alt() = palette.surfaceAlt
}
