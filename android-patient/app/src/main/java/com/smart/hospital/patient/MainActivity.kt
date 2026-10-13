package com.smart.hospital.patient

import android.app.Activity
import android.app.AlertDialog
import android.content.Intent
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
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import android.widget.*
import com.smart.hospital.patient.data.*
import com.smart.hospital.patient.model.*
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.time.LocalDate
import java.time.ZoneId

class MainActivity : Activity() {
    private val bg = Color.rgb(243, 248, 247)
    private val surface = Color.WHITE
    private val primary = Color.rgb(0, 169, 167)
    private val primaryDark = Color.rgb(0, 127, 125)
    private val primarySoft = Color.rgb(223, 245, 243)
    private val ink = Color.rgb(25, 51, 49)
    private val secondary = Color.rgb(95, 115, 113)
    private val border = Color.rgb(214, 228, 226)
    private val danger = Color.rgb(200, 59, 59)
    private val dangerSoft = Color.rgb(252, 232, 232)
    private val warning = Color.rgb(163, 90, 0)
    private val warningSoft = Color.rgb(255, 241, 217)
    private val success = Color.rgb(20, 122, 85)
    private val successSoft = Color.rgb(223, 243, 233)
    private val info = Color.rgb(49, 91, 150)
    private val infoSoft = Color.rgb(231, 239, 251)
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
    private var previsitValue: EditText? = null
    private var triageDraft = ""
    private var bookingDate = ""
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

