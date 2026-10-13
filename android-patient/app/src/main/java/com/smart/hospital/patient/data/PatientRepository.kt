package com.smart.hospital.patient.data

import com.smart.hospital.patient.R
import com.smart.hospital.patient.BuildConfig
import com.smart.hospital.patient.model.*
import org.json.JSONObject
import java.net.URLEncoder
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeParseException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class PatientRepository(private val client: ApiClient, private val session: SessionStore) {
    private val mockAppointments = mutableListOf<Appointment>()
    private val mockTokens = ConcurrentHashMap<String, Appointment>()
    private val previsitAssistantText = ConcurrentHashMap<String, String>()
    @Volatile private var mockPrevisit: PrevisitSession? = null
    private val previsitOperationLock = Any()
    private var nextAppointmentId = 501L
    private val hospitalZone = ZoneId.of("Asia/Shanghai")
    private data class Identity(val baseUrl: String, val patientId: Long, val token: String)
    private fun identity() = Identity(session.baseUrl, session.patientId, session.token)
    private fun requireIdentity(expected: Identity) {
        if (identity() != expected) throw ApiException(0, "SESSION_CHANGED", session.text(R.string.data_identity_changed))
    }
    private val mockQuestions = listOf(
        "chief" to session.text(R.string.data_question_chief),
        "duration" to session.text(R.string.data_question_duration),
        "severity" to session.text(R.string.data_question_severity),
        "associated" to session.text(R.string.data_question_associated),
        "history" to session.text(R.string.data_question_history),
        "allergy" to session.text(R.string.data_question_allergy)
    )
    private fun mockDate(offset: Long = 1) = LocalDate.now(hospitalZone).plusDays(offset).toString()
    private fun mockRemaining(id: Long, initial: Int) =
        (initial - mockAppointments.count { it.scheduleId == id && it.status == "booked" }).coerceAtLeast(0)
    private fun mockSchedules() = synchronized(this) { listOf(
        Schedule(41, 9, 3, mockDate(), "AM", 20, mockRemaining(41, 5), true, session.text(R.string.data_demo_respiratory_department), session.text(R.string.data_demo_doctor_li), session.text(R.string.data_demo_doctor_li_title)),
        Schedule(42, 10, 4, mockDate(2), "PM", 8, mockRemaining(42, 8), true, session.text(R.string.data_demo_general_department), session.text(R.string.data_demo_doctor_wang), session.text(R.string.data_demo_doctor_wang_title))
    ) }

    /** A credential login always uses the real service; demo entry is an explicit separate action. */
    fun login(name: String, password: String): LoginResult {
        val d = client.post("/api/v1/auth/login", JSONObject().put("login_name", name).put("password", password))
        if (d.optString("role") != "patient") {
            throw ApiException(403, "FORBIDDEN_ROLE", session.text(R.string.data_patient_only))
        }
        return LoginResult(d.getString("token"), d.getLong("expires_at"), d.getLong("user_id"),
            d.getString("role"), d.getLong("ref_id"), d.optString("display_name"), d.getLong("patient_id"))
    }

    fun enterDemo(): LoginResult {
        require(BuildConfig.DEBUG && session.mockMode) { session.text(R.string.data_demo_debug_only) }
        resetTransientState()
        val token = UUID.randomUUID().toString().replace("-", "") + UUID.randomUUID().toString().replace("-", "")
        return LoginResult(token, System.currentTimeMillis() / 1000 + 2_592_000,
            1, "patient", 7, session.text(R.string.data_demo_patient), 7)
    }

    fun me(): CurrentUser {
        if (session.mockMode) return CurrentUser(session.userId, "patient", session.patientId, 0, session.deviceId)
        val d = client.get("/api/v1/auth/me")
        return CurrentUser(d.getLong("user_id"), d.getString("role"), d.optLong("patient_id"),
            d.optLong("doctor_id"), d.optString("device_id"))
    }

    fun logout() {
        val expected = identity()
        if (!session.mockMode) runCatching {
            client.postWithStatus("/api/v1/auth/logout", JSONObject(), expected.baseUrl, expected.token)
        }
        val cleared = synchronized(session) {
            if (identity() == expected) { session.clearLoginIfCurrent(expected.token, expected.baseUrl); true }
            else false
        }
        if (cleared) resetTransientState()
    }

    @Synchronized fun resetTransientState() {
        mockAppointments.clear(); mockTokens.clear(); previsitAssistantText.clear(); mockPrevisit = null; nextAppointmentId = 501L
    }

    fun isCoolingDown() = client.isCoolingDown()
    fun remainingCooldownSeconds() = client.remainingCooldownSeconds()

    fun triage(chief: String): TriageResult {
        if (session.mockMode) return TriageResult(false, "OK", "rules", session.text(R.string.data_demo_triage_suggestion), false,
            session.text(R.string.data_demo_triage_notice), "", mockSchedules().map { s ->
                TriageOption(s.departmentId, s.departmentName, s.doctorId, s.doctorName, s.doctorTitle,
                    s.id, s.workDate, s.period, s.remainNum, s.remainNum)
            })
        val d = client.post("/api/v1/triage", JSONObject().put("chief_complaint", chief))
        val arr = d.optJSONArray("options")
        val options = if (d.optBoolean("red_flag")) emptyList() else (0 until (arr?.length() ?: 0)).map { i ->
            val o = arr!!.getJSONObject(i)
            TriageOption(o.getLong("department_id"), o.optString("department_name"), o.getLong("doctor_id"),
                o.optString("doctor_name"), o.optString("doctor_title"), o.getLong("schedule_id"),
                o.getString("work_date"), o.getString("period"), o.getInt("remain_num"), o.optInt("total_remain"))
        }
        return TriageResult(d.optBoolean("red_flag"), d.optString("reason_code"), d.optString("source"),
            d.optString("patient_note"), d.optBoolean("truncated"), d.optString("ai_note"), d.optString("ai_reason"), options)
    }

    fun schedules(date: String): List<Schedule> {
        val requested = parseDate(date)
        if (requested.isBefore(LocalDate.now(hospitalZone))) throw ApiException(400, "VALIDATION_FAILED", session.text(R.string.data_date_not_past))
        if (session.mockMode) return mockSchedules().filter { it.workDate == requested.toString() }
        val encoded = URLEncoder.encode(requested.toString(), "UTF-8")
        val a = client.get("/api/v1/schedules?work_date=$encoded&limit=100").optJSONArray("schedules")
        return (0 until (a?.length() ?: 0)).mapNotNull { i ->
            val o = a!!.getJSONObject(i)
            val day = o.getString("work_date")
            val validDay = runCatching { LocalDate.parse(day) }.getOrNull()
            if (!o.optBoolean("enabled", false) || validDay == null || validDay.isBefore(LocalDate.now(hospitalZone)) || validDay != requested) null
            else Schedule(o.getLong("id"), o.getLong("doctor_id"), o.getLong("department_id"), day,
                o.getString("period"), o.getInt("total_num"), o.getInt("remain_num"), true,
                o.optString("department_name"), o.optString("doctor_name"), o.optString("doctor_title"))
        }
    }

    private fun parseDate(value: String): LocalDate {
        if (!Regex("\\d{4}-\\d{2}-\\d{2}").matches(value)) throw ApiException(400, "VALIDATION_FAILED", session.text(R.string.data_date_format))
        return try { LocalDate.parse(value) }
        catch (_: DateTimeParseException) { throw ApiException(400, "VALIDATION_FAILED", session.text(R.string.data_date_invalid)) }
    }

    fun book(scheduleId: Long): Appointment {
        val (expected, token) = synchronized(session) { identity() to session.bookingToken(scheduleId) }
        return bookForIdentity(scheduleId, token, expected)
    }

    fun book(scheduleId: Long, clientToken: String): Appointment = bookForIdentity(scheduleId, clientToken, identity())

    private fun bookForIdentity(scheduleId: Long, clientToken: String, expected: Identity): Appointment {
        require(scheduleId > 0 && clientToken.isNotBlank() && clientToken.length <= 64) { session.text(R.string.data_booking_invalid) }
        if (session.mockMode) return synchronized(this) {
            requireIdentity(expected)
            mockTokens[clientToken]?.let { return@synchronized it.copy(replayed = true) }
            val s = mockSchedules().firstOrNull { it.id == scheduleId }
                ?: throw ApiException(404, "SCHEDULE_NOT_FOUND", session.text(R.string.data_schedule_missing))
            if (s.remainNum <= 0) throw ApiException(409, "SLOT_GONE", session.text(R.string.data_schedule_full))
            val seq = mockAppointments.count { it.scheduleId == scheduleId } + 1
            val result = Appointment(nextAppointmentId++, s.id, session.patientId, s.doctorId, s.departmentId,
                s.workDate, s.period, seq, "booked", departmentName = s.departmentName,
                doctorName = s.doctorName, doctorTitle = s.doctorTitle)
            mockTokens[clientToken] = result; mockAppointments += result
            session.markBookingCompleted(scheduleId, result.appointmentId)
            result
        }
        val knownId = session.completedBookingId(scheduleId)
        val (status, d) = client.postWithStatus("/api/v1/appointments", JSONObject().put("schedule_id", scheduleId)
            .put("client_token", clientToken), expected.baseUrl, expected.token)
        val result = parseAppointment(d).let { it.copy(replayed = status == 200 || knownId == it.appointmentId) }
        if (result.patientId != expected.patientId || result.scheduleId != scheduleId) {
            throw ApiException(0, "INVALID_RESPONSE", session.text(R.string.data_booking_response_mismatch))
        }
        // Keep the original token after success too: retries/re-entry must identify the same order.
        synchronized(session) { requireIdentity(expected); session.markBookingCompleted(scheduleId, result.appointmentId) }
        return result
    }

    fun appointments(includeCancelled: Boolean): List<Appointment> {
        if (session.mockMode) return synchronized(this) { mockAppointments.filter { includeCancelled || it.status != "cancelled" } }
        val a = client.get("/api/v1/appointments?include_cancelled=$includeCancelled&limit=200").optJSONArray("appointments")
        return (0 until (a?.length() ?: 0)).map { parseAppointment(a!!.getJSONObject(it)) }
    }

    fun cancel(id: Long): Appointment {
        if (session.mockMode) return synchronized(this) {
            val index = mockAppointments.indexOfFirst { it.appointmentId == id }
            if (index < 0) throw ApiException(404, "APPOINTMENT_NOT_FOUND", session.text(R.string.data_appointment_not_found))
            val old = mockAppointments[index]
            if (old.status != "booked") throw ApiException(409, "APPOINTMENT_NOT_CANCELLABLE", session.text(R.string.data_cancellation_invalid_state))
            val result = old.copy(status = "cancelled", slotRestored = true)
            mockAppointments[index] = result
            mockTokens.entries.removeIf { it.value.appointmentId == id }
            session.clearBooking(old.scheduleId)
            result
        }
        val expected = identity()
        return parseAppointment(client.post("/api/v1/appointments/$id/cancel", JSONObject())).also {
            if (it.patientId != expected.patientId || it.appointmentId != id) {
                throw ApiException(0, "INVALID_RESPONSE", session.text(R.string.data_cancellation_response_mismatch))
            }
            synchronized(session) {
                requireIdentity(expected)
                if (it.status == "cancelled") session.clearBooking(it.scheduleId)
            }
        }
    }

    @Synchronized fun resetPrevisit() { session.clearPrevisitSession(); previsitAssistantText.clear(); mockPrevisit = null }

    private fun emptyPrevisit(expired: Boolean = false) = PrevisitSession("", 0, 0, 0, false,
        "chief", session.text(R.string.data_question_chief), expired = expired)

    fun preparePrevisit(): PrevisitSession = synchronized(previsitOperationLock) { preparePrevisitInternal() }

    private fun preparePrevisitInternal(): PrevisitSession {
        val saved = session.previsitSessionId
        if (saved.isBlank()) return emptyPrevisit()
        if (session.mockMode) return mockPrevisit?.takeIf { it.sessionId == saved }
            ?: emptyPrevisit(expired = true).also { session.clearPrevisitSession() }
        val expected = identity()
        return try {
            parsePrevisit(client.get("/api/v1/previsit/${encodeSegment(saved)}")).also { requireIdentity(expected) }
        }
        catch (e: ApiException) {
            if (e.status != 404) throw e
            synchronized(session) { requireIdentity(expected); session.clearPrevisitSession() }
            emptyPrevisit(expired = true)
        }
    }

    fun startPrevisit(chiefComplaint: String): PrevisitSession = synchronized(previsitOperationLock) {
        startPrevisitInternal(chiefComplaint)
    }

    private fun startPrevisitInternal(chiefComplaint: String): PrevisitSession {
        require(chiefComplaint.isNotBlank()) { session.text(R.string.data_chief_required) }
        // A timed-out stream may already have created a session. Recover instead of duplicating it.
        if (session.previsitSessionId.isNotBlank()) {
            val recovered = preparePrevisit()
            if (recovered.sessionId.isNotBlank()) return if (!recovered.complete && recovered.nextSlot == "chief")
                answerPrevisit(recovered.sessionId, "chief", chiefComplaint) else recovered
        }
        if (session.mockMode) {
            val id = UUID.randomUUID().toString().replace("-", "")
            session.setPrevisitSession(id)
            mockPrevisit = PrevisitSession(id, 0, 0, mockQuestions.size, false, "chief", mockQuestions.first().second)
            return answerPrevisit(id, "chief", chiefComplaint)
        }
        val expected = identity()
        val stream = client.openPrevisitStream()
        requireIdentity(expected)
        previsitAssistantText[stream.sessionId] = stream.text
        val state = parsePrevisit(client.get("/api/v1/previsit/${encodeSegment(stream.sessionId)}"))
        requireIdentity(expected)
        // main reads a legacy query for chief. Keep the shared protocol and sensitive text
        // out of the stream URL/headers: submit the real chief via the JSON answer endpoint.
        return if (!state.complete && state.nextSlot == "chief") answerPrevisit(state.sessionId, "chief", chiefComplaint) else state
    }

    fun answerPrevisit(sessionId: String, slot: String, value: String): PrevisitSession = synchronized(previsitOperationLock) {
        answerPrevisitInternal(sessionId, slot, value)
    }

    private fun answerPrevisitInternal(sessionId: String, slot: String, value: String): PrevisitSession {
        require(sessionId.isNotBlank() && slot.isNotBlank() && value.isNotBlank()) { session.text(R.string.data_answer_required) }
        if (session.mockMode) return synchronized(this) {
            val previous = mockPrevisit?.takeIf { it.sessionId == sessionId }
                ?: throw ApiException(404, "PREVISIT_NOT_FOUND", session.text(R.string.data_previsit_not_found))
            if (previous.complete) throw ApiException(409, "PREVISIT_COMPLETE", session.text(R.string.data_previsit_restart))
            if (slot != previous.nextSlot) throw ApiException(400, "VALIDATION_FAILED", session.text(R.string.data_answer_current_question))
            val form = previous.form + (slot to value)
            val next = mockQuestions.firstOrNull { form[it.first].isNullOrBlank() }
            val result = PrevisitSession(sessionId, previous.turn + 1, form.size, mockQuestions.size,
                next == null, next?.first.orEmpty(), next?.second.orEmpty(), form)
            mockPrevisit = result
            result
        }
        val expected = identity()
        return try {
            val currentState = parsePrevisit(client.get("/api/v1/previsit/${encodeSegment(sessionId)}"))
            requireIdentity(expected)
            // A previous request can have succeeded after its UI callback was discarded or timed out.
            // Re-read the authoritative slot and never overwrite a saved/completed answer on retry.
            if (currentState.complete || currentState.nextSlot != slot) currentState
            else parsePrevisit(client.post("/api/v1/previsit/answer", JSONObject().put("session_id", sessionId)
                .put("slot", slot).put("value", value))).also { requireIdentity(expected) }
        } catch (e: ApiException) {
            if (e.status != 404) throw e
            synchronized(session) { requireIdentity(expected); session.clearPrevisitSession() }
            emptyPrevisit(expired = true)
        }
    }

    private fun parsePrevisit(o: JSONObject): PrevisitSession {
        val form = o.optJSONObject("form")
        val answers = mutableMapOf<String, String>()
        form?.let { values -> values.keys().forEach { key -> answers[key] = values.optString(key) } }
        return PrevisitSession(o.getString("session_id"), o.getInt("turn"), o.getInt("filled"),
            o.getInt("total_slots"), o.getBoolean("complete"), o.getString("next_slot"),
            o.getString("next_question"), answers, assistantText = previsitAssistantText[o.getString("session_id")].orEmpty())
    }

    fun medicalRecords(): List<MedicalRecordSummary> {
        if (session.mockMode) return emptyList()
        val a = client.get("/api/v1/medical-records?limit=200").optJSONArray("items")
        return (0 until (a?.length() ?: 0)).map { parseMedicalSummary(a!!.getJSONObject(it)) }
    }

    fun medicalRecord(appointmentId: Long): MedicalRecordDetail {
        require(appointmentId > 0) { session.text(R.string.data_appointment_invalid) }
        if (session.mockMode) throw ApiException(404, "EMR_NOT_FOUND", session.text(R.string.data_demo_records_empty))
        val d = client.get("/api/v1/medical-records/$appointmentId")
        val summary = parseMedicalSummary(d)
        if (!summary.locked) throw ApiException(404, "EMR_NOT_FOUND", session.text(R.string.data_record_unavailable))
        val a = d.optJSONArray("sections")
        val sections = (0 until (a?.length() ?: 0)).map { i ->
            val o = a!!.getJSONObject(i)
            MedicalRecordSection(o.getString("key"), o.getString("label"), o.optString("value"), o.optBoolean("required_to_lock"))
        }
        return MedicalRecordDetail(summary, sections)
    }

    private fun parseMedicalSummary(o: JSONObject) = MedicalRecordSummary(o.getLong("id"), o.getLong("appointment_id"),
        o.getString("status"), o.getBoolean("locked"), o.getInt("filled"), o.getInt("total_sections"),
        o.optLong("patient_id"), o.optLong("doctor_id"), o.optLong("department_id"), o.optString("visit_date"),
        o.optString("period"), o.optString("department_name"), o.optString("doctor_name"), o.optString("doctor_title"),
        o.optLong("created_at"), o.optLong("updated_at"), o.optBoolean("complete"))

    private fun parseAppointment(o: JSONObject) = Appointment(o.getLong("appointment_id"), o.getLong("schedule_id"),
        o.getLong("patient_id"), o.getLong("doctor_id"), o.getLong("department_id"), o.getString("visit_date"),
        o.getString("period"), o.getInt("seq_no"), o.getString("status"), o.opt("slot_restored") == true,
        o.optString("warning"), departmentName = o.optString("department_name"),
        doctorName = o.optString("doctor_name"), doctorTitle = o.optString("doctor_title"))

    private fun encodeSegment(value: String) = URLEncoder.encode(value, "UTF-8").replace("+", "%20")
}
