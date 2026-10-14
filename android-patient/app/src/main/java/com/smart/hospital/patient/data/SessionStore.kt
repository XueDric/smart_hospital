package com.smart.hospital.patient.data

import com.smart.hospital.patient.R
import android.content.Context
import com.smart.hospital.patient.BuildConfig
import com.smart.hospital.patient.model.LoginResult
import com.smart.hospital.patient.model.CurrentUser
import java.net.URI
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID

/** Passwords and demonstration identities are never persisted. */
class SessionStore(context: Context) {
    private val appContext = context.applicationContext
    internal fun text(resourceId: Int, vararg arguments: Any): String = appContext.getString(resourceId, *arguments)
    private val prefs = context.getSharedPreferences("patient_session", Context.MODE_PRIVATE)
    private var demoMode = false
    private var demoLogin: LoginResult? = null
    private var demoPrevisitId = ""
    private val demoBookingTokens = mutableMapOf<Long, String>()
    private val demoCompletedBookings = mutableMapOf<Long, Long>()
    private val demoCancelledBookings = mutableMapOf<Long, MutableSet<Long>>()

    init {
        // Remove identities created by the former persisted demonstration mode.
        if (prefs.getBoolean("mock_mode", false)) clearLogin()
        prefs.edit().remove("mock_mode").apply()
        val savedUrl = prefs.getString("base_url", null)
        if (savedUrl != null && runCatching { validateBaseUrl(savedUrl) }.isFailure) {
            clearLogin()
            prefs.edit().remove("base_url").apply()
        }
    }

    val deviceId: String
        get() = prefs.getString("device_id", null) ?: UUID.randomUUID().toString().also {
            prefs.edit().putString("device_id", it).apply()
        }
    var lastLoginName: String
        get() = prefs.getString("last_login_name", "").orEmpty()
        set(value) { prefs.edit().putString("last_login_name", value.trim()).apply() }
    var baseUrl: String
        get() = validateBaseUrl(prefs.getString("base_url", BuildConfig.DEFAULT_BASE_URL).orEmpty())
        set(value) {
            synchronized(this) {
                val normalized = validateBaseUrl(value)
                if (normalized != baseUrl) clearLogin()
                prefs.edit().putString("base_url", normalized).apply()
            }
        }
    var mockMode: Boolean
        get() = BuildConfig.DEBUG && demoMode
        set(value) { switchMode(value) }

    @Synchronized fun switchMode(enabled: Boolean) {
        require(!enabled || BuildConfig.DEBUG) { text(R.string.data_demo_unavailable) }
        if (demoMode != enabled) {
            clearLogin()
            demoMode = enabled
        }
    }

    val token: String get() = if (mockMode) demoLogin?.token.orEmpty() else prefs.getString("token", "").orEmpty()
    val expiresAt: Long get() = if (mockMode) demoLogin?.expiresAt ?: 0 else prefs.getLong("expires_at", 0)
    val userId: Long get() = if (mockMode) demoLogin?.userId ?: 0 else prefs.getLong("user_id", 0)
    val role: String get() = if (mockMode) demoLogin?.role.orEmpty() else prefs.getString("role", "").orEmpty()
    val refId: Long get() = if (mockMode) demoLogin?.refId ?: 0 else prefs.getLong("ref_id", 0)
    val patientId: Long get() = if (mockMode) demoLogin?.patientId ?: 0 else prefs.getLong("patient_id", 0)
    val displayName: String get() = if (mockMode) demoLogin?.displayName.orEmpty() else prefs.getString("display_name", "").orEmpty()
    val previsitSessionId: String get() = if (mockMode) demoPrevisitId else prefs.getString("previsit_session_id", "").orEmpty()

    @Synchronized fun isLoggedIn(): Boolean = token.length == 64 && role == "patient" && patientId > 0 &&
        (!mockMode || expiresAt > System.currentTimeMillis() / 1000)

    // Cached expiry is a server snapshot: the server renews it on authenticated requests.
    // Only an authoritative rejection may discard an otherwise valid persisted online identity.
    @Synchronized fun updateCurrentUserIfCurrent(user: CurrentUser, requestedToken: String,
                                                requestedBaseUrl: String): Boolean {
        if (token != requestedToken || baseUrl != requestedBaseUrl || user.role != "patient" ||
            user.userId != userId || user.patientId != patientId) return false
        if (mockMode) demoLogin = demoLogin?.copy(displayName = user.displayName)
        else {
            val editor = prefs.edit().putString("display_name", user.displayName)
            // Older servers omit this field; zero also represents development header auth.
            if (user.expiresAt > 0) editor.putLong("expires_at", user.expiresAt)
            editor.apply()
        }
        return true
    }

