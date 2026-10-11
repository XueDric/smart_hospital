import {
  ApiConfig,
  ApiError,
  ErrorCode,
  HttpClient,
  SseClient,
  SseHandlers
} from 'common-core';
import {
  Appointment,
  asArray,
  asBool,
  asNumber,
  asRecord,
  asString,
  asStringMap,
  CurrentUser,
  LoginResult,
  MedicalRecordDetail,
  MedicalRecordSection,
  MedicalRecordSummary,
  PatientNotice,
  PrevisitSession,
  Schedule,
  TriageOption,
  TriageResult
} from '../model/PatientModels';
import { MockPatientRepository } from './MockPatientRepository';

export class PatientRepository {
  private static instance: PatientRepository = new PatientRepository();

  static getInstance(): PatientRepository {
    return PatientRepository.instance;
  }

  async login(loginName: string, password: string): Promise<LoginResult> {
    if (ApiConfig.isMock()) {
      return MockPatientRepository.login(loginName, password);
    }
    const body: Record<string, Object> = {
      'login_name': loginName,
      'password': password
    };
    const response = asRecord(await HttpClient.getInstance().post('/api/v1/auth/login', body, false));
    const result = new LoginResult();
    result.token = asString(response['token']);
    result.expiresAt = asNumber(response['expires_at']);
    result.userId = asNumber(response['user_id']);
    result.role = asString(response['role']);
    result.refId = asNumber(response['ref_id']);
    result.displayName = asString(response['display_name']);
    result.patientId = asNumber(response['patient_id']);
    return result;
  }

  async me(): Promise<CurrentUser> {
    if (ApiConfig.isMock()) {
      return MockPatientRepository.me();
    }
    const response = asRecord(await HttpClient.getInstance().get('/api/v1/auth/me'));
    const result = new CurrentUser();
    result.userId = asNumber(response['user_id']);
    result.role = asString(response['role']);
    result.patientId = asNumber(response['patient_id']);
    result.doctorId = asNumber(response['doctor_id']);
    result.deviceId = asString(response['device_id']);
    return result;
  }

  async logout(): Promise<void> {
    if (ApiConfig.isMock()) {
      return;
    }
    try {
      const body: Record<string, Object> = {};
      await HttpClient.getInstance().post('/api/v1/auth/logout', body);
    } catch (error) {
      const apiError = ApiError.from(error as Error);
      if (apiError.status !== 401) {
        throw apiError;
      }
    }
  }

  async triage(chiefComplaint: string): Promise<TriageResult> {
    if (ApiConfig.isMock()) {
      return MockPatientRepository.triage(chiefComplaint);
    }
    const body: Record<string, Object> = {
      'chief_complaint': chiefComplaint
    };
    const response = asRecord(await HttpClient.getInstance().post('/api/v1/triage', body));
    return this.parseTriage(response);
  }

