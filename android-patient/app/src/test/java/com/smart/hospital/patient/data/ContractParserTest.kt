package com.smart.hospital.patient.data

import org.json.JSONException
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 契约层单元测试（纯 JVM，不连服务端、不需要模拟器）。
 *
 * 为什么要它：2026-10-18 审查同事提交时，同一类缺陷连出三次 ——
 *   A1 医生队列响应没有 `schedule_id`，`ContractParser.appointment()` 却用 `getLong` 必填；
 *   A2 病历响应没有 `version`，`ContractParser.record()` 却用 `get` 必填；
 *   A3 乐观锁字段名客户端发 `expected_version`、服务端读 `expected_updated_at`，静默失效。
 * 三个都是"字段名/必填性"错配，全部可以在编译期之外用**真实响应样本**抓出来。
 *
 * 样本在 `app/src/test/resources/contracts/`，都是从本机服务端（`--port 8091`）真实抓下来的
 * 完整响应（含 `{"ok":true,"data":…}` 外壳），因此样本与服务端同期。
 */
class ContractParserTest {

    private fun fixture(name: String): JSONObject {
        val stream = javaClass.classLoader!!.getResourceAsStream("contracts/$name")
            ?: throw IllegalStateException("缺少金样本 contracts/$name")
        return JSONObject(stream.bufferedReader().use { it.readText() })
    }

    private fun dataOf(name: String): JSONObject = fixture(name).getJSONObject("data")

    /**
     * A1 回归：医生队列的 items **没有** `schedule_id`（那是患者侧 /appointments 才有的字段），
     * 解析必须当可选处理，缺省 0，而不是抛 JSONException 让整页红条。
     */
    @Test
    fun `医生队列缺 schedule_id 也能解析`() {
        val items = dataOf("doctor-visits.json").getJSONArray("items")
        assertTrue("金样本应至少有一条接诊记录", items.length() > 0)
        for (i in 0 until items.length()) {
            val raw = items.getJSONObject(i)
            assertTrue("金样本本身不该带 schedule_id（否则这条回归就失效了）", !raw.has("schedule_id"))
            val a = ContractParser.appointment(raw)
            assertEquals(0L, a.scheduleId)
            assertTrue("appointment_id 必须解析出来", a.appointmentId > 0)
            assertTrue("就诊日必须是 YYYY-MM-DD", a.visitDate.matches(Regex("""\d{4}-\d{2}-\d{2}""")))
        }
    }

    /** 全新挂号单的病历：`version` 是 0，且与 `updated_at` 一致（服务端就是这么定义的）。 */
    @Test
    fun `空病历 version 为 0`() {
        val d = dataOf("doctor-record.json")
        val r = ContractParser.record(d)
        assertEquals(0L, r.version)
        assertEquals(r.updatedAt, r.version)
        assertTrue("空病历应有七段骨架（服务端固定返回）", r.sections.size >= 7)
        assertTrue("空病历必须列出必填缺项", r.missingRequired.isNotEmpty())
    }

    /** A2/A3 回归：保存过之后 `version` 与 `updated_at` 同步前进，且是正数（乐观锁令牌）。 */
    @Test
    fun `已保存病历 version 等于 updated_at 且为正`() {
        val r = ContractParser.record(dataOf("doctor-record-saved.json"))
        assertTrue("version 必须是正数，0 表示从未保存", r.version > 0)
        assertEquals(r.updatedAt, r.version)
    }

    /** 缺 `version` 必须**显式失败**，绝不能悄悄变成可写的 v0（会覆盖别人的修改）。 */
    @Test
    fun `缺 version 必须抛异常`() {
        val d = dataOf("doctor-record-saved.json")
        d.remove("version")
        val e = assertThrows(JSONException::class.java) { ContractParser.record(d) }
        assertTrue("错误信息应说明 version 不合法", e.message!!.contains("version"))
    }

    @Test
    fun `version 为负数必须抛异常`() {
        val d = dataOf("doctor-record-saved.json")
        d.put("version", -1)
        assertThrows(JSONException::class.java) { ContractParser.record(d) }
    }

    @Test
    fun `version 为字符串必须抛异常`() {
        val d = dataOf("doctor-record-saved.json")
        d.put("version", "12")
        assertThrows(JSONException::class.java) { ContractParser.record(d) }
    }

    /**
     * 登录口径：服务端只给**当前角色**的 id —— 医生拿到的 `patient_id` 是 0
     * （2026-10-18 修过：原来不分角色直接回 ref_id，与 /auth/me 自相矛盾），
     * 而医生自己的 `doctor_id` 服务端不给，客户端回退 `ref_id`。
     */
    @Test
    fun `医生登录 patient_id 为 0 且 doctor_id 回退 ref_id`() {
        val d = dataOf("auth-login-doctor.json")
        val r = ContractParser.login(d)
        assertEquals("doctor", r.role)
        assertEquals(0L, r.patientId)
        assertEquals(r.refId, r.doctorId)
        assertTrue(r.token.isNotEmpty())
        assertTrue(r.expiresAt > 0)
    }

    @Test
    fun `患者登录带上 patient_id`() {
        val r = ContractParser.login(dataOf("auth-login-patient.json"))
        assertEquals("patient", r.role)
        assertEquals(r.refId, r.patientId)
        assertEquals(0L, r.doctorId)
    }

    /** 患者侧 /appointments 才带科室/医生名字（BUG-10 就是"列表忽略自带名字"）。 */
    @Test
    fun `预约列表带科室与医生名字`() {
        val arr = dataOf("appointments.json").getJSONArray("appointments")
        assertTrue(arr.length() > 0)
        val a = ContractParser.appointment(arr.getJSONObject(0))
        assertTrue("科室名不能为空", a.departmentName.isNotEmpty())
        assertTrue("医生名不能为空", a.doctorName.isNotEmpty())
        assertTrue("患者侧响应应带 schedule_id", a.scheduleId > 0)
    }

    /** 分诊：模型增强结果里每个备选都必须能落到一个真实号源（schedule_id > 0）。 */
    @Test
    fun `分诊备选号源可解析`() {
        val r = ContractParser.triage(dataOf("triage.json"))
        assertEquals("model", r.source)
        assertTrue(r.options.isNotEmpty())
        for (o in r.options) {
            assertTrue("备选必须有真实号源", o.scheduleId > 0)
            assertTrue("备选必须有科室名", o.departmentName.isNotEmpty())
            assertTrue("余号必须 >= 0", o.remainNum >= 0)
        }
    }
}