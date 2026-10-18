package com.smart.hospital.patient.model

data class LoginResult(val token: String, val expiresAt: Long, val userId: Long, val role: String,
                       val refId: Long, val displayName: String, val patientId: Long, val doctorId: Long = 0)
data class CurrentUser(val userId: Long, val role: String, val patientId: Long, val doctorId: Long,
                       val deviceId: String, val displayName: String = "", val expiresAt: Long = 0)
data class TriageOption(val departmentId: Long, val departmentName: String, val doctorId: Long,
                        val doctorName: String, val doctorTitle: String, val scheduleId: Long,
                        val workDate: String, val period: String, val remainNum: Int,
                        val totalRemain: Int)
data class TriageResult(val redFlag: Boolean, val reasonCode: String, val source: String,
                        val patientNote: String, val truncated: Boolean, val aiNote: String,
                        val aiReason: String, val options: List<TriageOption>, val requestId: String = "")
data class Schedule(val id: Long, val doctorId: Long, val departmentId: Long, val workDate: String,
                    val period: String, val totalNum: Int, val remainNum: Int, val enabled: Boolean,
                    val departmentName: String = "", val doctorName: String = "",
                    val doctorTitle: String = "")
data class Appointment(val appointmentId: Long, val scheduleId: Long, val patientId: Long,
                       val doctorId: Long, val departmentId: Long, val visitDate: String,
                       val period: String, val seqNo: Int, val status: String,
                       val slotRestored: Boolean = false, val warning: String = "",
                       val replayed: Boolean = false, val departmentName: String = "",
                       val doctorName: String = "", val doctorTitle: String = "",
                       val previsitId: String = "", val previsitBound: Boolean = false,
                       val createdAt: Long = 0, val arrivedAt: Long = 0, val waitingAt: Long = 0,
                       val startedAt: Long = 0, val finishedAt: Long = 0, val requestId: String = "",
                       val statusLabel: String = "")
data class PrevisitSession(val sessionId: String, val turn: Int, val filled: Int,
                           val totalSlots: Int, val complete: Boolean, val nextSlot: String,
                           val nextQuestion: String, val form: Map<String, String> = emptyMap(),
                           val expired: Boolean = false, val assistantText: String = "",
                           val appointmentId: Long = 0, val requestId: String = "")
data class MedicalRecordSummary(val id: Long, val appointmentId: Long, val status: String,
                                val locked: Boolean, val filled: Int, val totalSections: Int,
                                val patientId: Long = 0, val doctorId: Long = 0,
                                val departmentId: Long = 0, val visitDate: String = "",
                                val period: String = "", val departmentName: String = "",
                                val doctorName: String = "", val doctorTitle: String = "",
                                val createdAt: Long = 0, val updatedAt: Long = 0,
                                val complete: Boolean = false)
data class MedicalRecordSection(val key: String, val label: String, val value: String,
                                val requiredToLock: Boolean = false)
data class MedicalRecordDetail(val summary: MedicalRecordSummary,
                               val sections: List<MedicalRecordSection>)

data class PendingBooking(val scheduleId: Long, val clientToken: String, val previsitId: String = "")

data class PatientNotice(val id: Long, val title: String, val body: String,
                         val date: String, val category: String)
data class DoctorVisit(val appointment: Appointment, val recordStatus: String,
                       val recordFilled: Int, val previsitReady: Boolean)
data class DoctorSection(val key: String, val label: String, val value: String,
                         val maxLen: Int, val requiredToLock: Boolean)
data class IntakeSummary(val sessionId: String, val bound: Boolean, val completed: Boolean,
                         val capturedAt: Long, val sections: List<DoctorSection>)
data class DoctorRecord(val appointmentId: Long, val locked: Boolean, val version: Long,
                        val updatedAt: Long, val sections: List<DoctorSection>,
                        val missingRequired: List<String>, val intakeSections: Set<String>,
                        val intakeSessionId: String = "", val requestId: String = "")
