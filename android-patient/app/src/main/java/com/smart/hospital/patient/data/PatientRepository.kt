package com.smart.hospital.patient.data

import com.smart.hospital.patient.R
import com.smart.hospital.patient.BuildConfig
import com.smart.hospital.patient.model.*
import org.json.JSONObject
import java.net.URLEncoder
import java.time.LocalDate
import java.time.ZoneOffset
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
    private var mockSeedIdentity: Identity? = null
    // A fixed demonstration clock keeps the two clients' fixture dates reproducible.
    private val mockToday = LocalDate.of(2026, 11, 20)
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
    private fun mockDate(offset: Long = 0) = mockToday.plusDays(offset).toString()
    private fun occupiesSchedule(status: String) = status !in setOf("done", "cancelled", "no_show")
    private fun mockRemaining(id: Long, initial: Int) =
        (initial - mockAppointments.count { it.scheduleId == id && !it.slotRestored }).coerceAtLeast(0)
    private fun mockSchedules() = synchronized(this) {
        ensureDemoInitialized()
        listOf(
            // Baselines exclude other patients' occupied slots; local fixtures deduct once each.
            Schedule(41, 9, 3, mockDate(), "AM", 20, mockRemaining(41, 8), true, session.text(R.string.data_demo_respiratory_department), session.text(R.string.data_demo_doctor_li), session.text(R.string.data_demo_doctor_li_title)),
            Schedule(42, 9, 3, mockDate(), "PM", 20, mockRemaining(42, 2), true, session.text(R.string.data_demo_respiratory_department), session.text(R.string.data_demo_doctor_li), session.text(R.string.data_demo_doctor_li_title)),
            Schedule(48, 15, 5, mockDate(1), "PM", 30, mockRemaining(48, 9), true, session.text(R.string.align_demo_general_department), session.text(R.string.align_demo_doctor_zhou), session.text(R.string.align_demo_doctor_zhou_title)),
            // A separate unoccupied slot lets the presentation demonstrate creating a new order.
            Schedule(49, 15, 5, mockDate(), "PM", 20, mockRemaining(49, 10), true, session.text(R.string.align_demo_general_department), session.text(R.string.align_demo_doctor_zhou), session.text(R.string.align_demo_doctor_zhou_title))
        )
    }

    /** Seed only after saveLogin; enterDemo itself runs before the patient identity exists. */
    @Synchronized private fun ensureDemoInitialized(requestedIdentity: Identity? = null) {
        synchronized(session) {
            check(BuildConfig.DEBUG && session.mockMode && session.isLoggedIn() && session.role == "patient") {
                session.text(R.string.data_demo_debug_only)
            }
            if (requestedIdentity != null) requireIdentity(requestedIdentity)
            val expected = identity()
            if (mockSeedIdentity == expected) return
            // First fixture read must not discard a previsit started on another page.
            if (mockSeedIdentity != null) resetTransientState()
            fun fixture(id: Long, scheduleId: Long, doctorId: Long, departmentId: Long,
                        date: String, period: String, seq: Int, status: String): Appointment {
                val arrived = status in setOf("arrived", "waiting", "visiting", "done")
                val started = status in setOf("visiting", "done")
                val base = LocalDate.parse(date).atStartOfDay().toEpochSecond(ZoneOffset.ofHours(8)) + 8 * 3600
                return Appointment(id, scheduleId, expected.patientId, doctorId, departmentId, date, period, seq, status,
                    slotRestored = status == "cancelled",
                    departmentName = session.text(if (departmentId == 3L) R.string.data_demo_respiratory_department else R.string.align_demo_general_department),
                    doctorName = session.text(if (doctorId == 9L) R.string.data_demo_doctor_li else R.string.align_demo_doctor_zhou),
                    doctorTitle = session.text(if (doctorId == 9L) R.string.data_demo_doctor_li_title else R.string.align_demo_doctor_zhou_title),
                    createdAt = base - 86400, arrivedAt = if (arrived) base + id else 0,
                    waitingAt = if (status in setOf("waiting", "visiting", "done")) base + id + 300 else 0,
                    startedAt = if (started) base + id + 600 else 0,
                    finishedAt = if (status == "done") base + id + 1200 else 0,
                    statusLabel = demoStatusLabel(status))
            }
            // Mirrors Harmony's seven-state presentation. Some sample orders intentionally share
            // a schedule to show each stage; they are scenarios, not seven newly submitted bookings.
            val fixtures = listOf(
                fixture(501, 41, 9, 3, mockDate(), "AM", 6, "booked"),
                fixture(502, 42, 9, 3, mockDate(), "PM", 2, "arrived"),
                fixture(503, 48, 15, 5, mockDate(1), "PM", 5, "waiting"),
                fixture(504, 41, 9, 3, mockDate(), "AM", 3, "visiting"),
                fixture(505, 42, 9, 3, mockDate(), "PM", 1, "done"),
                fixture(506, 48, 15, 5, mockDate(1), "PM", 4, "cancelled"),
                fixture(507, 41, 9, 3, mockDate(), "AM", 8, "no_show"))
            val first = fixtures.first()
            val token = session.bookingToken(first.scheduleId)
            check(session.markBookingCompleted(first.scheduleId, first.appointmentId, token)) {
                session.text(R.string.data_booking_response_mismatch)
            }
            mockAppointments += fixtures
            mockTokens[token] = first
            nextAppointmentId = 508L
            mockSeedIdentity = expected
        }
    }

    fun demoNotices(): List<PatientNotice> {
        check(BuildConfig.DEBUG && session.mockMode) { session.text(R.string.data_demo_debug_only) }
        return listOf(
            PatientNotice(1, session.text(R.string.demo_notice_visit_title), session.text(R.string.demo_notice_visit_body), "2026-10-08", session.text(R.string.demo_notice_visit_category)),
            PatientNotice(2, session.text(R.string.demo_notice_health_title), session.text(R.string.demo_notice_health_body), "2026-10-03", session.text(R.string.demo_notice_health_category)),
            PatientNotice(3, session.text(R.string.align_notice_records_title), session.text(R.string.align_notice_records_body), "2026-09-28", session.text(R.string.align_notice_records_category))
        )
    }

    fun notices(): List<PatientNotice> {
        if (session.mockMode) return demoNotices()
        val expected = identity()
        val rows = client.get("/api/v1/notices?limit=20").getJSONArray("items")
        return (0 until rows.length()).map { i ->
            val item = rows.getJSONObject(i)
            PatientNotice(item.getLong("id"), item.getString("title"), item.getString("body"),
                item.getString("date"), item.optString("category"))
        }.also { requireIdentity(expected) }
    }

    private fun demoStatusLabel(status: String) = session.text(when (status) {
        "booked" -> R.string.align_status_booked
        "arrived" -> R.string.align_status_arrived
        "waiting" -> R.string.align_status_waiting
        "visiting" -> R.string.align_status_visiting
        "done" -> R.string.align_status_done
        "cancelled" -> R.string.align_status_cancelled
        "no_show" -> R.string.align_status_no_show
        else -> R.string.align_status_unknown
    })

    /** A credential login always uses the real service; demo entry is an explicit separate action. */
    fun login(name: String, password: String): LoginResult {
        val d = client.post("/api/v1/auth/login", JSONObject().put("login_name", name).put("password", password))
        if (d.optString("role") != "patient") {
            throw ApiException(403, "FORBIDDEN_ROLE", session.text(R.string.data_patient_only))
        }
        return ContractParser.login(d)
    }

    fun enterDemo(): LoginResult {
        require(BuildConfig.DEBUG && session.mockMode) { session.text(R.string.data_demo_debug_only) }
        resetTransientState()
        val token = UUID.randomUUID().toString().replace("-", "") + UUID.randomUUID().toString().replace("-", "")
        return LoginResult(token, System.currentTimeMillis() / 1000 + 2_592_000,
            1, "patient", 7, session.text(R.string.data_demo_patient), 7)
    }

    fun me(): CurrentUser {
        val (expected, cachedName) = synchronized(session) { identity() to session.displayName }
        if (session.mockMode) return CurrentUser(session.userId, "patient", session.patientId, 0, session.deviceId,
            cachedName)
        val d = client.get("/api/v1/auth/me")
        val user = CurrentUser(d.getLong("user_id"), d.getString("role"), d.optLong("patient_id"),
            d.optLong("doctor_id"), d.optString("device_id"), d.optString("display_name", cachedName),
            d.optLong("expires_at"))
        synchronized(session) {
            requireIdentity(expected)
            if (user.role != "patient" || user.userId != session.userId || user.patientId != expected.patientId) {
                session.clearLoginIfCurrent(expected.token, expected.baseUrl)
                throw ApiException(403, "FORBIDDEN_ROLE", session.text(R.string.data_invalid_patient_identity))
            }
            if (!session.updateCurrentUserIfCurrent(user, expected.token, expected.baseUrl)) {
                throw ApiException(0, "SESSION_CHANGED", session.text(R.string.data_identity_changed))
            }
        }
        return user
    }

    fun logout() {
        val (expected, demo) = synchronized(session) { identity() to session.mockMode }
        try {
            if (!demo) client.postWithStatus("/api/v1/auth/logout", JSONObject(), expected.baseUrl, expected.token)
        } finally {
            // Match the demo operation lock order; an old logout must not clear a new identity.
            synchronized(this) {
                synchronized(session) {
                    if (identity() == expected) {
                        session.clearLoginIfCurrent(expected.token, expected.baseUrl)
                        resetTransientState()
                    }
                }
            }
        }
    }

    @Synchronized fun resetTransientState() {
        mockAppointments.clear(); mockTokens.clear(); previsitAssistantText.clear(); mockPrevisit = null; nextAppointmentId = 501L
        mockSeedIdentity = null
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
        return ContractParser.triage(d)
    }

    fun hospitalToday(): String {
        if (session.mockMode) return mockToday.toString()
        val today = client.get("/health").opt("today") as? String
            ?: throw ApiException(0, "INVALID_RESPONSE", session.text(R.string.data_hospital_date_invalid))
        return try { parseDate(today).toString() }
        catch (_: ApiException) { throw ApiException(0, "INVALID_RESPONSE", session.text(R.string.data_hospital_date_invalid)) }
    }

    fun schedules(date: String, departmentId: Long = 0, doctorId: Long = 0, period: String = ""): List<Schedule> {
        val requested = parseDate(date)
        require(departmentId >= 0 && doctorId >= 0 && period in setOf("", "AM", "PM")) {
            session.text(R.string.align_schedule_filter_invalid)
        }
        fun matches(schedule: Schedule) = schedule.workDate == requested.toString() &&
            (departmentId == 0L || schedule.departmentId == departmentId) &&
            (doctorId == 0L || schedule.doctorId == doctorId) && (period.isEmpty() || schedule.period == period)
        if (session.mockMode) return mockSchedules().filter(::matches)
        val expected = identity()
        val encoded = URLEncoder.encode(requested.toString(), "UTF-8")
        // Filter department before the server applies LIMIT; doctors and periods are local.
        val departmentQuery = if (departmentId > 0) "&department_id=$departmentId" else ""
        val a = client.get("/api/v1/schedules?work_date=$encoded$departmentQuery&limit=100").optJSONArray("schedules")
        // Patient sellability is decided by the server using the hospital's clock.
        return (0 until (a?.length() ?: 0)).map { i ->
            val o = a!!.getJSONObject(i)
            Schedule(o.getLong("id"), o.getLong("doctor_id"), o.getLong("department_id"), o.getString("work_date"),
                o.getString("period"), o.getInt("total_num"), o.getInt("remain_num"), o.getBoolean("enabled"),
                o.optString("department_name"), o.optString("doctor_name"), o.optString("doctor_title"))
        }.filter(::matches).also { requireIdentity(expected) }
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
    fun bookWithPrevisit(scheduleId: Long, previsitId: String): Appointment {
        val expected=identity()
        val pending=synchronized(session) { requireIdentity(expected);session.beginBooking(scheduleId,previsitId) }
        return try {
            bookForIdentity(scheduleId,pending.clientToken,expected,pending.previsitId).also {
                requireHandoff(it,pending)
                synchronized(session) {requireIdentity(expected);session.clearPending(scheduleId,pending.clientToken)}
            }
        } catch(e:ApiException) {
            if(e.status in listOf(400,404,409)) synchronized(session) {requireIdentity(expected);session.clearPending(scheduleId,pending.clientToken)}
            throw e
        }
    }
    /** A 404 only says no committed token owner was observed. Keep the same intent for retry. */
    fun confirmBooking(pending: PendingBooking): Appointment? {
        val expected=identity()
        if(session.mockMode) return synchronized(this) {
            ensureDemoInitialized(expected)
            mockTokens[pending.clientToken]?.takeIf {handoffComplete(it,pending)}?.also {
                synchronized(session) {requireIdentity(expected);session.clearPending(pending.scheduleId,pending.clientToken)}
            }
        }
        val found=try {ContractParser.appointment(client.get("/api/v1/appointments/by-token/${encodeSegment(pending.clientToken)}"))}
            catch(e:ApiException) {if(e.status==404 && e.code=="APPOINTMENT_NOT_FOUND") return null else throw e}
        synchronized(session) {
            requireIdentity(expected)
            if(found.patientId!=expected.patientId || found.scheduleId!=pending.scheduleId || found.status=="cancelled") {
                throw ApiException(0,"INVALID_RESPONSE",session.text(R.string.data_booking_response_mismatch))
            }
            if(!handoffComplete(found,pending)) return null
            if(!session.markBookingCompleted(pending.scheduleId,found.appointmentId,pending.clientToken)) {
                // Only POST is authoritative enough for the A -> B replacement handshake.
                return null
            }
            session.clearPending(pending.scheduleId,pending.clientToken)
        }
        return found.copy(replayed=true)
    }
    private fun handoffComplete(found:Appointment,pending:PendingBooking) = pending.previsitId.isBlank() ||
        (found.previsitBound && found.previsitId==pending.previsitId)
    private fun requireHandoff(found:Appointment,pending:PendingBooking) {
        if(!handoffComplete(found,pending)) throw ApiException(0,"BOOKING_HANDOFF_UNCONFIRMED",
            "预约已查到，但所选预问诊的交接尚未确认，请继续确认同一预约")
    }

    fun book(scheduleId: Long, clientToken: String): Appointment = bookForIdentity(scheduleId, clientToken, identity())

    private fun bookForIdentity(scheduleId: Long, clientToken: String, expected: Identity, previsitId: String = ""): Appointment {
        require(scheduleId > 0 && clientToken.isNotBlank() && clientToken.length <= 64) { session.text(R.string.data_booking_invalid) }
        synchronized(session) {
            requireIdentity(expected)
            if (session.bookingToken(scheduleId) != clientToken) {
                throw ApiException(0, "BOOKING_CHANGED", session.text(R.string.data_booking_response_mismatch))
            }
        }
        if (session.mockMode) return synchronized(this) {
            requireIdentity(expected)
            ensureDemoInitialized(expected)
            mockTokens[clientToken]?.let { existing ->
                if(previsitId.isNotBlank() && existing.previsitId!=previsitId) {
                    check(existing.previsitId.isBlank() && existing.status=="booked") {"本次预约不能替换预问诊单"}
                    val updated=existing.copy(previsitId=previsitId,previsitBound=true)
                    mockTokens[clientToken]=updated
                    val index=mockAppointments.indexOfFirst {it.appointmentId==existing.appointmentId}
                    if(index>=0) mockAppointments[index]=updated
                    mockPrevisit=mockPrevisit?.copy(appointmentId=existing.appointmentId)
                    return@synchronized updated.copy(replayed=true)
                }
                return@synchronized existing.copy(replayed=true)
            }
            if (mockAppointments.any { it.scheduleId == scheduleId && occupiesSchedule(it.status) }) {
                throw ApiException(409, "APPOINTMENT_ALREADY_EXISTS", session.text(R.string.align_schedule_already_booked))
            }
            val s = mockSchedules().firstOrNull { it.id == scheduleId }
                ?: throw ApiException(404, "SCHEDULE_NOT_FOUND", session.text(R.string.data_schedule_missing))
            if (s.remainNum <= 0) throw ApiException(409, "SLOT_GONE", session.text(R.string.data_schedule_full))
            val seq = (mockAppointments.filter { it.scheduleId == scheduleId }.maxOfOrNull { it.seqNo } ?: 0) + 1
            val result = Appointment(nextAppointmentId++, s.id, session.patientId, s.doctorId, s.departmentId,
                s.workDate, s.period, seq, "booked", departmentName = s.departmentName,
                doctorName = s.doctorName, doctorTitle = s.doctorTitle,
                previsitId = previsitId, previsitBound = previsitId.isNotBlank(),
                createdAt = mockToday.atStartOfDay().toEpochSecond(ZoneOffset.ofHours(8)) + 8 * 3600,
                statusLabel = demoStatusLabel("booked"))
            if(previsitId.isNotBlank()) mockPrevisit=mockPrevisit?.copy(appointmentId=result.appointmentId)
            mockTokens[clientToken] = result; mockAppointments += result
            synchronized(session) {
                requireIdentity(expected)
                if (!session.markBookingCompleted(scheduleId, result.appointmentId, clientToken)) {
                    throw ApiException(0, "BOOKING_CHANGED", session.text(R.string.data_booking_response_mismatch))
                }
            }
            result
        }
        val knownId = synchronized(session) { requireIdentity(expected); session.completedBookingId(scheduleId) }
        val (status, d) = client.postWithStatus("/api/v1/appointments", JSONObject().put("schedule_id", scheduleId)
            .put("client_token", clientToken).put("previsit_id",previsitId), expected.baseUrl, expected.token)
        val result = parseAppointment(d).let { it.copy(replayed = status == 200 || knownId == it.appointmentId) }
        if (result.patientId != expected.patientId || result.scheduleId != scheduleId) {
            throw ApiException(0, "INVALID_RESPONSE", session.text(R.string.data_booking_response_mismatch))
        }
        // Keep the original token after success too: retries/re-entry must identify the same order.
        synchronized(session) {
            requireIdentity(expected)
            val accepted = session.markBookingCompleted(scheduleId, result.appointmentId, clientToken) ||
                ((status == 200 || status == 201) && knownId != null && knownId != result.appointmentId &&
                    result.status != "cancelled" && session.markBookingReplacementIfCurrent(
                        scheduleId, result.appointmentId, clientToken, knownId))
            if (!accepted) {
                throw ApiException(0, "BOOKING_CHANGED", session.text(R.string.data_booking_response_mismatch))
            }
        }
        return result
    }

    fun appointments(includeCancelled: Boolean): List<Appointment> {
        if (session.mockMode) return synchronized(this) {
            ensureDemoInitialized()
            mockAppointments.filter { includeCancelled || it.status != "cancelled" }
        }
        // Even the active-only UI must learn explicit cancellations so completed IDs recover.
        val expected = identity()
        val history = loadAppointments(expected)
        // Preserve the backend's active-only LIMIT scope: 200 recent cancellations must not
        // hide older active bookings by filtering a capped history list on the client.
        return if (includeCancelled) history else loadAppointments(expected, includeCancelled = false)
    }

    private fun loadAppointments(expected: Identity, includeCancelled: Boolean = true): List<Appointment> {
        val a = client.get("/api/v1/appointments?include_cancelled=$includeCancelled&limit=200").optJSONArray("appointments")
        val items = (0 until (a?.length() ?: 0)).map { parseAppointment(a!!.getJSONObject(it)) }
        if (items.any { it.patientId != expected.patientId || it.appointmentId <= 0 || it.scheduleId <= 0 }) {
            throw ApiException(0, "INVALID_RESPONSE", session.text(R.string.data_booking_response_mismatch))
        }
        synchronized(session) {
            requireIdentity(expected)
            items.filter { it.status == "cancelled" }.forEach {
                // Compare-and-retire A plus its tombstone; never clear a newer completed B.
                session.clearBookingIfCompleted(it.scheduleId, it.appointmentId)
            }
        }
        return items
    }

    fun cancel(id: Long): Appointment {
        if (session.mockMode) return synchronized(this) {
            ensureDemoInitialized()
            val index = mockAppointments.indexOfFirst { it.appointmentId == id }
            if (index < 0) throw ApiException(404, "APPOINTMENT_NOT_FOUND", session.text(R.string.data_appointment_not_found))
            val old = mockAppointments[index]
            if (old.status != "booked") throw ApiException(409, "APPOINTMENT_NOT_CANCELLABLE", session.text(R.string.data_cancellation_invalid_state))
            val result = old.copy(status = "cancelled", slotRestored = true, statusLabel = demoStatusLabel("cancelled"))
            mockAppointments[index] = result
            mockTokens.entries.removeIf { it.value.appointmentId == id }
            session.clearBookingIfCompleted(old.scheduleId, id)
            result
        }
        val expected = identity()
        return parseAppointment(client.post("/api/v1/appointments/$id/cancel", JSONObject())).also {
            if (it.patientId != expected.patientId || it.appointmentId != id) {
                throw ApiException(0, "INVALID_RESPONSE", session.text(R.string.data_cancellation_response_mismatch))
            }
            synchronized(session) {
                requireIdentity(expected)
                if (it.status == "cancelled") session.clearBookingIfCompleted(it.scheduleId, id)
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
        return ContractParser.previsit(o).copy(assistantText=previsitAssistantText[o.getString("session_id")].orEmpty())
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

    private fun parseAppointment(o: JSONObject) = ContractParser.appointment(o)

    private fun encodeSegment(value: String) = URLEncoder.encode(value, "UTF-8").replace("+", "%20")
}
