import {
  Appointment,
  CurrentUser,
  LoginResult,
  MedicalRecordDetail,
  MedicalRecordSection,
  MedicalRecordSummary,
  PatientNotice,
  PrevisitSession,
  PrevisitSlots,
  Schedule,
  SlotDefinition,
  TriageOption,
  TriageResult
} from '../model/PatientModels';
import { ApiError, ErrorCode, SseHandlers } from 'common-core';

class MockBookingIntent {
  token: string = '';
  appointmentId: number = 0;

  constructor(token: string, appointmentId: number) {
    this.token = token;
    this.appointmentId = appointmentId;
  }
}

class MockState {
  static readonly SESSION_ID: string =
    '4f3a1d55d5c64d3e8f6c4b4a7d1e7c2f4f3a1d55d5c64d3e8f6c4b4a7d1e7c2f';
  static filled: string[] = [];
  static appointments: Appointment[] = [];
  static bookingIntents: MockBookingIntent[] = [];
  static initialized: boolean = false;
  static nextAppointmentId: number = 501;

  static initialize(): void {
    if (MockState.initialized) {
      return;
    }
    MockState.initialized = true;
    MockState.appointments = [
      MockState.makeAppointment(501, 41, 9, 3, '2026-11-20', 'AM', 6, 'booked'),
      MockState.makeAppointment(502, 52, 18, 6, '2026-11-24', 'PM', 2, 'done')
    ];
  }

  static makeAppointment(id: number, scheduleId: number, doctorId: number, departmentId: number,
    visitDate: string, period: string, seqNo: number, status: string): Appointment {
    const result = new Appointment();
    result.appointmentId = id;
    result.scheduleId = scheduleId;
    result.patientId = 7;
    result.doctorId = doctorId;
    result.departmentId = departmentId;
    result.visitDate = visitDate;
    result.period = period;
    result.seqNo = seqNo;
    result.status = status;
    result.slotRestored = true;
    return result;
  }
}

export class MockPatientRepository {
  static async login(loginName: string, password: string): Promise<LoginResult> {
    if (loginName.trim().length === 0 || password.length === 0) {
      throw new ApiError(ErrorCode.VALIDATION_FAILED, '请输入账号和密码', 400);
    }
    const result = new LoginResult();
    result.token = 'mock-patient-token';
    result.expiresAt = Math.floor(Date.now() / 1000) + 7 * 24 * 3600;
    result.userId = 12;
    result.role = 'patient';
    result.refId = 7;
    result.displayName = loginName.trim() === 'demo' ? '演示患者' : loginName.trim();
    result.patientId = 7;
    return result;
  }

  static async me(): Promise<CurrentUser> {
    const result = new CurrentUser();
    result.userId = 12;
    result.role = 'patient';
    result.patientId = 7;
    result.deviceId = 'mock-device';
    return result;
  }

  static async triage(chiefComplaint: string): Promise<TriageResult> {
    const text = chiefComplaint.trim();
    const result = new TriageResult();
    result.source = 'rules';
    result.reasonCode = 'OK';
    result.patientNote = '已根据主诉匹配到可预约号源。';
    result.aiReason = '当前为 Mock 模式，模拟规则引擎返回稳定数据。';
    if (text.length === 0) {
      result.reasonCode = 'NO_COMPLAINT';
      result.patientNote = '请补充症状、持续时间以及是否伴随发热等信息。';
      return result;
    }
    if (text.indexOf('胸痛') >= 0 || text.indexOf('呼吸困难') >= 0 || text.indexOf('晕厥') >= 0) {
      result.redFlag = true;
      result.reasonCode = 'RED_FLAG';
      result.patientNote = '检测到危急征象，请立即前往急诊或拨打 120，不要等待在线预约。';
      result.aiReason = '命中 Mock 危急规则。';
      result.count = 0;
      return result;
    }
    const first = new TriageOption();
    first.departmentId = 3;
    first.departmentName = '呼吸内科';
    first.doctorId = 9;
    first.doctorName = '李明医生';
    first.doctorTitle = '副主任医师';
    first.scheduleId = 41;
    first.workDate = '2026-11-20';
    first.period = 'AM';
    first.remainNum = 5;
    first.totalRemain = 12;
    const second = new TriageOption();
    second.departmentId = 5;
    second.departmentName = '全科门诊';
    second.doctorId = 15;
    second.doctorName = '周宁医生';
    second.doctorTitle = '主治医师';
    second.scheduleId = 48;
    second.workDate = '2026-11-20';
    second.period = 'PM';
    second.remainNum = 8;
    second.totalRemain = 18;
    if (text.indexOf('胃') >= 0 || text.indexOf('腹') >= 0) {
      first.departmentId = 4;
      first.departmentName = '消化内科';
    }
    result.options = [first, second];
    result.count = result.options.length;
    return result;
  }

