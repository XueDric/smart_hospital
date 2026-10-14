import {
  ApiConfig,
  HttpClient,
  asArray,
  asBool,
  asNumber,
  asRecord,
  asString
} from 'common-core';
import { EmrRecord, EmrSection, LoginResult, VisitItem } from '../model/DoctorModels';
import { MockDoctorRepository } from './MockDoctorRepository';

export class DoctorRepository {
  private static instance: DoctorRepository = new DoctorRepository();

  static getInstance(): DoctorRepository {
    return DoctorRepository.instance;
  }

  async login(loginName: string, password: string): Promise<LoginResult> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.login(loginName, password);
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
    return result;
  }

  async visits(): Promise<VisitItem[]> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.visits();
    }
    const response = asRecord(await HttpClient.getInstance().get('/api/v1/doctor/visits?limit=200'));
    const result: VisitItem[] = [];
    for (const item of asArray(response['items'])) {
      result.push(this.parseVisit(asRecord(item)));
    }
    return result;
  }

  async startVisit(appointmentId: number): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.startVisit(appointmentId);
    }
    // ArkTS 禁止"无类型对象字面量"（arkts-no-untyped-obj-literals）：先声明类型再传。
    const body: Record<string, Object> = {};
    await HttpClient.getInstance().post(`/api/v1/doctor/visits/${appointmentId}/start`, body);
  }

  async finishVisit(appointmentId: number): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.finishVisit(appointmentId);
    }
    const body: Record<string, Object> = {};
    await HttpClient.getInstance().post(`/api/v1/doctor/visits/${appointmentId}/finish`, body);
  }

  async noShow(appointmentId: number): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.noShow(appointmentId);
    }
    const body: Record<string, Object> = {};
    await HttpClient.getInstance().post(`/api/v1/doctor/visits/${appointmentId}/no-show`, body);
  }

  async getRecord(appointmentId: number): Promise<EmrRecord> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.getRecord(appointmentId);
    }
    const response = asRecord(await HttpClient.getInstance()
      .get(`/api/v1/doctor/visits/${appointmentId}/record`));
    return this.parseRecord(response);
  }

  async saveDraft(appointmentId: number, sections: Record<string, string>,
    useIntakeSession: string = ''): Promise<EmrRecord> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.saveDraft(appointmentId, sections);
    }
    const body: Record<string, Object> = {};
    const keys = Object.keys(sections);
    for (const key of keys) {
      body[key] = sections[key];
    }
    if (useIntakeSession.length > 0) {
      body['use_intake_session'] = useIntakeSession;
    }
    const response = asRecord(await HttpClient.getInstance()
      .put(`/api/v1/doctor/visits/${appointmentId}/record`, body));
    return this.parseRecord(response);
  }

  async lockRecord(appointmentId: number): Promise<EmrRecord> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.lockRecord(appointmentId);
    }
    const body: Record<string, Object> = {};
    const response = asRecord(await HttpClient.getInstance()
      .post(`/api/v1/doctor/visits/${appointmentId}/record/lock`, body));
    return this.parseRecord(response);
  }

  private parseVisit(response: Record<string, Object>): VisitItem {
    const result = new VisitItem();
    result.appointmentId = asNumber(response['appointment_id']);
    result.patientId = asNumber(response['patient_id']);
    result.doctorId = asNumber(response['doctor_id']);
    result.departmentId = asNumber(response['department_id']);
    result.visitDate = asString(response['visit_date']);
    result.period = asString(response['period']);
    result.seqNo = asNumber(response['seq_no']);
    result.status = asString(response['status']);
    result.recordId = asNumber(response['record_id']);
    result.recordStatus = asString(response['record_status'], 'none');
    result.recordFilled = asNumber(response['record_filled']);
    result.recordTotal = asNumber(response['record_total'], 7);
    return result;
  }

  private parseRecord(response: Record<string, Object>): EmrRecord {
    const result = new EmrRecord();
    result.id = asNumber(response['id']);
    result.appointmentId = asNumber(response['appointment_id']);
    result.patientId = asNumber(response['patient_id']);
    result.doctorId = asNumber(response['doctor_id']);
    result.status = asString(response['status'], 'none');
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
    const sections: EmrSection[] = [];
    for (const item of asArray(response['sections'])) {
      const source = asRecord(item);
      const section = new EmrSection();
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
}
