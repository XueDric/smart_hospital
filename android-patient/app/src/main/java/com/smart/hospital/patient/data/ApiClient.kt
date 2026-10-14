package com.smart.hospital.patient.data

import com.smart.hospital.patient.R
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.ConcurrentHashMap

class ApiException(val status: Int, val code: String, override val message: String,
                   val retryAfterSeconds: Int = 0) : Exception(message)

data class PrevisitStreamResult(
    val sessionId: String,
    val text: String,
    val nextSlot: String,
    val turn: Int,
    val totalSlots: Int
)

class ApiClient(private val session: SessionStore) {
    companion object {
        // Shared across clients; changing accounts cannot bypass a server's cooldown.
        private val cooldowns = ConcurrentHashMap<String, Long>()
    }

    fun remainingCooldownSeconds() = cooldownSeconds(session.baseUrl)
    private fun cooldownSeconds(baseUrl: String): Int {
        val remaining = (cooldowns[baseUrl] ?: 0L) - System.currentTimeMillis()
        return if (remaining <= 0) 0 else ((remaining + 999) / 1000).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    }
    fun isCoolingDown() = remainingCooldownSeconds() > 0

    private fun ensureNotCoolingDown(baseUrl: String) {
        val seconds = cooldownSeconds(baseUrl)
        if (seconds > 0) throw ApiException(429, "AUTH_RATE_LIMITED", session.text(R.string.data_rate_limited, seconds), seconds)
    }

    private fun retrySeconds(header: String?): Int {
        val raw = header?.trim().orEmpty()
        val seconds = raw.toLongOrNull() ?: runCatching {
            val until = ZonedDateTime.parse(raw, DateTimeFormatter.RFC_1123_DATE_TIME).toInstant().toEpochMilli()
            ((until - System.currentTimeMillis()).coerceAtLeast(0) + 999) / 1000
        }.getOrDefault(30L)
        return seconds.coerceIn(1L, Int.MAX_VALUE.toLong()).toInt()
    }

    private fun rateLimited(baseUrl: String, connection: HttpURLConnection, code: String): ApiException {
        val seconds = retrySeconds(connection.getHeaderField("Retry-After"))
        val deadline = System.currentTimeMillis() + seconds * 1000L
        cooldowns.compute(baseUrl) { _, previous -> maxOf(previous ?: 0L, deadline) }
        return ApiException(429, code.ifBlank { "AUTH_RATE_LIMITED" }, session.text(R.string.data_rate_limited, seconds), seconds)
    }

    private fun connection(baseUrl: String, token: String, path: String, method: String, accept: String): HttpURLConnection {
        var created: HttpURLConnection? = null
        return try {
            val connection = URL(baseUrl + if (path.startsWith("/")) path else "/$path").openConnection() as HttpURLConnection
            created = connection
            connection.apply {
                requestMethod = method
                connectTimeout = 15_000
                // Triage includes bounded server AI enrichment and rule fallback.
                readTimeout = if (path == "/api/v1/triage") 45_000 else 15_000
                instanceFollowRedirects = false
                setRequestProperty("Accept", accept)
                setRequestProperty("X-Device-Id", session.deviceId)
                setRequestProperty("X-Device-Name", "Android patient")
                if (token.isNotBlank()) setRequestProperty("Authorization", "Bearer $token")
            }
        } catch (e: Exception) {
            created?.disconnect()
            throw ApiException(0, "NETWORK", session.text(R.string.data_network_failed))
        }
    }

    private fun readJson(connection: HttpURLConnection, status: Int): JSONObject {
        val stream = if (status in 200..299) connection.inputStream else connection.errorStream
        val text = stream?.bufferedReader(StandardCharsets.UTF_8)?.use { it.readText() }.orEmpty()
        return runCatching { JSONObject(text) }.getOrDefault(JSONObject())
    }

    private fun handleAuth(error: ApiException, requestedToken: String, baseUrl: String, path: String) {
        val identityEndpoint = path == "/api/v1/auth/me" || path == "/api/v1/auth/login"
        if (error.status == 401 || (identityEndpoint && error.status == 403 && error.code == "FORBIDDEN_ROLE")) {
            session.clearLoginIfCurrent(requestedToken, baseUrl)
        }
    }

