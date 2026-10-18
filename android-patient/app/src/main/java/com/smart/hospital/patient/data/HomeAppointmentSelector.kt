package com.smart.hospital.patient.data

import com.smart.hospital.patient.model.Appointment

/** Mirrors Harmony HomePage + VisitStatus; repository list order is not visit order. */
object HomeAppointmentSelector {
    fun select(appointments: List<Appointment>): Appointment? {
        var next: Appointment? = null
        for (appointment in appointments) {
            // Unknown states stay visible, matching Harmony's non-terminal rule.
            if (appointment.status in setOf("done", "cancelled", "no_show")) continue
            if (next == null || isEarlier(appointment, next)) next = appointment
        }
        return next
    }

    private fun isEarlier(candidate: Appointment, current: Appointment): Boolean {
        val candidateStatus = statusPriority(candidate.status)
        val currentStatus = statusPriority(current.status)
        if (candidateStatus != currentStatus) return candidateStatus < currentStatus
        if (candidate.visitDate.isEmpty() || current.visitDate.isEmpty()) {
            if (candidate.visitDate.isEmpty() != current.visitDate.isEmpty()) {
                return candidate.visitDate.isNotEmpty()
            }
        } else if (candidate.visitDate != current.visitDate) {
            return candidate.visitDate < current.visitDate
        }
        val candidatePeriod = periodPriority(candidate.period)
        val currentPeriod = periodPriority(current.period)
        if (candidatePeriod != currentPeriod) return candidatePeriod < currentPeriod
        // Equal candidates keep the first occurrence, as Harmony's strict comparison does.
        return candidate.seqNo < current.seqNo
    }

    private fun statusPriority(status: String) = when (status) {
        "visiting" -> 0
        "waiting" -> 1
        "arrived" -> 2
        "booked" -> 3
        else -> 0
    }

    private fun periodPriority(period: String) = when (period) {
        "AM" -> 0
        "PM" -> 1
        else -> 2
    }
}
