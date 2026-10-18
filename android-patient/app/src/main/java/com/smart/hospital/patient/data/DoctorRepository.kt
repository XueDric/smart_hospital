package com.smart.hospital.patient.data

import com.smart.hospital.patient.model.*
import org.json.JSONArray
import org.json.JSONObject

class DoctorRepository(private val api: ApiClient, private val session: SessionStore) {
    private var demoVisit = Appointment(9001,41,7,9,3,"2026-10-15","AM",1,"booked",previsitBound=true,previsitId="demo-intake")
    private val demoFields = listOf("chief_complaint" to "主诉","present_illness" to "现病史","past_history" to "既往史",
        "allergy_history" to "过敏史","physical_exam" to "体格检查","diagnosis" to "诊断","treatment" to "处理意见")
    private var demoRecord = DoctorRecord(9001,false,0,0,demoFields.map { (key,label) ->
        DoctorSection(key,label,"",if (key in setOf("present_illness","treatment")) 4000 else 2000,key in setOf("diagnosis","treatment"))
    },listOf("诊断","处理意见"),emptySet())
    private val demoVersions = mutableListOf<JSONObject>()
    fun login(name: String,password: String) = ContractParser.login(api.post("/api/v1/auth/login",
        JSONObject().put("login_name",name).put("password",password))).also {
        if (it.role != "doctor" || it.doctorId <= 0) throw ApiException(403,"FORBIDDEN_ROLE","请使用绑定医生档案的医生账号")
    }
    fun demoLogin(): LoginResult = LoginResult("d".repeat(64),System.currentTimeMillis()/1000+86400,9,"doctor",9,"演示医生",0,9)
    fun me() {
        if (session.mockMode) return
        val token=session.token; val base=session.baseUrl
        val d=api.get("/api/v1/auth/me")
        val user=CurrentUser(d.getLong("user_id"),d.getString("role"),d.optLong("patient_id"),d.optLong("doctor_id"),
            d.optString("device_id"),d.optString("display_name"),d.optLong("expires_at"))
        if (user.role != "doctor" || !session.updateCurrentUserIfCurrent(user,token,base)) {
            session.clearLoginIfCurrent(token,base)
            throw ApiException(403,"FORBIDDEN_ROLE","医生身份已变化，请重新登录")
        }
    }
    fun logout() {
        val token=session.token;val base=session.baseUrl
        try { if (!session.mockMode) api.postWithStatus("/api/v1/auth/logout",JSONObject(),base,token) }
        finally { session.clearLoginIfCurrent(token,base) }
    }
    fun queue(): List<DoctorVisit> {
        if (session.mockMode) return listOf(DoctorVisit(demoVisit,if(demoRecord.locked) "locked" else "draft",demoRecord.sections.count { it.value.isNotBlank() },true))
        val rows=api.get("/api/v1/doctor/visits?limit=200").getJSONArray("items")
        return (0 until rows.length()).map { i -> val o=rows.getJSONObject(i)
            DoctorVisit(ContractParser.appointment(o),o.optString("record_status"),o.optInt("record_filled"),o.optBoolean("previsit_ready")) }
    }
    private fun path(id: Long)="/api/v1/doctor/visits/$id"
    fun record(id: Long)=if(session.mockMode) demoRecord else ContractParser.record(api.get(path(id)+"/record"))
    fun intake(id: Long): IntakeSummary? {
        if(session.mockMode) return IntakeSummary("demo-intake",true,true,System.currentTimeMillis()/1000,
            listOf(DoctorSection("chief_complaint","主诉","咳嗽三天",2000,false),DoctorSection("present_illness","现病史","持续三天，影响睡眠",4000,false)))
        return try { ContractParser.intake(api.get(path(id)+"/previsit")) }
        catch(error:ApiException) {
            if(error.status==404 && error.code=="PREVISIT_NOT_FOUND") null else throw error
        }
    }
    fun history(patientId:Long, exclude:Long): List<DoctorRecord> {
        if(session.mockMode) return emptyList()
        val data=api.get("/api/v1/doctor/patients/$patientId/records?limit=5&exclude_appointment_id=$exclude")
        if(data.getLong("patient_id")!=patientId) throw org.json.JSONException("既往病历患者编号不一致")
        val rows=data.getJSONArray("items")
        return (0 until rows.length()).map {ContractParser.record(rows.getJSONObject(it))}
    }
    fun save(id: Long, version: Long, values: Map<String,String>): DoctorRecord {
        if(session.mockMode) {
            check(version==demoRecord.version) { "病历已变化，请刷新" }
            check(!demoRecord.locked) { "病历已锁定" }
            demoRecord=demoRecord.copy(version=version+1,updatedAt=System.currentTimeMillis()/1000,
                sections=demoRecord.sections.map { it.copy(value=values[it.key] ?: it.value) })
            return demoRecord
        }
        val body=JSONObject().put("expected_version",version)
        values.forEach { (k,v)->body.put(k,v) }
        return ContractParser.record(api.put(path(id)+"/record",body))
    }
    fun lock(id: Long, version: Long): DoctorRecord {
        if(session.mockMode) {
            check(version==demoRecord.version && !demoRecord.locked)
            check(demoRecord.sections.filter { it.requiredToLock }.all { it.value.isNotBlank() }) { "请填写诊断和处理意见" }
            demoRecord=demoRecord.copy(locked=true,version=version+1,updatedAt=System.currentTimeMillis()/1000)
            demoVersions.add(JSONObject().put("version",demoRecord.version).put("created_at",demoRecord.updatedAt)
                .put("operator_user_id",9).put("operation","lock").put("reason",""))
            return demoRecord
        }
        return ContractParser.record(api.post(path(id)+"/record/lock",JSONObject().put("expected_version",version)))
    }
    fun action(id: Long, action: String) {
        require(action in setOf("arrive","waiting","start","finish","no-show")) { "当前服务端不支持此接诊操作" }
        if(session.mockMode) {
            val next=mapOf("arrive" to "arrived","waiting" to "waiting","start" to "visiting","finish" to "done","no-show" to "no_show").getValue(action)
            check((action=="arrive" && demoVisit.status=="booked") ||
                (action=="waiting" && demoVisit.status=="arrived") ||
                (action=="start" && demoVisit.status=="waiting") ||
                (action=="finish" && demoVisit.status=="visiting") ||
                (action=="no-show" && demoVisit.status in setOf("booked","arrived","waiting","visiting"))) { "当前就诊状态不允许此操作" }
            check(action!="finish" || demoRecord.locked) { "请先锁定病历" }
            val now=System.currentTimeMillis()/1000
            demoVisit=demoVisit.copy(status=next,arrivedAt=if(action=="arrive") now else demoVisit.arrivedAt,
                startedAt=if(action=="start") now else demoVisit.startedAt,finishedAt=if(action=="finish") now else demoVisit.finishedAt)
        } else api.post(path(id)+"/$action",JSONObject())
    }
    fun revisions(id: Long): JSONObject = if(session.mockMode) JSONObject().put("items",JSONArray(demoVersions))
        else api.get(path(id)+"/record/revisions")
    fun diff(id: Long,version: Long,against: Long): JSONObject = if(session.mockMode) JSONObject().put("sections",JSONArray())
        else api.get(path(id)+"/record/revisions/$version/diff?against=$against")
}
