import { ApiError, ErrorCode } from 'common-core';
import { EmrRecord, EmrSection, LoginResult, VisitItem } from '../model/DoctorModels';

class MockDoctorState {
  static visits: VisitItem[] = [];
  static records: Record<number, EmrRecord> = {};
  static initialized: boolean = false;

  static initialize(): void {
    if (MockDoctorState.initialized) {
      return;
    }
    MockDoctorState.initialized = true;
    const today = new Date();
    const date = `${today.getFullYear()}-${pad2(today.getMonth() + 1)}-${pad2(today.getDate())}`;
    MockDoctorState.visits = [
      MockDoctorState.visit(601, 101, date, 'AM', 1, 'visiting', 'draft', 2),
      MockDoctorState.visit(602, 102, date, 'AM', 2, 'booked', 'none', 0),
      MockDoctorState.visit(603, 103, date, 'PM', 1, 'booked', 'none', 0),
      MockDoctorState.visit(604, 104, date, 'AM', 3, 'done', 'locked', 7)
    ];
    MockDoctorState.records[601] = MockDoctorState.draft(601, 101);
  }

  private static visit(appointmentId: number, patientId: number, visitDate: string, period: string,
    seqNo: number, status: string, recordStatus: string, recordFilled: number): VisitItem {
    const result = new VisitItem();
    result.appointmentId = appointmentId;
    result.patientId = patientId;
    result.doctorId = 9;
    result.departmentId = 3;
    result.visitDate = visitDate;
    result.period = period;
    result.seqNo = seqNo;
    result.status = status;
    result.recordStatus = recordStatus;
    result.recordFilled = recordFilled;
    result.recordTotal = 7;
    return result;
  }

  private static draft(appointmentId: number, patientId: number): EmrRecord {
    const result = MockDoctorState.skeleton(appointmentId, patientId);
    result.status = 'draft';
    result.filled = 2;
    result.complete = false;
    result.sections = [
      MockDoctorState.section('chief_complaint', '主诉', '咳嗽伴咽痛 3 天', 2000, false),
      MockDoctorState.section('present_illness', '现病史', '3 天前受凉后出现咳嗽，昨夜加重。', 4000, false),
      MockDoctorState.section('past_history', '既往史', '', 2000, false),
      MockDoctorState.section('allergy_history', '过敏史', '', 2000, false),
      MockDoctorState.section('physical_exam', '体格检查', '', 2000, false),
      MockDoctorState.section('diagnosis', '诊断', '', 2000, true),
      MockDoctorState.section('treatment', '处理意见', '', 4000, true)
    ];
    return result;
  }

  // 非 private：本文件的 MockDoctorRepository 需要复用这两个夹具工厂
  // （私有静态成员不能被类外访问，ArkTS 编译期直接报错）。
  static skeleton(appointmentId: number, patientId: number): EmrRecord {
    const result = new EmrRecord();
    result.id = appointmentId;
    result.appointmentId = appointmentId;
    result.patientId = patientId;
    result.doctorId = 9;
    result.status = 'none';
    result.locked = false;
    result.filled = 0;
    result.totalSections = 7;
    result.complete = false;
    return result;
  }

  static section(key: string, label: string, value: string, maxLen: number,
    required: boolean): EmrSection {
    const result = new EmrSection();
    result.key = key;
    result.label = label;
    result.value = value;
    result.maxLen = maxLen;
    result.requiredToLock = required;
    return result;
  }
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}

export class MockDoctorRepository {
  static async login(loginName: string, password: string): Promise<LoginResult> {
    if (loginName.trim().length === 0 || password.length === 0) {
      throw new ApiError(ErrorCode.VALIDATION_FAILED, '请输入工号和密码', 400);
    }
    const result = new LoginResult();
    result.token = 'mock-doctor-token';
    result.expiresAt = Math.floor(Date.now() / 1000) + 7 * 24 * 3600;
    result.userId = 22;
    result.role = 'doctor';
    result.refId = 9;
    result.displayName = '李明医生';
    return result;
  }

  static async visits(): Promise<VisitItem[]> {
    MockDoctorState.initialize();
    return MockDoctorState.visits;
  }

  static async startVisit(appointmentId: number): Promise<void> {
    MockDoctorState.initialize();
    const item = MockDoctorRepository.find(appointmentId);
    if (item.status !== 'booked') {
      throw new ApiError('VISIT_BAD_STATE', '当前状态不允许开始接诊', 409);
    }
    item.status = 'visiting';
  }

