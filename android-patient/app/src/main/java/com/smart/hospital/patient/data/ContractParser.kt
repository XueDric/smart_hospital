package com.smart.hospital.patient.data

import com.smart.hospital.patient.model.*
import org.json.JSONArray
import org.json.JSONObject

/** Shared network parser: required identifiers never quietly become 0. */
object ContractParser {
    fun triage(o: JSONObject): TriageResult {
        val red=o.getBoolean("red_flag")
        val a=o.optJSONArray("options")
        val options=if(red) emptyList() else (0 until (a?.length() ?: 0)).map {i->val v=a!!.getJSONObject(i)
            TriageOption(v.getLong("department_id"),v.optString("department_name"),v.getLong("doctor_id"),v.optString("doctor_name"),
                v.optString("doctor_title"),v.getLong("schedule_id"),v.getString("work_date"),v.getString("period"),v.getInt("remain_num"),v.optInt("total_remain"))}
        return TriageResult(red,o.getString("reason_code"),o.getString("source"),o.optString("patient_note"),o.optBoolean("truncated"),
            o.optString("ai_note"),o.optString("ai_reason"),options,o.optString("_request_id"))
    }
    fun login(o: JSONObject): LoginResult {
        val role = o.getString("role")
        return LoginResult(o.getString("token"),o.getLong("expires_at"),o.getLong("user_id"),role,
            o.getLong("ref_id"),o.optString("display_name"),if (role == "patient") o.getLong("patient_id") else 0,
            if (role == "doctor") o.optLong("doctor_id",o.getLong("ref_id")) else 0)
    }
    fun appointment(o: JSONObject) = Appointment(o.getLong("appointment_id"),o.optLong("schedule_id"),
        o.getLong("patient_id"),o.getLong("doctor_id"),o.getLong("department_id"),o.getString("visit_date"),
        o.getString("period"),o.getInt("seq_no"),o.optString("visit_status").takeIf { it.isNotBlank() } ?: o.getString("status"),o.optBoolean("slot_restored"),
        o.optString("warning"),departmentName=o.optString("department_name"),doctorName=o.optString("doctor_name"),
        doctorTitle=o.optString("doctor_title"),previsitId=o.optString("previsit_id"),previsitBound=o.optBoolean("previsit_bound"),
        createdAt=o.optLong("created_at"),arrivedAt=o.optLong("arrived_at"),waitingAt=o.optLong("waiting_at"),
        startedAt=o.optLong("started_at"),finishedAt=o.optLong("finished_at"),requestId=o.optString("_request_id"),
        statusLabel=o.optString("status_label"))
    fun previsit(o: JSONObject): PrevisitSession {
        val form = o.optJSONObject("form")
        return PrevisitSession(o.getString("session_id"),o.getInt("turn"),o.getInt("filled"),o.getInt("total_slots"),
            o.getBoolean("complete"),o.optString("next_slot"),o.optString("next_question"),
            form?.keys()?.asSequence()?.associateWith { form.getString(it) }.orEmpty(),
            appointmentId=o.optLong("appointment_id"),requestId=o.optString("_request_id"))
    }
    fun sections(a: JSONArray?) = (0 until (a?.length() ?: 0)).map { i ->
        val o=a!!.getJSONObject(i)
        DoctorSection(o.getString("key"),o.getString("label"),o.getString("value"),
            o.optInt("max_len",4000),o.optBoolean("required_to_lock"))
    }
    fun record(o: JSONObject): DoctorRecord {
        val ref=o.optJSONObject("previsit_ref") ?: JSONObject()
        val source=ref.optJSONArray("sections")
        val missing=o.optJSONArray("missing_required")
        // Missing or coerced versions must never turn an incompatible response into a writable v0.
        val rawVersion=o.get("version")
        val version=when(rawVersion) {
            is Int -> rawVersion.toLong()
            is Long -> rawVersion
            else -> throw org.json.JSONException("病历 version 必须是非负整数")
        }
        if(version<0) throw org.json.JSONException("病历 version 必须是非负整数")
        return DoctorRecord(o.getLong("appointment_id"),o.getBoolean("locked"),version,o.getLong("updated_at"),
            sections(o.getJSONArray("sections")),(0 until (missing?.length() ?: 0)).map { missing!!.getString(it) },
            (0 until (source?.length() ?: 0)).map { source!!.getString(it) }.toSet(),ref.optString("session_id"),o.optString("_request_id"))
    }
    fun intake(o: JSONObject)=IntakeSummary(o.getString("session_id"),o.getBoolean("bound"),o.getBoolean("completed"),
        o.getLong("captured_at"),sections(o.getJSONArray("sections")))
}
