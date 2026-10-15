import { ApiError, ErrorCode } from 'common-core';
import {
  EmrRecord,
  EmrSection,
  LoginResult,
  PrevisitSlot,
  PrevisitSummary,
  VisitItem
} from '../model/DoctorModels';

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
    const nowSec = Math.floor(Date.now() / 1000);
    MockDoctorState.visits = [
      MockDoctorState.visit(601, 101, date, 'AM', 1, 'visiting', 'draft', 2),
      MockDoctorState.visit(602, 102, date, 'AM', 2, 'waiting', 'none', 0),
      MockDoctorState.visit(603, 103, date, 'PM', 1, 'booked', 'none', 0),
      MockDoctorState.visit(604, 104, date, 'AM', 3, 'done', 'locked', 7)
    ];
    /*
     * ⚠ 2026-10-16（复核 D3）：夹具必须覆盖中间两态，否则"按钮渲染对不对"根本看不出来。
     *   601 接诊中（有到院/接诊时刻 ⇒ 队列页能算出等待时长）
     *   602 候诊中（该给「开始接诊」）
     *   603 已挂号（该给「到院登记」）
     *   604 已完成（无按钮，只有时间线）
     */
    MockDoctorState.visits[0].statusLabel = '接诊中';
    MockDoctorState.visits[0].arrivedAt = nowSec - 1500;
    MockDoctorState.visits[0].startedAt = nowSec - 600;
    MockDoctorState.visits[1].statusLabel = '候诊中';
    MockDoctorState.visits[1].arrivedAt = nowSec - 480;
    MockDoctorState.visits[3].statusLabel = '已完成';
    MockDoctorState.visits[3].arrivedAt = nowSec - 5400;
    MockDoctorState.visits[3].startedAt = nowSec - 4800;
    MockDoctorState.visits[3].finishedAt = nowSec - 3000;
    MockDoctorState.records[601] = MockDoctorState.draft(601, 101);
    // 601 这单演示「患者已交预问诊」：队列徽标 + 病历页「患者自述」卡片/角标。
    MockDoctorState.visits[0].previsitReady = true;
    MockDoctorState.records[601].previsitRefSessionId = 'mock-previsit-601';
    MockDoctorState.records[601].previsitRefSections = ['chief_complaint', 'present_illness'];
    MockDoctorState.records[601].previsitRefAt = Math.floor(Date.now() / 1000) - 1800;
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

  /*
   * ⚠ 2026-10-16（复核 D3）：Mock 必须和服务端同一套状态机，否则"演示能跑、
   *   真机 409"（上一版就是这样：startVisit 从 booked 直接跳 visiting）。
   *   服务端约束：booked → arrived → waiting → visiting → done。
   */
  static async arriveVisit(appointmentId: number): Promise<void> {
    MockDoctorState.initialize();
    const item = MockDoctorRepository.find(appointmentId);
    if (item.status !== 'booked') {
      throw new ApiError('VISIT_BAD_STATE', `当前状态 ${item.status} 不允许流转到 arrived`, 409);
    }
    item.status = 'arrived';
    item.statusLabel = '已到院';
    item.arrivedAt = Math.floor(Date.now() / 1000);
  }

  static async waitingVisit(appointmentId: number): Promise<void> {
    MockDoctorState.initialize();
    const item = MockDoctorRepository.find(appointmentId);
    if (item.status !== 'arrived') {
      throw new ApiError('VISIT_BAD_STATE', `当前状态 ${item.status} 不允许流转到 waiting`, 409);
    }
    item.status = 'waiting';
    item.statusLabel = '候诊中';
  }

  static async startVisit(appointmentId: number): Promise<void> {
    MockDoctorState.initialize();
    const item = MockDoctorRepository.find(appointmentId);
    if (item.status !== 'waiting') {
      // 与服务端一致：只有"候诊中"才能开始接诊（booked 要先到院、再候诊）。
      throw new ApiError('VISIT_BAD_STATE',
        `当前状态 ${item.status} 不允许流转到 visiting（需先到院、候诊）`, 409);
    }
    item.status = 'visiting';
    item.statusLabel = '接诊中';
    item.startedAt = Math.floor(Date.now() / 1000);
  }

  static async finishVisit(appointmentId: number): Promise<void> {
    MockDoctorState.initialize();
    const item = MockDoctorRepository.find(appointmentId);
    const record = MockDoctorState.records[appointmentId];
    if (record === undefined || !record.locked) {
      throw new ApiError('EMR_NOT_LOCKED', '完成就诊前必须先提交锁定病历', 409);
    }
    item.status = 'done';
    item.statusLabel = '已完成';
    item.finishedAt = Math.floor(Date.now() / 1000);
  }

  static async noShow(appointmentId: number): Promise<void> {
    MockDoctorState.initialize();
    const item = MockDoctorRepository.find(appointmentId);
    item.status = 'no_show';
    item.statusLabel = '已爽约';
  }

  static async logout(): Promise<void> {
    // Mock 无服务端会话，登出即本地清理即可。
  }

  static async getPrevisit(appointmentId: number): Promise<PrevisitSummary> {
    MockDoctorState.initialize();
    if (appointmentId !== 601) {
      throw new ApiError('PREVISIT_NOT_FOUND', '该患者没有可用的预问诊摘要', 404);
    }
    const result = new PrevisitSummary();
    result.sessionId = 'mock-previsit-601';
    result.bound = true;
    result.turn = 6;
    result.completed = true;
    result.filled = 6;
    result.total = 6;
    result.capturedAt = Math.floor(Date.now() / 1000) - 1800;
    result.sections = [
      MockDoctorRepository.previsitSlot('chief', '主诉', '咳嗽伴咽痛 3 天', 200),
      MockDoctorRepository.previsitSlot('duration', '病程', '3 天', 60),
      MockDoctorRepository.previsitSlot('severity', '程度', '影响睡眠', 60),
      MockDoctorRepository.previsitSlot('associated', '伴随', '发热、咽干', 200),
      MockDoctorRepository.previsitSlot('history', '既往史', '无', 300),
      MockDoctorRepository.previsitSlot('allergy', '过敏史', '青霉素过敏', 200)
    ];
    return result;
  }

  private static previsitSlot(key: string, label: string, value: string, maxLen: number): PrevisitSlot {
    const result = new PrevisitSlot();
    result.key = key;
    result.label = label;
    result.value = value;
    result.maxLen = maxLen;
    return result;
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