  static async finishVisit(appointmentId: number): Promise<void> {
    MockDoctorState.initialize();
    const item = MockDoctorRepository.find(appointmentId);
    const record = MockDoctorState.records[appointmentId];
    if (record === undefined || !record.locked) {
      throw new ApiError('EMR_NOT_LOCKED', '完成就诊前必须先提交锁定病历', 409);
    }
    item.status = 'done';
  }

  static async noShow(appointmentId: number): Promise<void> {
    MockDoctorState.initialize();
    const item = MockDoctorRepository.find(appointmentId);
    item.status = 'no_show';
  }

  static async getRecord(appointmentId: number): Promise<EmrRecord> {
    MockDoctorState.initialize();
    const existing = MockDoctorState.records[appointmentId];
    if (existing !== undefined) {
      return existing;
    }
    const item = MockDoctorRepository.find(appointmentId);
    const result = MockDoctorState.skeleton(appointmentId, item.patientId);
    result.sections = [
      MockDoctorState.section('chief_complaint', '主诉', '', 2000, false),
      MockDoctorState.section('present_illness', '现病史', '', 4000, false),
      MockDoctorState.section('past_history', '既往史', '', 2000, false),
      MockDoctorState.section('allergy_history', '过敏史', '', 2000, false),
      MockDoctorState.section('physical_exam', '体格检查', '', 2000, false),
      MockDoctorState.section('diagnosis', '诊断', '', 2000, true),
      MockDoctorState.section('treatment', '处理意见', '', 4000, true)
    ];
    return result;
  }

  static async saveDraft(appointmentId: number, sections: Record<string, string>): Promise<EmrRecord> {
    MockDoctorState.initialize();
    const record = await MockDoctorRepository.getRecord(appointmentId);
    const keys = Object.keys(sections);
    for (const key of keys) {
      for (const section of record.sections) {
        if (section.key === key) {
          section.value = sections[key];
        }
      }
    }
    record.status = 'draft';
    record.filled = MockDoctorRepository.countFilled(record);
    record.complete = record.filled >= record.sections.length;
    record.updatedAt = Math.floor(Date.now() / 1000);
    MockDoctorState.records[appointmentId] = record;
    MockDoctorRepository.syncVisit(appointmentId, 'draft', record.filled);
    return record;
  }

  static async lockRecord(appointmentId: number): Promise<EmrRecord> {
    MockDoctorState.initialize();
    const record = MockDoctorState.records[appointmentId];
    if (record === undefined) {
      const draft = await MockDoctorRepository.saveDraft(appointmentId, {});
      MockDoctorState.records[appointmentId] = draft;
    }
    const target = MockDoctorState.records[appointmentId];
    const missing: string[] = [];
    for (const section of target.sections) {
      if (section.requiredToLock && section.value.trim().length === 0) {
        missing.push(section.label);
      }
    }
    if (missing.length > 0) {
      throw new ApiError(ErrorCode.VALIDATION_FAILED, `提交前必须填写 ${missing.join('、')}`, 400);
    }
    target.status = 'locked';
    target.locked = true;
    target.filled = MockDoctorRepository.countFilled(target);
    target.complete = true;
    target.updatedAt = Math.floor(Date.now() / 1000);
    MockDoctorState.records[appointmentId] = target;
    MockDoctorRepository.syncVisit(appointmentId, 'locked', target.filled);
    return target;
  }

  private static find(appointmentId: number): VisitItem {
    for (const item of MockDoctorState.visits) {
      if (item.appointmentId === appointmentId) {
        return item;
      }
    }
    throw new ApiError(ErrorCode.APPOINTMENT_NOT_FOUND, '挂号单不存在或不属于你', 404);
  }

  private static countFilled(record: EmrRecord): number {
    let count = 0;
    for (const section of record.sections) {
      if (section.value.trim().length > 0) {
        count++;
      }
    }
    return count;
  }

  private static syncVisit(appointmentId: number, recordStatus: string, recordFilled: number): void {
    for (const item of MockDoctorState.visits) {
      if (item.appointmentId === appointmentId) {
        item.recordStatus = recordStatus;
        item.recordFilled = recordFilled;
        return;
      }
    }
  }
}