  static async openPrevisitStream(chiefComplaint: string, handlers: SseHandlers): Promise<void> {
    MockState.filled = [];
    handlers.onMeta(MockState.SESSION_ID);
    await handlers.onDelta('您好，我会用 6 个问题帮您整理本次就诊信息。');
    handlers.onDone();
  }

  static async answerPrevisit(sessionId: string, slot: string, value: string): Promise<PrevisitSession> {
    if (sessionId !== MockState.SESSION_ID) {
      throw new ApiError(ErrorCode.PREVISIT_NOT_FOUND, '预问诊会话不存在或已过期', 404);
    }
    const trimmed = value.trim();
    if (trimmed.length > 0) {
      const existingIndex = MockState.filled.indexOf(slot);
      if (existingIndex < 0) {
        MockState.filled.push(slot);
      }
    }
    return MockPatientRepository.session();
  }

  static async getPrevisit(sessionId: string): Promise<PrevisitSession> {
    if (sessionId !== MockState.SESSION_ID) {
      throw new ApiError(ErrorCode.PREVISIT_NOT_FOUND, '预问诊会话不存在或已过期', 404);
    }
    return MockPatientRepository.session();
  }

  static async schedules(departmentId: number, workDate: string): Promise<Schedule[]> {
    const result: Schedule[] = [];
    const first = new Schedule();
    first.id = 41;
    first.doctorId = 9;
    first.departmentId = 3;
    first.workDate = '2026-11-20';
    first.period = 'AM';
    first.totalNum = 20;
    first.remainNum = 5;
    const second = new Schedule();
    second.id = 42;
    second.doctorId = 9;
    second.departmentId = 3;
    second.workDate = '2026-11-20';
    second.period = 'PM';
    second.totalNum = 20;
    second.remainNum = 0;
    const third = new Schedule();
    third.id = 48;
    third.doctorId = 15;
    third.departmentId = 5;
    third.workDate = '2026-11-21';
    third.period = 'PM';
    third.totalNum = 30;
    third.remainNum = 8;
    const all = [first, second, third];
    for (const schedule of all) {
      if (departmentId > 0 && schedule.departmentId !== departmentId) {
        continue;
      }
      if (workDate.length > 0 && schedule.workDate !== workDate) {
        continue;
      }
      result.push(schedule);
    }
    return result;
  }

  static async book(scheduleId: number, clientToken: string): Promise<Appointment> {
    MockState.initialize();
    for (const intent of MockState.bookingIntents) {
      if (intent.token === clientToken) {
        for (const appointment of MockState.appointments) {
          if (appointment.appointmentId === intent.appointmentId && appointment.status !== 'cancelled') {
            return appointment;
          }
        }
      }
    }
    const schedule = await MockPatientRepository.findSchedule(scheduleId);
    if (schedule.remainNum <= 0) {
      throw new ApiError(ErrorCode.SLOT_GONE, '号源刚被约满，请刷新后选择其他号源', 409);
    }
    const appointment = MockState.makeAppointment(MockState.nextAppointmentId++, scheduleId,
      schedule.doctorId, schedule.departmentId, schedule.workDate, schedule.period, 6, 'booked');
    MockState.bookingIntents.push(new MockBookingIntent(clientToken, appointment.appointmentId));
    MockState.appointments.unshift(appointment);
    return appointment;
  }

  static async appointments(includeCancelled: boolean): Promise<Appointment[]> {
    MockState.initialize();
    const result: Appointment[] = [];
    for (const appointment of MockState.appointments) {
      if (!includeCancelled && appointment.status === 'cancelled') {
        continue;
      }
      result.push(appointment);
    }
    return result;
  }

  static async cancel(appointmentId: number): Promise<Appointment> {
    MockState.initialize();
    for (const appointment of MockState.appointments) {
      if (appointment.appointmentId === appointmentId) {
        appointment.status = 'cancelled';
        appointment.slotRestored = true;
        appointment.warning = '';
        return appointment;
      }
    }
    throw new ApiError(ErrorCode.APPOINTMENT_NOT_FOUND, '挂号单不存在', 404);
  }

  static async records(): Promise<MedicalRecordSummary[]> {
    const item = new MedicalRecordSummary();
    item.id = 88;
    item.appointmentId = 502;
    item.patientId = 7;
    item.doctorId = 18;
    item.status = 'locked';
    item.locked = true;
    item.filled = 7;
    item.totalSections = 7;
    item.complete = true;
    item.updatedBy = 18;
    item.createdAt = Math.floor(Date.now() / 1000) - 86400;
    item.updatedAt = Math.floor(Date.now() / 1000) - 82000;
    return [item];
  }