    @Synchronized fun saveLogin(result: LoginResult) {
        require(result.token.length == 64) { text(R.string.data_invalid_token) }
        require(result.expiresAt > System.currentTimeMillis() / 1000 && result.userId > 0 &&
            result.refId > 0 && result.role == "patient" && result.patientId > 0) { text(R.string.data_invalid_patient_identity) }
        if (mockMode) {
            demoLogin = result
            return
        }
        if (patientId != result.patientId || userId != result.userId) clearPrevisitSession()
        prefs.edit().putString("token", result.token).putLong("expires_at", result.expiresAt)
            .putLong("user_id", result.userId).putString("role", result.role).putLong("ref_id", result.refId)
            .putLong("patient_id", result.patientId).putString("display_name", result.displayName).apply()
    }

    @Synchronized fun setPrevisitSession(id: String) {
        if (mockMode) demoPrevisitId = id
        else prefs.edit().putString("previsit_session_id", id).apply()
    }
    fun clearPrevisitSession() = setPrevisitSession("")

    @Synchronized fun clearLogin() {
        demoMode = false
        demoLogin = null
        demoPrevisitId = ""
        demoBookingTokens.clear()
        demoCompletedBookings.clear()
        demoCancelledBookings.clear()
        prefs.edit().remove("token").remove("expires_at").remove("user_id").remove("role")
            .remove("ref_id").remove("patient_id").remove("display_name")
            .remove("previsit_session_id").remove("mock_mode").apply()
        // Online keys survive logout/401: an uncertain request must keep its idempotency key.
    }

    @Synchronized fun clearLoginIfCurrent(requestedToken: String, requestedBaseUrl: String) {
        if (token == requestedToken && baseUrl == requestedBaseUrl) clearLogin()
    }

    @Synchronized fun setPrevisitSessionIfCurrent(id: String, requestedToken: String, requestedBaseUrl: String) {
        if (token == requestedToken && baseUrl == requestedBaseUrl) setPrevisitSession(id)
    }

    @Synchronized fun bookingToken(scheduleId: Long): String {
        require(scheduleId > 0 && patientId > 0) { text(R.string.data_login_and_select_schedule) }
        if (mockMode) return demoBookingTokens.getOrPut(scheduleId) { newBookingToken() }
        val key = "booking_token_${bookingNamespace(scheduleId)}"
        val token = prefs.getString(key, null) ?: newBookingToken()
        // A failed commit may already have changed the preferences' in-memory value.
        // Confirm durable storage on every attempt, including a reused in-memory key.
        check(prefs.edit().putString(key, token).commit()) { text(R.string.data_booking_storage_failed) }
        return token
    }

    @Synchronized fun completedBookingId(scheduleId: Long): Long? {
        if (mockMode) return demoCompletedBookings[scheduleId]
        return prefs.getLong("booking_completed_${bookingNamespace(scheduleId)}", 0).takeIf { it > 0 }
    }

    @Synchronized fun markBookingCompleted(scheduleId: Long, appointmentId: Long, clientToken: String): Boolean {
        require(appointmentId > 0)
        val namespace = bookingNamespace(scheduleId)
        val currentToken = if (mockMode) demoBookingTokens[scheduleId] else prefs.getString("booking_token_$namespace", null)
        val completed = completedBookingId(scheduleId)
        val cancelled = if (mockMode) demoCancelledBookings[scheduleId]?.contains(appointmentId) == true
            else prefs.getStringSet("booking_cancelled_$namespace", emptySet()).orEmpty().contains(appointmentId.toString())
        // A cancelled request can finish after a new booking. It must not replace the newer ID.
        if (cancelled || currentToken != clientToken || (completed != null && completed != appointmentId)) return false
        if (mockMode) demoCompletedBookings[scheduleId] = appointmentId
        else check(prefs.edit().putLong("booking_completed_$namespace", appointmentId).commit()) {
            text(R.string.data_booking_storage_failed)
        }
        return true
    }

