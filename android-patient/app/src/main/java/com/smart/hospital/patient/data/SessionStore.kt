package com.smart.hospital.patient.data

import com.smart.hospital.patient.R
import android.content.Context
import com.smart.hospital.patient.BuildConfig
import com.smart.hospital.patient.model.LoginResult
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

    fun isLoggedIn(): Boolean = token.length == 64 && expiresAt > System.currentTimeMillis() / 1000 &&
        role == "patient" && patientId > 0

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

    @Synchronized fun markBookingCompleted(scheduleId: Long, appointmentId: Long) {
        require(appointmentId > 0)
        if (mockMode) demoCompletedBookings[scheduleId] = appointmentId
        else prefs.edit().putLong("booking_completed_${bookingNamespace(scheduleId)}", appointmentId).commit()
    }

    @Synchronized fun clearBooking(scheduleId: Long) {
        if (mockMode) {
            demoBookingTokens.remove(scheduleId)
            demoCompletedBookings.remove(scheduleId)
        } else {
            val namespace = bookingNamespace(scheduleId)
            prefs.edit().remove("booking_token_$namespace").remove("booking_completed_$namespace").commit()
        }
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