    private fun ensureCurrent(requestedToken: String, baseUrl: String) {
        if (session.token != requestedToken || session.baseUrl != baseUrl || session.mockMode) {
            throw ApiException(0, "SESSION_CHANGED", session.text(R.string.data_session_changed))
        }
    }

    private fun request(method: String, path: String, body: JSONObject? = null,
                        requestedBaseUrl: String? = null, requestedToken: String? = null): Pair<Int, JSONObject> {
        val (baseUrl, token) = synchronized(session) {
            val capturedBase = session.validateBaseUrl(requestedBaseUrl ?: session.baseUrl)
            val capturedToken = requestedToken ?: session.token
            ensureCurrent(capturedToken, capturedBase)
            capturedBase to capturedToken
        }
        ensureNotCoolingDown(baseUrl)
        val connection = connection(baseUrl, token, path, method, "application/json")
        return try {
            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                connection.outputStream.use { it.write(body.toString().toByteArray(StandardCharsets.UTF_8)) }
            }
            val status = connection.responseCode
            val json = readJson(connection, status)
            if (status == 429) throw rateLimited(baseUrl, connection, json.optJSONObject("error")?.optString("code").orEmpty())
            if (status !in 200..299 || (json.has("ok") && !json.optBoolean("ok"))) {
                throw toException(status, json, path).also { handleAuth(it, token, baseUrl, path) }
            }
            ensureCurrent(token, baseUrl)
            if (path == "/health") status to json
            else if (json.optBoolean("ok") && json.optJSONObject("data") != null) status to json.getJSONObject("data")
            else throw ApiException(status, "INVALID_RESPONSE", session.text(R.string.data_invalid_response))
        } catch (e: ApiException) { throw e }
        catch (e: Exception) { throw ApiException(0, "NETWORK", session.text(R.string.data_network_failed)) }
        finally { connection.disconnect() }
    }

    private fun toException(status: Int, json: JSONObject, path: String): ApiException {
        val code = json.optJSONObject("error")?.optString("code").orEmpty().ifBlank { "HTTP_$status" }
        val message = when {
            status >= 500 -> session.text(R.string.data_service_unavailable)
            code == "AUTH_BAD_CREDENTIALS" -> session.text(R.string.data_bad_credentials)
            status == 401 -> session.text(R.string.data_session_expired)
            code == "FORBIDDEN_ROLE" && (path == "/api/v1/auth/me" || path == "/api/v1/auth/login") -> session.text(R.string.data_patient_only)
            code == "SLOT_GONE" -> session.text(R.string.data_schedule_sold_out)
            code == "SCHEDULE_NOT_FOUND" -> session.text(R.string.data_schedule_unavailable)
            code == "APPOINTMENT_NOT_FOUND" -> session.text(R.string.data_appointment_missing)
            code == "APPOINTMENT_NOT_CANCELLABLE" -> session.text(R.string.data_cancellation_unavailable)
            code == "PREVISIT_NOT_FOUND" -> session.text(R.string.data_previsit_expired)
            code == "PREVISIT_COMPLETE" -> session.text(R.string.data_previsit_complete)
            code == "EMR_NOT_FOUND" -> session.text(R.string.data_record_missing)
            code == "VALIDATION_FAILED" -> session.text(R.string.data_invalid_input)
            status == 403 -> session.text(R.string.data_forbidden)
            status == 404 -> session.text(R.string.data_not_found)
            status == 409 -> session.text(R.string.data_conflict)
            status in 300..399 -> session.text(R.string.data_service_redirect)
            else -> session.text(R.string.data_request_failed)
        }
        return ApiException(status, code, message)
    }

    fun get(path: String) = request("GET", path).second
    fun post(path: String, body: JSONObject) = request("POST", path, body).second
    fun postWithStatus(path: String, body: JSONObject) = request("POST", path, body)
    fun postWithStatus(path: String, body: JSONObject, requestedBaseUrl: String, requestedToken: String) =
        request("POST", path, body, requestedBaseUrl, requestedToken)

    /** A meta id is resumable, but only an explicit done frame makes the stream successful. */
    fun openPrevisitStream(): PrevisitStreamResult {
        val (baseUrl, token) = synchronized(session) { session.validateBaseUrl(session.baseUrl) to session.token }
        ensureNotCoolingDown(baseUrl)
        val path = "/api/v1/previsit/stream"
        val connection = connection(baseUrl, token, path, "GET", "text/event-stream")
        return try {
            connection.readTimeout = 60_000
            // The shared backend creates the session here; the real chief is submitted as JSON.
            val status = connection.responseCode
            if (status !in 200..299) {
                val json = readJson(connection, status)
                if (status == 429) throw rateLimited(baseUrl, connection, json.optJSONObject("error")?.optString("code").orEmpty())
                throw toException(status, json, path).also { handleAuth(it, token, baseUrl, path) }
            }
            if (!connection.contentType.orEmpty().substringBefore(';').trim().equals("text/event-stream", true)) {
                throw ApiException(status, "INVALID_RESPONSE", session.text(R.string.data_previsit_invalid_response))
            }
            var sessionId = ""
            var sawDone = false
            var nextSlot = ""
            var turn = 0
            var totalSlots = 0
            val dialogue = StringBuilder()
            val dataLines = mutableListOf<String>()
            var frameType = ""
            fun consumeFrame() {
                if (dataLines.isEmpty()) { frameType = ""; return }
                val raw = dataLines.joinToString("\n")
                dataLines.clear()
                val event = runCatching { JSONObject(raw) }.getOrElse {
                    throw ApiException(0, "PREVISIT_STREAM_INVALID", session.text(R.string.data_previsit_invalid_stream))
                }
                val kind = event.optString("event").ifBlank { frameType }
                frameType = ""
                val data = event.optJSONObject("data") ?: event
                if (kind == "error" || (event.has("ok") && !event.optBoolean("ok"))) {
                    val envelope = if (event.has("error")) event else if (data.has("error")) data
                        else JSONObject().put("error", data)
                    val code = envelope.optJSONObject("error")?.optString("code").orEmpty()
                    val errorStatus = data.optInt("status", when {
                        code == "AUTH_RATE_LIMITED" -> 429
                        code.startsWith("AUTH_") -> 401
                        code == "FORBIDDEN_ROLE" -> 403
                        code == "PREVISIT_NOT_FOUND" -> 404
                        else -> 500
                    })
                    if (errorStatus == 429) throw rateLimited(baseUrl, connection, code)
                    throw toException(errorStatus, envelope, path).also { handleAuth(it, token, baseUrl, path) }
                }
                when (kind) {
                    "meta", "done" -> {
                        val id = data.optString("session_id").ifBlank { sessionId }
                        if (id.isBlank() || (sessionId.isNotBlank() && sessionId != id)) {
                            throw ApiException(0, "PREVISIT_STREAM_INVALID", session.text(R.string.data_previsit_invalid_session))
                        }
                        sessionId = id
                        session.setPrevisitSessionIfCurrent(id, token, baseUrl)
                        turn = data.optInt("turn", turn)
                        totalSlots = data.optInt("total_slots", totalSlots)
                        if (kind == "done") { nextSlot = data.optString("next_slot"); sawDone = true }
                    }
                    "delta" -> {
                        val text = data.optString("text")
                        if (dialogue.length + text.length > 64_000) {
                            throw ApiException(0, "PREVISIT_STREAM_INVALID", session.text(R.string.data_previsit_response_too_long))
                        }
                        if (dialogue.isNotEmpty()) dialogue.append('\n')
                        dialogue.append(text)
                    }
                }
            }
            connection.inputStream.bufferedReader(StandardCharsets.UTF_8).use { reader ->
                while (!sawDone) {
                    val line = reader.readLine() ?: break
                    when {
                        line.isEmpty() -> consumeFrame()
                        line.startsWith("data:") -> dataLines.add(line.substring(5).removePrefix(" "))
                        line.startsWith("event:") -> frameType = line.substring(6).trim()
                    }
                }
                if (!sawDone && dataLines.isNotEmpty()) consumeFrame()
            }
            if (!sawDone || sessionId.isBlank()) throw ApiException(0, "PREVISIT_STREAM_INCOMPLETE", session.text(R.string.data_previsit_incomplete_stream))
            ensureCurrent(token, baseUrl)
            PrevisitStreamResult(sessionId, dialogue.toString(), nextSlot, turn, totalSlots)
        } catch (e: ApiException) { throw e }
        catch (e: Exception) { throw ApiException(0, "NETWORK", session.text(R.string.data_previsit_network_failed)) }
        finally { connection.disconnect() }
    }
}