    private enum class Screen { LOGIN, HOME, TRIAGE, PREVISIT, BOOKING, APPOINTMENTS, RECORDS, RECORD_DETAIL, PROFILE }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        session = SessionStore(this)
        api = ApiClient(session)
        repo = PatientRepository(api, session)
        content = FrameLayout(this).apply { setBackgroundColor(bg) }
        setContentView(content)
        if (Build.VERSION.SDK_INT >= 33) {
            backCallback = OnBackInvokedCallback { handleBack() }.also {
                onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, it)
            }
        }
        if (session.isLoggedIn()) show(Screen.HOME, true) else { session.clearLogin(); show(Screen.LOGIN, true) }
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
        }
        val wrapper = vertical()
        if (session.mockMode) wrapper.addView(banner(getString(R.string.demo_notice), warningSoft, warning), lp(-1, -2))
        cooldownBanner = banner("", warningSoft, warning).apply { id = R.id.cooldown_banner; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }.also { wrapper.addView(it, lp(-1, -2)) }
        wrapper.addView(page, lp(-1, 0).also { it.weight = 1f })
        content.addView(wrapper, main)
        updateCooldownBanner(renderVersion)
    }

    private fun loginView(): View {
        val scroll = ScrollView(this); val box = column(16)
        box.setPadding(dp(28), dp(42), dp(28), dp(28))
        box.addView(textView(getString(R.string.app_name), 30f, ink, true))
        box.addView(textView(getString(R.string.login_services), 14f, secondary), spaced(8))
        val name = edit(getString(R.string.login_name_hint), session.lastLoginName).apply { id = R.id.login_name; isSingleLine = true }
        remember(name) { session.lastLoginName = it }
        val password = edit(getString(R.string.login_password_hint)).apply {
            id = R.id.login_password
            isSingleLine = true; inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
            setSaveEnabled(false)
        }
        box.addView(name, lp(-1, dp(48)).also { it.topMargin = dp(32) })
        box.addView(password, lp(-1, dp(48)).also { it.topMargin = dp(12) })
        val message = textView(loginNotice, 13f, danger).apply { id = R.id.login_message }; box.addView(message, spaced(10))
        val submit = networkButton(getString(R.string.login_action), true).apply { id = R.id.login_submit }; box.addView(submit, lp(-1, dp(46)).also { it.topMargin = dp(18) })
        loginButton = submit; loginMessage = message
        if (BuildConfig.DEBUG) {
            val demo = button(getString(R.string.demo_enter), false)
            box.addView(demo, lp(-1, dp(46)).also { it.topMargin = dp(10) })
            demo.setOnClickListener {
                if (loginBusy) return@setOnClickListener
                clearPatientState(); session.switchMode(true); session.saveLogin(repo.enterDemo())
                password.text?.clear(); loginNotice = ""; show(Screen.HOME, true)
            }
        }
        val address = button(getString(R.string.service_address_setup), false); box.addView(address, spaced(16))
        address.setOnClickListener { if (!loginBusy) editServiceAddress() }
        box.addView(textView(getString(R.string.login_mode_note), 12f, secondary), spaced(12))
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
        val root = vertical(); root.addView(header(getString(R.string.home_greeting, session.displayName.ifBlank { getString(R.string.patient_fallback) }), getString(R.string.home_subtitle)))
        val body = bodyColumn(); val notice = textView(getString(R.string.appointments_syncing), 14f, secondary); body.addView(notice)
        val retry = networkButton(getString(R.string.sync_retry), false); body.addView(retry, spaced(8))
        val quick = cardColumn(); quick.addView(textView(getString(R.string.home_quick_services), 18f, ink, true))
        listOf(getString(R.string.triage_title) to Screen.TRIAGE, getString(R.string.previsit_title) to Screen.PREVISIT, getString(R.string.booking_title) to Screen.BOOKING, getString(R.string.records_title) to Screen.RECORDS).forEach { (label, target) ->
            val action = button(label, false); quick.addView(action, lp(-1, dp(44)).also { it.topMargin = dp(10) })
            action.setOnClickListener { show(target) }
        }
        body.addView(quick, spaced(14)); val appointments = vertical(); body.addView(appointments, spaced(18))
        fun load() {
            retry.isEnabled = false; notice.text = getString(R.string.appointments_syncing)
            runAsync({ repo.appointments(false) }, { items ->
                retry.isEnabled = true
                notice.text = if (items.isEmpty()) getString(R.string.appointments_pending_empty) else getString(R.string.appointments_recent, items.first().visitDate, periodText(items.first().period), statusText(items.first().status))
                appointments.removeAllViews(); items.firstOrNull()?.let { appointments.addView(appointmentCard(it, false)) }
            }, { error -> retry.isEnabled = true; notice.text = userMessage(error) })
        }
        retry.setOnClickListener { load() }; load(); addBody(root, body, Screen.HOME); return root
    }
    private fun triageView(): View {
        val root = vertical(); root.addView(header(getString(R.string.triage_title), getString(R.string.triage_subtitle), true))
        val body = bodyColumn(); val input = edit(getString(R.string.triage_hint), triageDraft).apply { minLines = 3; gravity = Gravity.TOP }
        val count = textView(getString(R.string.triage_character_count, triageDraft.codePointCount(0, triageDraft.length)), 12f, secondary)
        remember(input) { triageDraft = it; count.text = getString(R.string.triage_character_count, it.codePointCount(0, it.length)) }
        body.addView(input, lp(-1, dp(110))); body.addView(count, spaced(4))
        body.addView(textView(getString(R.string.triage_length_note), 12f, secondary), spaced(6))
        val message = textView("", 13f, danger); body.addView(message, spaced(8))
        val submit = networkButton(if (triageResult == null) getString(R.string.triage_start) else getString(R.string.triage_restart), true); body.addView(submit, lp(-1, dp(46)).also { it.topMargin = dp(10) })
        val resultBox = vertical(); body.addView(resultBox, spaced(16))
        fun renderResult(result: TriageResult) {
            resultBox.removeAllViews()
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
                card.addView(choose, lp(-1, dp(42)).also { it.topMargin = dp(10) })
                choose.setOnClickListener {
                    selectedSchedule = Schedule(option.scheduleId, option.doctorId, option.departmentId, option.workDate, option.period, option.remainNum, option.remainNum, true, option.departmentName, option.doctorName, option.doctorTitle)
                    bookingDate = option.workDate; show(Screen.BOOKING)
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
        val root = vertical(); root.addView(header(getString(R.string.booking_title), getString(R.string.booking_subtitle), true)); val body = bodyColumn()
        val date = edit(getString(R.string.booking_date_hint), bookingDate.ifBlank { selectedSchedule?.workDate ?: today() }).apply { isSingleLine = true }
        bookingDate = date.text.toString(); remember(date) { bookingDate = it }
        val query = networkButton(getString(R.string.booking_query), true); body.addView(date, lp(-1, dp(48))); body.addView(query, lp(-1, dp(46)).also { it.topMargin = dp(10) })
        val message = textView("", 13f, danger); body.addView(message, spaced(8)); val list = vertical(); body.addView(list, spaced(14))
        fun load() {
            query.isEnabled = false; query.text = getString(R.string.booking_query_pending); message.text = ""; list.removeAllViews()
            runAsync({ repo.schedules(date.text.toString().trim()) }, { schedules ->
                query.isEnabled = true; query.text = getString(R.string.booking_query)
                if (schedules.isEmpty()) list.addView(banner(getString(R.string.booking_slots_empty), infoSoft, info))
                schedules.sortedByDescending { it.id == selectedSchedule?.id }.forEach { list.addView(scheduleCard(it) { load() }, spaced(10)) }
            }, { error -> query.isEnabled = true; query.text = getString(R.string.booking_query_retry); message.text = userMessage(error) })
        }
        query.setOnClickListener { load() }; load(); addBody(root, body, Screen.BOOKING); return root
    }

    private fun scheduleLabel(schedule: Schedule): String {
        val department = schedule.departmentName.ifBlank { selectedSchedule?.takeIf { it.departmentId == schedule.departmentId }?.departmentName.orEmpty().ifBlank { getString(R.string.department_fallback, schedule.departmentId) } }
        val doctor = schedule.doctorName.ifBlank { selectedSchedule?.takeIf { it.doctorId == schedule.doctorId }?.doctorName.orEmpty().ifBlank { getString(R.string.doctor_fallback, schedule.doctorId) } }
        return getString(R.string.provider_label, department, doctor)
    }

    private fun scheduleCard(schedule: Schedule, refresh: () -> Unit): View {
        val card = cardColumn(); val selected = selectedSchedule?.id == schedule.id
        card.addView(textView((if (selected) getString(R.string.booking_selected_prefix) else "") + scheduleLabel(schedule), 16f, ink, true))
        if (schedule.doctorTitle.isNotBlank()) card.addView(textView(schedule.doctorTitle, 13f, secondary), spaced(4))
        card.addView(textView(getString(R.string.booking_slot_summary, schedule.workDate, periodText(schedule.period), schedule.totalNum, schedule.remainNum), 13f, secondary), spaced(6))
        val confirm = networkButton(if (schedule.remainNum > 0 && schedule.enabled) (if (selected) getString(R.string.booking_confirm_selected) else getString(R.string.booking_confirm)) else getString(R.string.booking_unavailable), false)
        confirm.isEnabled = schedule.remainNum > 0 && schedule.enabled
        card.addView(confirm, lp(-1, dp(42)).also { it.topMargin = dp(10) })
        confirm.setOnClickListener {
            selectedSchedule = schedule
            AlertDialog.Builder(this).setTitle(if (session.mockMode) getString(R.string.booking_demo_confirm) else getString(R.string.booking_confirm))
                .setMessage(getString(R.string.booking_confirm_summary, schedule.workDate, periodText(schedule.period), scheduleLabel(schedule)) + (if (session.mockMode) getString(R.string.booking_demo_confirm_note) else ""))
                .setNegativeButton(getString(R.string.dialog_reconsider), null).setPositiveButton(getString(R.string.dialog_confirm)) { _, _ ->
                    confirm.isEnabled = false; confirm.text = getString(R.string.booking_pending)
                    runAsync({ repo.book(schedule.id) }, { item ->
                        appointmentOutcome = when {
                            session.mockMode -> getString(R.string.demo_booking_success, item.seqNo)
                            item.replayed -> getString(R.string.booking_replayed, item.seqNo, statusText(item.status))
                            item.status == "booked" -> getString(R.string.booking_success, item.seqNo)
                            else -> getString(R.string.booking_result_status, statusText(item.status))
                        }
                        appointmentOutcomeWarning = item.status != "booked"
                        show(Screen.APPOINTMENTS, true)
                    }, { error ->
                        toast(userMessage(error))
                        if ((error as? ApiException)?.status in listOf(404, 409)) refresh()
                        else { confirm.isEnabled = true; confirm.text = getString(R.string.booking_retry) }
                    })
                }.show()
        }
        return card
    }
    private fun appointmentsView(): View {
        val root = vertical(); root.addView(header(getString(R.string.appointments_title), getString(R.string.appointments_subtitle), true)); val body = bodyColumn()
        body.addView(banner(appointmentOutcome, if (appointmentOutcomeWarning) warningSoft else successSoft, if (appointmentOutcomeWarning) warning else success).apply {
            id = R.id.appointment_outcome
            visibility = if (appointmentOutcome.isBlank()) View.GONE else View.VISIBLE
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        }, spaced(8))
        val message = textView(getString(R.string.booking_orders_syncing), 13f, secondary); body.addView(message)
        val retry = networkButton(getString(R.string.appointments_refresh), false); body.addView(retry, spaced(8)); val list = vertical(); body.addView(list, spaced(12))
        fun load() {
            retry.isEnabled = false
            runAsync({ repo.appointments(true) }, { items ->
                retry.isEnabled = true; message.text = if (items.isEmpty()) getString(R.string.appointments_empty) else ""
                list.removeAllViews(); items.forEach { list.addView(appointmentCard(it, true), spaced(10)) }
            }, { error -> retry.isEnabled = true; message.text = userMessage(error) })
        }
        retry.setOnClickListener { load() }; load(); addBody(root, body, Screen.APPOINTMENTS); return root
    }

    private fun appointmentCard(item: Appointment, allowActions: Boolean): View {
        val card = cardColumn(); card.addView(textView(getString(R.string.appointment_date_summary, item.visitDate, periodText(item.period)), 16f, ink, true))
        card.addView(textView(getString(R.string.appointment_provider_summary, item.seqNo, item.departmentName.ifBlank { getString(R.string.department_fallback, item.departmentId) }, item.doctorName.ifBlank { getString(R.string.doctor_fallback, item.doctorId) }), 13f, secondary), spaced(6))
        card.addView(banner(statusText(item.status), statusBackground(item.status), statusColor(item.status)), spaced(10))
        if (allowActions && item.status == "booked") {
            val cancel = networkButton(getString(R.string.cancel_action), false); card.addView(cancel, lp(-1, dp(42)).also { it.topMargin = dp(10) })
            cancel.setOnClickListener {
                AlertDialog.Builder(this).setTitle(getString(R.string.cancel_title))
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
            val records = button(getString(R.string.record_open), false); card.addView(records, lp(-1, dp(42)).also { it.topMargin = dp(10) })
            records.setOnClickListener { recordAppointmentId = item.appointmentId; show(Screen.RECORD_DETAIL) }
        }
        return card
    }

    private fun previsitView(): View {
        val root = vertical(); root.addView(header(getString(R.string.previsit_title), getString(R.string.previsit_subtitle), true)); val body = bodyColumn()
        val question = textView(getString(R.string.previsit_initial_question), 18f, ink, true); body.addView(question)
        body.addView(textView(getString(R.string.previsit_answer_note), 13f, secondary), spaced(6))
        val assistant = textView("", 13f, secondary); body.addView(assistant, spaced(6))
        val answer = edit(getString(R.string.previsit_answer_hint), previsitDraft).apply { minLines = 4; gravity = Gravity.TOP }
        previsitValue = answer; remember(answer) { previsitDraft = it }; body.addView(answer, lp(-1, dp(120)).also { it.topMargin = dp(14) })
        val message = textView("", 13f, danger); body.addView(message, spaced(8))
        val send = networkButton(getString(R.string.previsit_submit), true); body.addView(send, lp(-1, dp(46)).also { it.topMargin = dp(10) })
        val progress = textView("", 13f, secondary); body.addView(progress, spaced(12))
        val retry = networkButton(getString(R.string.previsit_load_retry), false).apply { visibility = View.GONE }; body.addView(retry, spaced(10))
        val restart = button(getString(R.string.previsit_restart), false).apply { visibility = View.GONE }; body.addView(restart, spaced(10))
        var loaded = false
        fun display(result: PrevisitSession) {
            val previous = previsit
            if ((previous != null && (previous.sessionId != result.sessionId || previous.nextSlot != result.nextSlot)) ||
                (previous == null && result.sessionId.isNotBlank() && result.nextSlot != "chief")) answer.text?.clear()
            previsit = result; loaded = true
            question.text = when { result.complete -> getString(R.string.previsit_complete); result.sessionId.isBlank() -> getString(R.string.previsit_initial_question); else -> result.nextQuestion.ifBlank { getString(R.string.previsit_question_fallback) } }
            assistant.text = if (result.assistantText.isBlank()) "" else getString(R.string.previsit_assistant_note, result.assistantText)
            progress.text = if (result.sessionId.isBlank()) getString(R.string.previsit_not_started) else getString(R.string.previsit_progress, result.filled, result.totalSlots)
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
            }, { sync.isEnabled = true; toast(getString(R.string.identity_synced)) }, { error -> sync.isEnabled = true; toast(userMessage(error)) })
        }
        body.addView(identity)
        val settings = cardColumn(); settings.addView(textView(if (session.mockMode) getString(R.string.demo_mode_label) else getString(R.string.online_mode_label), 18f, ink, true))
        if (BuildConfig.DEBUG) {
            val mode = button(if (session.mockMode) getString(R.string.demo_exit) else getString(R.string.demo_switch_enter), false); settings.addView(mode, spaced(10))
            mode.setOnClickListener {
                if (logoutBusy) return@setOnClickListener
                val targetDemo = !session.mockMode
                AlertDialog.Builder(this).setTitle(getString(R.string.mode_switch_title)).setMessage(getString(R.string.mode_switch_note))
                    .setNegativeButton(getString(R.string.dialog_cancel), null).setPositiveButton(getString(R.string.mode_switch_action)) { _, _ ->
                        clearPatientState(); session.switchMode(targetDemo)
                        if (targetDemo) { session.saveLogin(repo.enterDemo()); show(Screen.HOME, true) }
                        else { loginNotice = getString(R.string.demo_exited); show(Screen.LOGIN, true) }
                    }.show()
            }
        }
        val address = button(getString(R.string.service_address_edit), false); settings.addView(address, spaced(10)); address.setOnClickListener { if (!logoutBusy) editServiceAddress() }
        settings.addView(textView(getString(R.string.service_address_security_note), 12f, warning), spaced(10)); body.addView(settings, spaced(18))
        val records = button(getString(R.string.records_title), false); records.setOnClickListener { show(Screen.RECORDS) }; body.addView(records, spaced(12))
        val logout = button(getString(R.string.logout_action), true); body.addView(logout, lp(-1, dp(46)).also { it.topMargin = dp(20) })
        logout.setOnClickListener {
            logout.isEnabled = false; logoutBusy = true
            runAsync({ repo.logout() }, { clearPatientState(); loginNotice = getString(R.string.logout_success); show(Screen.LOGIN, true) }, {
                session.clearLogin(); clearPatientState(); loginNotice = getString(R.string.logout_local_success); show(Screen.LOGIN, true)
            })
        }
        addBody(root, body, Screen.PROFILE); return root
    }

    private fun editServiceAddress() {
        val value = edit(getString(R.string.service_address_title), session.baseUrl).apply { isSingleLine = true }
        val dialog = AlertDialog.Builder(this).setTitle(getString(R.string.service_address_title)).setView(value)
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
        triageDraft = ""; triageResult = null; selectedSchedule = null; bookingDate = ""
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
        setPadding(dp(12), dp(12), dp(12), dp(12)); background = rounded(surface, border, 8)
    }
    private fun addBody(root: LinearLayout, body: View, nav: Screen? = null) {
        root.addView(ScrollView(this).apply { addView(body) }, lp(-1, 0).also { it.weight = 1f })
        if (nav != null) root.addView(bottomNav(nav))
    }
    private fun bodyColumn() = vertical().apply { setPadding(dp(16), dp(8), dp(16), dp(18)) }
    private fun spaced(top: Int) = lp(-1, -2).also { it.topMargin = dp(top) }
    private fun toast(message: String) = Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    private fun bottomNav(selected: Screen): View { val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; setBackgroundColor(surface); setPadding(dp(4), 0, dp(4), dp(4)) }; listOf(getString(R.string.nav_home) to Screen.HOME, getString(R.string.nav_triage) to Screen.TRIAGE, getString(R.string.nav_booking) to Screen.BOOKING, getString(R.string.nav_appointments) to Screen.APPOINTMENTS, getString(R.string.profile_title) to Screen.PROFILE).forEach { (label, target) -> val b = TextView(this).apply { text = label; textSize = 12f; gravity = Gravity.CENTER; setTextColor(if (selected == target) primaryDark else secondary); setPadding(0, dp(8), 0, 0); setOnClickListener { if (target != selected) show(target, true) } }; row.addView(b, LinearLayout.LayoutParams(0, dp(58), 1f)) }; return row }
    private fun header(title: String, subtitle: String, back: Boolean = false): View { val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL; setPadding(dp(if (back) 4 else 16), dp(14), dp(16), dp(12)); setBackgroundColor(bg) }; if (back) { val b = TextView(this).apply { text = "‹"; textSize = 32f; gravity = Gravity.CENTER; setTextColor(ink); contentDescription = getString(R.string.nav_back); setOnClickListener { handleBack() } }; row.addView(b, LinearLayout.LayoutParams(dp(44), dp(48))) }; val box = vertical(); box.addView(textView(title, 24f, ink, true)); box.addView(textView(subtitle, 13f, secondary), lp(-1, -2).also { it.topMargin = dp(4) }); row.addView(box, LinearLayout.LayoutParams(0, -2, 1f)); return row }
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
        return when {
            e.status == 401 && current == Screen.LOGIN && e.code == "AUTH_BAD_CREDENTIALS" -> getString(R.string.login_bad_credentials)
            e.status == 401 -> getString(R.string.login_expired)
            e.status == 403 && e.code == "FORBIDDEN_ROLE" && !session.isLoggedIn() -> getString(R.string.patient_role_required)
            e.status == 429 -> getString(R.string.cooldown_error, api.remainingCooldownSeconds().coerceAtLeast(1))
            e.status >= 500 -> getString(R.string.service_unavailable)
            else -> e.message
        }
    }
    private fun periodText(p: String) = when (p.trim().uppercase(Locale.ROOT)) {
        "AM" -> getString(R.string.period_am); "PM" -> getString(R.string.period_pm); "NIGHT" -> getString(R.string.period_night); "" -> getString(R.string.period_unknown); else -> getString(R.string.period_other, p.trim())
    }
    private fun statusText(s: String) = mapOf("booked" to getString(R.string.status_booked), "visiting" to getString(R.string.status_visiting), "done" to getString(R.string.status_done), "cancelled" to getString(R.string.status_cancelled), "no_show" to getString(R.string.status_no_show))[s] ?: s.ifBlank { getString(R.string.status_unknown) }
    private fun statusColor(s: String) = when (s) { "booked" -> info; "visiting" -> primaryDark; "done" -> success; "cancelled", "no_show" -> danger; else -> secondary }
    private fun statusBackground(s: String) = when (s) { "cancelled", "no_show" -> dangerSoft; "done" -> successSoft; else -> primarySoft }
    private fun today() = LocalDate.now(ZoneId.of("Asia/Shanghai")).toString()
    private fun formatEpoch(value: Long) = if (value <= 0) getString(R.string.time_unknown) else SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.getDefault()).format(Date(value * 1000))
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun lp(w: Int, h: Int) = LinearLayout.LayoutParams(w, h)
    private fun vertical(gap: Int = 0) = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; if (gap > 0) setPadding(dp(gap), dp(gap), dp(gap), dp(gap)) }
    private fun column(gap: Int) = vertical(gap)
    private fun cardColumn() = vertical().apply { setPadding(dp(14), dp(14), dp(14), dp(14)); background = rounded(surface, border, 8) }
    private fun textView(value: String, size: Float, color: Int, bold: Boolean = false) = TextView(this).apply { text = value; textSize = size; setTextColor(color); if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD) }
    private fun button(label: String, filled: Boolean) = Button(this).apply { text = label; contentDescription = label; textSize = 15f; isAllCaps = false; setTextColor(if (filled) Color.WHITE else primaryDark); background = rounded(if (filled) primary else primarySoft, if (filled) Color.TRANSPARENT else primary, 8); minHeight = 0; minimumHeight = 0 }
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
        text = label; contentDescription = label; textSize = 15f; isAllCaps = false
        setTextColor(if (filled) Color.WHITE else primaryDark)
        background = rounded(if (filled) primary else primarySoft, if (filled) Color.TRANSPARENT else primary, 8)
        minHeight = 0; minimumHeight = 0
        networkButtons.add(this)
        setCoolingDown(!session.mockMode && api.isCoolingDown())
    }
    private fun banner(value: String, background: Int, foreground: Int) = TextView(this).apply { text = value; contentDescription = value; textSize = 14f; setTextColor(foreground); setPadding(dp(12), dp(12), dp(12), dp(12)); this.background = rounded(background, Color.TRANSPARENT, 8) }
    private fun rounded(fill: Int, stroke: Int, radius: Int) = GradientDrawable().apply { setColor(fill); if (stroke != Color.TRANSPARENT) setStroke(dp(1), stroke); cornerRadius = dp(radius).toFloat() }
    private fun surface_alt() = Color.rgb(234, 243, 242)
}