    /** Only a successful POST bound to this same token may establish the A -> B handoff. */
    @Synchronized fun markBookingReplacementIfCurrent(scheduleId: Long, appointmentId: Long,
                                                     clientToken: String, expectedCompletedId: Long): Boolean {
        require(scheduleId > 0 && appointmentId > 0 && expectedCompletedId > 0 && appointmentId != expectedCompletedId)
        val namespace = bookingNamespace(scheduleId)
        val currentToken = if (mockMode) demoBookingTokens[scheduleId] else prefs.getString("booking_token_$namespace", null)
        val completed = completedBookingId(scheduleId)
        val cancelled = if (mockMode) demoCancelledBookings[scheduleId].orEmpty().map { it.toString() }.toMutableSet()
            else prefs.getStringSet("booking_cancelled_$namespace", emptySet()).orEmpty().toMutableSet()
        if (currentToken != clientToken || cancelled.contains(appointmentId.toString())) return false
        if (completed != expectedCompletedId &&
            !(completed == null && cancelled.contains(expectedCompletedId.toString()))) return false
        // The backend's unique (patient, token) binding and cancellation's NULL release mean
        // a successful same-token POST returning B proves A no longer owns that token.
        // Tombstone A and accept B in ONE CAS/commit; late A cannot replace B, nor B replace C.
        cancelled.add(expectedCompletedId.toString())
        if (mockMode) {
            demoCancelledBookings.getOrPut(scheduleId) { mutableSetOf() }.add(expectedCompletedId)
            demoCompletedBookings[scheduleId] = appointmentId
        } else check(prefs.edit().putStringSet("booking_cancelled_$namespace", cancelled)
            .putLong("booking_completed_$namespace", appointmentId).commit()) {
            text(R.string.data_booking_storage_failed)
        }
        return true
    }

    @Synchronized fun clearBookingIfCompleted(scheduleId: Long, appointmentId: Long): Boolean {
        require(scheduleId > 0 && appointmentId > 0)
        // Compare and removal share the same monitor as token creation and completion writes.
        // Cancelling another device's order for this schedule must preserve our retry token.
        // Keep our token even when A is retired: the server releases it on cancellation,
        // and a concurrent/uncertain POST may already have created B with that same token.
        // Rotating here would let the next retry create a second order instead of replaying B.
        val matchesCompleted = completedBookingId(scheduleId) == appointmentId
        if (mockMode) {
            demoCancelledBookings.getOrPut(scheduleId) { mutableSetOf() }.add(appointmentId)
            if (matchesCompleted) {
                demoCompletedBookings.remove(scheduleId)
            }
        } else {
            val namespace = bookingNamespace(scheduleId)
            // Even an unobserved booking response may arrive after its confirmed cancellation.
            // Record that ID without deleting an unrelated pending/completed booking's key.
            val cancelledKey = "booking_cancelled_$namespace"
            val cancelled = prefs.getStringSet(cancelledKey, emptySet()).orEmpty().toMutableSet()
            if (!matchesCompleted && cancelled.contains(appointmentId.toString())) return false
            cancelled.add(appointmentId.toString())
            val editor = prefs.edit().putStringSet(cancelledKey, cancelled)
            if (matchesCompleted) editor.remove("booking_completed_$namespace")
            check(editor.commit()) {
                text(R.string.data_booking_storage_failed)
            }
        }
        return matchesCompleted
    }

    private fun newBookingToken() = UUID.randomUUID().toString().replace("-", "")
    private fun bookingNamespace(scheduleId: Long): String = MessageDigest.getInstance("SHA-256")
        .digest("$baseUrl|$patientId|$scheduleId".toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    fun validateBaseUrl(value: String): String {
        val uri = runCatching { URI(value.trim()) }.getOrElse { throw IllegalArgumentException(text(R.string.data_invalid_service_address)) }
        val scheme = uri.scheme?.lowercase(Locale.ROOT)
        require(scheme == "http" || scheme == "https") { text(R.string.data_service_scheme) }
        require(BuildConfig.DEBUG || scheme == "https") { text(R.string.data_release_https) }
        require(!uri.host.isNullOrBlank() && uri.userInfo == null && uri.rawQuery == null && uri.rawFragment == null &&
            (uri.port == -1 || uri.port in 1..65535)) { text(R.string.data_service_components) }
        require(uri.rawPath.isNullOrBlank() || uri.rawPath == "/") { text(R.string.data_service_root) }
        val port = if ((scheme == "http" && uri.port == 80) || (scheme == "https" && uri.port == 443)) -1 else uri.port
        return URI(scheme, null, uri.host.lowercase(Locale.ROOT), port, null, null, null).toASCIIString()
    }
}