  async openPrevisitStream(chiefComplaint: string, handlers: SseHandlers): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockPatientRepository.openPrevisitStream(chiefComplaint, handlers);
    }
    const path = `/api/v1/previsit/stream?chief_complaint=${encodeURIComponent(chiefComplaint)}`;
    return SseClient.getInstance().open(path, handlers);
  }

  async answerPrevisit(sessionId: string, slot: string, value: string): Promise<PrevisitSession> {
    if (ApiConfig.isMock()) {
      return MockPatientRepository.answerPrevisit(sessionId, slot, value);
    }
    const body: Record<string, Object> = {
      'session_id': sessionId,
      'slot': slot,
      'value': value
    };
    const response = asRecord(await HttpClient.getInstance().post('/api/v1/previsit/answer', body));
    return this.parsePrevisit(response);
  }

  async getPrevisit(sessionId: string): Promise<PrevisitSession> {
    if (ApiConfig.isMock()) {
      return MockPatientRepository.getPrevisit(sessionId);
    }
    const path = `/api/v1/previsit/${encodeURIComponent(sessionId)}`;
    const response = asRecord(await HttpClient.getInstance().get(path));
    return this.parsePrevisit(response);
  }

  async schedules(departmentId: number = 0, workDate: string = '',
    limit: number = 100): Promise<Schedule[]> {
    if (ApiConfig.isMock()) {
      return MockPatientRepository.schedules(departmentId, workDate);
    }
    const query = this.buildScheduleQuery(departmentId, workDate, limit);
    const response = asRecord(await HttpClient.getInstance().get(`/api/v1/schedules${query}`));
    const result: Schedule[] = [];
    for (const item of asArray(response['schedules'])) {
      result.push(this.parseSchedule(asRecord(item)));
    }
    return result;
  }

  async schedule(scheduleId: number): Promise<Schedule> {
    if (ApiConfig.isMock()) {
      const schedules = await MockPatientRepository.schedules(0, '');
      for (const schedule of schedules) {
        if (schedule.id === scheduleId) {
          return schedule;
        }
      }
      throw new ApiError(ErrorCode.SCHEDULE_NOT_FOUND, '排班不存在或已停诊', 404);
    }
    const response = asRecord(await HttpClient.getInstance().get(`/api/v1/schedules/${scheduleId}`));
    return this.parseSchedule(response);
  }

  async book(scheduleId: number, clientToken: string): Promise<Appointment> {
    if (ApiConfig.isMock()) {
      return MockPatientRepository.book(scheduleId, clientToken);
    }
    const body: Record<string, Object> = {
      'schedule_id': scheduleId,
      'client_token': clientToken
    };
    const response = asRecord(await HttpClient.getInstance().post('/api/v1/appointments', body));
    return this.parseAppointment(response);
  }

  async appointments(includeCancelled: boolean = false): Promise<Appointment[]> {
    if (ApiConfig.isMock()) {
      return MockPatientRepository.appointments(includeCancelled);
    }
    const query = includeCancelled ? '?include_cancelled=true&limit=200' : '?limit=200';
    const response = asRecord(await HttpClient.getInstance().get(`/api/v1/appointments${query}`));
    const result: Appointment[] = [];
    for (const item of asArray(response['appointments'])) {
      result.push(this.parseAppointment(asRecord(item)));
    }
    return result;
  }

  async cancelAppointment(appointmentId: number): Promise<Appointment> {
    if (ApiConfig.isMock()) {
      return MockPatientRepository.cancel(appointmentId);
    }
    const body: Record<string, Object> = {};
    const response = asRecord(await HttpClient.getInstance()
      .post(`/api/v1/appointments/${appointmentId}/cancel`, body));
    return this.parseAppointment(response);
  }

  async medicalRecords(): Promise<MedicalRecordSummary[]> {
    if (ApiConfig.isMock()) {
      return MockPatientRepository.records();
    }
    const response = asRecord(await HttpClient.getInstance().get('/api/v1/medical-records?limit=200'));
    const result: MedicalRecordSummary[] = [];
    for (const item of asArray(response['items'])) {
      result.push(this.parseRecordSummary(asRecord(item)));
    }
    return result;
  }

  async medicalRecordDetail(appointmentId: number): Promise<MedicalRecordDetail> {
    if (ApiConfig.isMock()) {
      return MockPatientRepository.recordDetail(appointmentId);
    }
    const response = asRecord(await HttpClient.getInstance()
      .get(`/api/v1/medical-records/${appointmentId}`));
    const result = new MedicalRecordDetail();
    this.fillRecordSummary(result, response);
    const sections: MedicalRecordSection[] = [];
    for (const item of asArray(response['sections'])) {
      const source = asRecord(item);
      const section = new MedicalRecordSection();
      section.key = asString(source['key']);
      section.label = asString(source['label']);
      section.value = asString(source['value']);
      section.maxLen = asNumber(source['max_len']);
      section.requiredToLock = asBool(source['required_to_lock']);
      sections.push(section);
    }
    result.sections = sections;
    return result;
  }

  notices(): PatientNotice[] {
    return MockPatientRepository.notices();
  }

  private parseTriage(response: Record<string, Object>): TriageResult {
    const result = new TriageResult();
    result.redFlag = asBool(response['red_flag']);
    result.reasonCode = asString(response['reason_code']);
    result.source = asString(response['source']);
    result.patientNote = asString(response['patient_note']);
    result.truncated = asBool(response['truncated']);
    result.aiNote = asString(response['ai_note']);
    result.aiReason = asString(response['ai_reason']);
    result.count = asNumber(response['count']);
    const options: TriageOption[] = [];
    if (!result.redFlag) {
      for (const item of asArray(response['options'])) {
        const source = asRecord(item);
        const option = new TriageOption();
        option.departmentId = asNumber(source['department_id']);
        option.departmentName = asString(source['department_name']);
        option.doctorId = asNumber(source['doctor_id']);
        option.doctorName = asString(source['doctor_name']);
        option.doctorTitle = asString(source['doctor_title']);
        option.scheduleId = asNumber(source['schedule_id']);
        option.workDate = asString(source['work_date']);
        option.period = asString(source['period']);
        option.remainNum = asNumber(source['remain_num']);
        option.totalRemain = asNumber(source['total_remain']);
        options.push(option);
      }
    }
    result.options = options;
    if (result.count === 0) {
      result.count = options.length;
    }
    return result;
  }

  private parsePrevisit(response: Record<string, Object>): PrevisitSession {
    const result = new PrevisitSession();
    result.sessionId = asString(response['session_id']);
    result.turn = asNumber(response['turn']);
    result.filled = asNumber(response['filled']);
    result.totalSlots = asNumber(response['total_slots'], 6);
    result.complete = asBool(response['complete']);
    result.nextSlot = asString(response['next_slot']);
    result.nextQuestion = asString(response['next_question']);
    result.form = result.complete ? asStringMap(response['form']) : {};
    return result;
  }

  private parseSchedule(response: Record<string, Object>): Schedule {
    const result = new Schedule();
    result.id = asNumber(response['id']);
    result.doctorId = asNumber(response['doctor_id']);
    result.departmentId = asNumber(response['department_id']);
    result.workDate = asString(response['work_date']);
    result.period = asString(response['period']);
    result.totalNum = asNumber(response['total_num']);
    result.remainNum = asNumber(response['remain_num']);
    result.enabled = asBool(response['enabled'], true);
    return result;
  }

  private parseAppointment(response: Record<string, Object>): Appointment {
    const result = new Appointment();
    result.appointmentId = asNumber(response['appointment_id']);
    result.scheduleId = asNumber(response['schedule_id']);
    result.patientId = asNumber(response['patient_id']);
    result.doctorId = asNumber(response['doctor_id']);
    result.departmentId = asNumber(response['department_id']);
    result.visitDate = asString(response['visit_date']);
    result.period = asString(response['period']);
    result.seqNo = asNumber(response['seq_no']);
    result.status = asString(response['status']);
    result.slotRestored = asBool(response['slot_restored'], true);
    result.warning = asString(response['warning']);
    return result;
  }

  private parseRecordSummary(response: Record<string, Object>): MedicalRecordSummary {
    const result = new MedicalRecordSummary();
    this.fillRecordSummary(result, response);
    return result;
  }

  private fillRecordSummary(result: MedicalRecordSummary, response: Record<string, Object>): void {
    result.id = asNumber(response['id']);
    result.appointmentId = asNumber(response['appointment_id']);
    result.patientId = asNumber(response['patient_id']);
    result.doctorId = asNumber(response['doctor_id']);
    result.status = asString(response['status']);
    result.locked = asBool(response['locked']);
    result.filled = asNumber(response['filled']);
    result.totalSections = asNumber(response['total_sections'], 7);
    result.complete = asBool(response['complete']);
    result.updatedBy = asNumber(response['updated_by']);
    result.createdAt = asNumber(response['created_at']);
    result.updatedAt = asNumber(response['updated_at']);
    const missing: string[] = [];
    for (const value of asArray(response['missing_required'])) {
      missing.push(asString(value));
    }
    result.missingRequired = missing;
  }

  private buildScheduleQuery(departmentId: number, workDate: string, limit: number): string {
    const parts: string[] = [];
    if (departmentId > 0) {
      parts.push(`department_id=${departmentId}`);
    }
    if (workDate.length > 0) {
      parts.push(`work_date=${encodeURIComponent(workDate)}`);
    }
    parts.push(`limit=${limit}`);
    return `?${parts.join('&')}`;
  }
}