  static async recordDetail(appointmentId: number): Promise<MedicalRecordDetail> {
    if (appointmentId !== 502) {
      throw new ApiError(ErrorCode.EMR_NOT_FOUND, '病历尚未提交，暂不可查看', 404);
    }
    const result = new MedicalRecordDetail();
    result.id = 88;
    result.appointmentId = 502;
    result.patientId = 7;
    result.doctorId = 18;
    result.status = 'locked';
    result.locked = true;
    result.filled = 7;
    result.totalSections = 7;
    result.complete = true;
    result.updatedBy = 18;
    result.createdAt = Math.floor(Date.now() / 1000) - 86400;
    result.updatedAt = Math.floor(Date.now() / 1000) - 82000;
    result.sections = [
      MockPatientRepository.section('chief_complaint', '主诉', '咳嗽伴咽痛 3 天', 2000, false),
      MockPatientRepository.section('present_illness', '现病史', '3 天前受凉后出现咳嗽，昨夜加重。', 4000, false),
      MockPatientRepository.section('past_history', '既往史', '无特殊。', 2000, false),
      MockPatientRepository.section('allergy_history', '过敏史', '无。', 2000, false),
      MockPatientRepository.section('physical_exam', '体格检查', '咽部充血，双肺呼吸音清。', 2000, false),
      MockPatientRepository.section('diagnosis', '诊断', '急性上呼吸道感染。', 2000, true),
      MockPatientRepository.section('treatment', '处理意见', '对症治疗，注意休息，多饮水。', 4000, true)
    ];
    return result;
  }

  static notices(): PatientNotice[] {
    const result: PatientNotice[] = [];
    const first = new PatientNotice();
    first.id = 1;
    first.title = '门诊预约就诊提醒';
    first.body = '请按预约时段提前 15 分钟到院，携带有效身份证件并完成签到。';
    first.date = '2026-10-08';
    first.category = '就诊提醒';
    const second = new PatientNotice();
    second.id = 2;
    second.title = '流感季节呼吸道防护建议';
    second.body = '进入医院请规范佩戴口罩；如有发热、咳嗽等症状，请优先前往发热门诊评估。';
    second.date = '2026-10-03';
    second.category = '健康提示';
    const third = new PatientNotice();
    third.id = 3;
    third.title = '电子病历查询说明';
    third.body = '医生提交并锁定病历后，可在“医疗档案”中查看本次就诊的七段式记录。';
    third.date = '2026-09-28';
    third.category = '服务说明';
    result.push(first, second, third);
    return result;
  }

  private static session(): PrevisitSession {
    const result = new PrevisitSession();
    result.sessionId = MockState.SESSION_ID;
    result.filled = MockState.filled.length;
    result.turn = MockState.filled.length;
    result.totalSlots = 6;
    result.complete = result.filled >= 6;
    if (result.complete) {
      result.nextSlot = '';
      result.nextQuestion = '';
      result.form = {
        'chief': '咳嗽、咽痛',
        'duration': '3 天',
        'severity': '轻微，不影响睡眠',
        'associated': '无',
        'history': '无',
        'allergy': '无'
      };
      return result;
    }
    const slot = MockPatientRepository.nextSlot();
    result.nextSlot = slot.key;
    result.nextQuestion = slot.question;
    return result;
  }

  private static nextSlot(): SlotDefinition {
    const order = ['chief', 'duration', 'severity', 'associated', 'history', 'allergy'];
    for (const key of order) {
      if (MockState.filled.indexOf(key) < 0) {
        for (const slot of PrevisitSlots.ALL) {
          if (slot.key === key) {
            return slot;
          }
        }
      }
    }
    return new SlotDefinition();
  }

  private static async findSchedule(scheduleId: number): Promise<Schedule> {
    const schedules = await MockPatientRepository.schedules(0, '');
    for (const schedule of schedules) {
      if (schedule.id === scheduleId) {
        return schedule;
      }
    }
    throw new ApiError(ErrorCode.SCHEDULE_NOT_FOUND, '排班不存在或已停诊', 404);
  }

  private static section(key: string, label: string, value: string, maxLen: number,
    required: boolean): MedicalRecordSection {
    const result = new MedicalRecordSection();
    result.key = key;
    result.label = label;
    result.value = value;
    result.maxLen = maxLen;
    result.requiredToLock = required;
    return result;
  }
}
