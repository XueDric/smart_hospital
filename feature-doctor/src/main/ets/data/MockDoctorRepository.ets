import { ApiError, ErrorCode } from 'common-core';
import {
  EmrRecord,
  EmrSection,
  LoginResult,
  PastRecord,
  PrevisitSlot,
  PrevisitSummary,
  RevisionDetail,
  RevisionDiff,
  RevisionDiffSection,
  RevisionItem,
  VisitItem
} from '../model/DoctorModels';

/*
 * Mock 里的一版修订快照。字段与服务端 `record_revision` 一一对应，
 * 连 `operatorRole` 可能是空串（存量补录）也照抄 —— mock 比契约宽松，
 * 就等于把"真机上才会炸"留给演示。
 */
class MockRevision {
  version: number = 0;
  status: string = 'locked';
  operation: string = 'lock';
  reason: string = '';
  operatorUserId: number = 0;
  operatorRole: string = '';
  createdAt: number = 0;
  sections: EmrSection[] = [];
}

class MockDoctorState {
  static visits: VisitItem[] = [];
  static records: Record<number, EmrRecord> = {};
  // appointmentId → 修订版本（升序，v1 在前），语义同服务端 `record_revision`。
  static revisions: Record<number, MockRevision[]> = {};
  // 既往病历夹具（更早就诊、已定稿，不在今日队列里）。
  static historical: PastRecord[] = [];
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
    // 603（booked）以前漏了 statusLabel ⇒ 队列页兜底用本地 appointmentStatusText 渲染成「待就诊」，
    // 而真实服务端 visitStatusLabel(booked) 是「已挂号」—— 演示与线上文案对不上（2026-10-16 在模拟器上实测发现）。
    MockDoctorState.visits[2].statusLabel = '已挂号';
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

    /*
     * 604（已完成）演示改进 3 的修订历史。夹具刻意给**三版**而不是两版 ——
     * 服务端只在 lock/reopen 落版，所以"当前已定稿 + 历史存在"必然是
     *   lock(v1) → reopen(v2，记解锁前那一版) → 医生改完再 lock(v3)
     * 这样一个奇数序列。给两版会造出"当前是草稿"的矛盾状态。
     */
    MockDoctorState.records[604] = MockDoctorState.locked(604, 104);
    const filled604 = MockDoctorState.records[604].sections;
    MockDoctorState.records[604].updatedAt = nowSec - 3000;
    // v1：最初定稿（当时还没补过敏史）
    const v1Sections: EmrSection[] = [];
    for (const section of filled604) {
      v1Sections.push(section.key === 'allergy_history' ?
        MockDoctorState.section(section.key, section.label, '', section.maxLen, section.requiredToLock) :
        MockDoctorState.section(section.key, section.label, section.value, section.maxLen,
          section.requiredToLock));
    }
    MockDoctorState.revisions[604] = [
      MockDoctorState.revision(1, 'lock', '', 22, 'doctor', nowSec - 5400, v1Sections),
      // v2：管理员解锁。快照内容与 v1 相同（记录的是"解锁前那一版"），差别只在 operation + reason。
      MockDoctorState.revision(2, 'reopen', '患者要求补充过敏史，解锁重写', 1, 'admin',
        nowSec - 4200, v1Sections),
      // v3：改完再定稿 —— 这就是 v2→v3 对比里会标红的那一段。
      MockDoctorState.revision(3, 'lock', '', 22, 'doctor', nowSec - 3000, filled604)
    ];
    MockDoctorState.records[604].revisionVersion = 3;

    // 既往病历夹具：患者 101 更早就诊、已定稿的两张单（不在今日队列里）。
    MockDoctorState.historical = [
      MockDoctorState.historicalRecord(590, 101, '2026-09-02', 'AM', '内科', '李明', '主任医师',
        '间断咳嗽 2 周', '慢性支气管炎急性发作', '阿莫西林 0.5g tid × 5 天'),
      MockDoctorState.historicalRecord(591, 101, '2026-09-20', 'PM', '内科', '李明', '主任医师',
        '咳嗽加重伴气促 3 天', '支气管哮喘（轻度持续）', '布地奈德吸入剂，2 周后复诊')
    ];
  }

  private static historicalRecord(appointmentId: number, patientId: number, visitDate: string,
    period: string, departmentName: string, doctorName: string, doctorTitle: string, chief: string,
    diagnosis: string, treatment: string): PastRecord {
    const record = MockDoctorState.skeleton(appointmentId, patientId);
    record.status = 'locked';
    record.locked = true;
    record.complete = true;
    record.updatedAt = Math.floor(new Date(`${visitDate}T10:00:00`).getTime() / 1000);
    record.createdAt = record.updatedAt;
    record.updatedBy = 22;
    // 只填能看出"当时写了什么"的几段，其余留空 —— 空段也要在，语义是"当时没写"。
    record.sections = [
      MockDoctorState.section('chief_complaint', '主诉', chief, 2000, false),
      MockDoctorState.section('present_illness', '现病史', '', 4000, false),
      MockDoctorState.section('past_history', '既往史', '', 2000, false),
      MockDoctorState.section('allergy_history', '过敏史', '青霉素过敏', 2000, false),
      MockDoctorState.section('physical_exam', '体格检查', '', 2000, false),
      MockDoctorState.section('diagnosis', '诊断', diagnosis, 2000, true),
      MockDoctorState.section('treatment', '处理意见', treatment, 4000, true)
    ];
    record.filled = MockDoctorRepository.countFilled(record);
    // 就诊上下文（服务端 putVisitContext 补的字段）。患者标识由 skeleton 从同一份
    // Mock 患者表带入，保持队列、病历、既往病历三处一致。
    const past = new PastRecord();
    past.record = record;
    past.departmentId = 3;
    past.visitDate = visitDate;
    past.period = period;
    past.departmentName = departmentName;
    past.doctorName = doctorName;
    past.doctorTitle = doctorTitle;
    return past;
  }

  static revision(version: number, operation: string, reason: string, operatorUserId: number,
    operatorRole: string, createdAt: number, sections: EmrSection[]): MockRevision {
    const result = new MockRevision();
    result.version = version;
    result.status = 'locked';
    result.operation = operation;
    result.reason = reason;
    result.operatorUserId = operatorUserId;
    result.operatorRole = operatorRole;
    result.createdAt = createdAt;
    // 快照要深拷贝：修订是"当时的样子"，不能被后来的编辑顺着引用改掉。
    const copied: EmrSection[] = [];
    for (const section of sections) {
      copied.push(MockDoctorState.section(section.key, section.label, section.value, section.maxLen,
        section.requiredToLock));
    }
    result.sections = copied;
    return result;
  }

  // 已定稿（七段填满）的病历夹具。
  private static locked(appointmentId: number, patientId: number): EmrRecord {
    const result = MockDoctorState.skeleton(appointmentId, patientId);
    result.status = 'locked';
    result.locked = true;
    result.complete = true;
    result.filled = 7;
    result.sections = [
      MockDoctorState.section('chief_complaint', '主诉', '反复咳嗽、咳痰 10 年，加重 1 周', 2000, false),
      MockDoctorState.section('present_illness', '现病史',
        '10 年来每于受凉后咳嗽、咳白痰，1 周前再发，夜间为著，无咯血、无胸痛。', 4000, false),
      MockDoctorState.section('past_history', '既往史', '高血压 5 年，规律服药。', 2000, false),
      MockDoctorState.section('allergy_history', '过敏史', '青霉素过敏。', 2000, false),
      MockDoctorState.section('physical_exam', '体格检查',
        '双肺可闻及散在干湿性啰音，心率 78 次/分，律齐。', 2000, false),
      MockDoctorState.section('diagnosis', '诊断', '慢性支气管炎急性发作', 2000, true),
      MockDoctorState.section('treatment', '处理意见',
        '抗感染、祛痰对症；1 周后门诊复查，症状加重随时就诊。', 4000, true)
    ];
    return result;
  }

  private static visit(appointmentId: number, patientId: number, visitDate: string, period: string,
    seqNo: number, status: string, recordStatus: string, recordFilled: number): VisitItem {
    const result = new VisitItem();
    result.appointmentId = appointmentId;
    result.patientId = patientId;
    result.patientName = MockDoctorState.patientNameOf(patientId);
    result.patientGender = MockDoctorState.patientGenderOf(patientId);
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
    result.patientName = MockDoctorState.patientNameOf(patientId);
    result.patientGender = MockDoctorState.patientGenderOf(patientId);
    result.doctorId = 9;
    result.status = 'none';
    result.locked = false;
    result.filled = 0;
    result.totalSections = 7;
    result.complete = false;
    return result;
  }

  private static patientNameOf(patientId: number): string {
    if (patientId === 101) {
      return '张伟';
    }
    if (patientId === 102) {
      return '李娜';
    }
    if (patientId === 103) {
      return '王强';
    }
    if (patientId === 104) {
      return '赵敏';
    }
    return '';
  }

  private static patientGenderOf(patientId: number): string {
    if (patientId === 101 || patientId === 103) {
      return 'M';
    }
    if (patientId === 102 || patientId === 104) {
      return 'F';
    }
    return '';
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
      throw new ApiError(ErrorCode.PREVISIT_NOT_FOUND, '该患者没有可用的预问诊摘要', 404);
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

  /*
   * 保存草稿。服务端的乐观锁语义（§5.30.2）在这里必须**一模一样**，否则
   * "演示全绿、真机 409"：
   *   ① 已定稿优先于冲突（domain_emr 先判 isLocked，再比 updated_at）；
   *   ② `expectedUpdatedAt <= 0` ⇒ 不校验（首次保存时还没有"当前版本"可比）；
   *   ③ 草稿 PUT **不落修订版本**（否则一个上午能刷出几百版，历史变噪声）。
   */
  /*
   * **仅 Mock 的演示开关**：把库里的 `updated_at` 往前挪一秒，制造"病历被另一端改过"。
   *
   * 为什么需要它：单机 Mock 里没有第二个写入者，而客户端保存时是拿**自己的**基准去比的
   * （每次保存后又用响应刷新基准），所以 409 `EMR_CHANGED` 这条完全正确的分支在 Mock 下
   * 永远走不到 —— 一条"演示不到、真机才炸"的路径等于没写。真实竞态只能由真并发产生，
   * 所以这里只做演示用途，且**只在 Mock 模式暴露**（调用方 DoctorRepository 在 live 下不转发）。
   */
  static simulateConcurrentEdit(appointmentId: number): void {
    MockDoctorState.initialize();
    const record = MockDoctorState.records[appointmentId];
    if (record === undefined) {
      return;
    }
    record.updatedAt = record.updatedAt - 1;
    // 改的是一个"别人"：让提示里的 operator 与医生自己（22）分得开。
    record.updatedBy = 1;
  }

  static async saveDraft(appointmentId: number, sections: Record<string, string>,
    expectedUpdatedAt: number = 0): Promise<EmrRecord> {
    MockDoctorState.initialize();
    const record = await MockDoctorRepository.getRecord(appointmentId);
    if (record.locked) {
      // 先讲最要紧的事：要回 EMR_CHANGED 会让客户端以为"重读版本再写就行"，
      // 而实际得先去调解锁。
      throw new ApiError(ErrorCode.EMR_LOCKED, '病历已定稿，需管理员解锁后才能修改', 409);
    }
    if (expectedUpdatedAt > 0 && record.updatedAt !== expectedUpdatedAt) {
      /*
       * 服务端这里下发的是**数字**（updated_at / updated_by / record_id），
       * 而 `ApiError.fields` 的声明类型是 Record<string, string> —— HttpClient 只是
       * 未校验的类型断言，运行时数字原样透传。Mock 故意给**字符串**：让客户端的
       * 解析器两种都吃得下，因为真实世界这两种都会遇到（还有整个 fields 缺席的情况）。
       * `record_id` 也可能缺席（TOCTOU 分支不设它），这里先按"齐全"给。
       */
      const fields: Record<string, string> = {
        'updated_at': `${record.updatedAt}`,
        'updated_by': `${record.updatedBy}`,
        'record_id': `${record.id}`
      };
      throw new ApiError(ErrorCode.EMR_CHANGED, '病历已被他人修改，请重新加载', 409, fields);
    }
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
    record.updatedBy = 22;
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
    if (target.locked) {
      // 服务端的幂等分支：已锁定再提交不报错，自愈并回填版本号（§5.29.6）。
      // 所以 `revision_version = 0` 绝不能当失败重试 —— 重试会走这条路。
      return target;
    }
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
    target.updatedBy = 22;
    // 每次定稿落一版。版本号是**稀疏**的语义 —— 记的是"定稿过几次"，不是"保存过几次"。
    const list = MockDoctorRepository.revisionList(appointmentId);
    const nextVersion = list.length + 1;
    list.push(MockDoctorState.revision(nextVersion, 'lock', '', 22, 'doctor', target.updatedAt,
      target.sections));
    MockDoctorState.revisions[appointmentId] = list;
    target.revisionVersion = nextVersion;
    MockDoctorState.records[appointmentId] = target;
    MockDoctorRepository.syncVisit(appointmentId, 'locked', target.filled);
    return target;
  }

  /*
   * 该患者的既往已定稿病历（§5.30.1）。
   * 放行条件是"该医生本人接诊过这位患者"；mock 里医生 9 看过 101–104。
   * 不满足时回 404 而不是 403 —— 刻意的隐私边界，不暴露"这位患者是否存在"的枚举面。
   */
  static async getPatientRecords(patientId: number, limit: number = 5,
    excludeAppointmentId: number = 0): Promise<PastRecord[]> {
    MockDoctorState.initialize();
    if (patientId <= 0) {
      throw new ApiError(ErrorCode.VALIDATION_FAILED, '患者 id 必须是正整数', 400);
    }
    if (MockDoctorRepository.treatedPatientIds().indexOf(patientId) < 0) {
      throw new ApiError(ErrorCode.APPOINTMENT_NOT_FOUND, '该患者不在你的接诊记录中', 404);
    }
    // limit 非法时服务端**回落 5**（不报 400），客户端照抄这个脾气。
    const effectiveLimit = limit > 0 && limit <= 20 ? limit : 5;
    const result: PastRecord[] = [];
    for (const past of MockDoctorState.historical) {
      if (past.record.patientId !== patientId) {
        continue;
      }
      if (past.record.appointmentId === excludeAppointmentId) {
        continue;
      }
      result.push(past);
      if (result.length >= effectiveLimit) {
        return result;
      }
    }
    // 今日队列里已定稿的单也算"既往"（只出 locked：草稿是医生个人的工作稿，不给别人看）。
    for (const item of MockDoctorState.visits) {
      if (item.patientId !== patientId || item.appointmentId === excludeAppointmentId) {
        continue;
      }
      const record = MockDoctorState.records[item.appointmentId];
      if (record === undefined || !record.locked) {
        continue;
      }
      const past = new PastRecord();
      past.record = record;
      past.departmentId = item.departmentId;
      past.visitDate = item.visitDate;
      past.period = item.period;
      past.departmentName = '内科';
      past.doctorName = '李明';
      past.doctorTitle = '主任医师';
      result.push(past);
      if (result.length >= effectiveLimit) {
        break;
      }
    }
    // 接诊过、但一条已定稿病历都没有 ⇒ 空数组，**不是 404**。
    return result;
  }

  // 修订列表（**升序**，v1 在前，§5.29.2）。列表不含正文，要正文得再取详情。
  static async getRevisions(appointmentId: number): Promise<RevisionItem[]> {
    MockDoctorState.initialize();
    MockDoctorRepository.requireOwnVisit(appointmentId);
    const result: RevisionItem[] = [];
    for (const revision of MockDoctorRepository.revisionList(appointmentId)) {
      result.push(MockDoctorRepository.revisionItemOf(revision));
    }
    return result;
  }

  // 某一版详情（§5.29.3）。取不到 ⇒ 404 REVISION_NOT_FOUND，**不是**空对象 ——
  // 空对象会让客户端渲染出"七段全空"的假版本，看起来像病历被清空了。
  static async getRevision(appointmentId: number, version: number): Promise<RevisionDetail> {
    MockDoctorState.initialize();
    MockDoctorRepository.requireOwnVisit(appointmentId);
    if (version <= 0) {
      throw new ApiError(ErrorCode.VALIDATION_FAILED, '版本号必须是正整数（第一版是 1）', 400);
    }
    const found = MockDoctorRepository.findRevision(appointmentId, version);
    if (found === undefined) {
      throw new ApiError(ErrorCode.REVISION_NOT_FOUND, '该病历没有这一版修订', 404);
    }
    const result = new RevisionDetail();
    MockDoctorRepository.fillRevisionItem(result, found);
    // mock 以 appointmentId 当作病历 id（见 MockDoctorState.skeleton），所以两者相等 ——
    // 真机上 record_id 是病历表的自增主键，与挂号单号无关，别照抄这个巧合。
    result.recordId = appointmentId;
    result.appointmentId = appointmentId;
    const sections: EmrSection[] = [];
    for (const section of found.sections) {
      sections.push(MockDoctorState.section(section.key, section.label, section.value, section.maxLen,
        section.requiredToLock));
    }
    result.sections = sections;
    return result;
  }

  /*
   * 两版逐段对比（§5.29.4）。`against <= 0` 时取 `version - 1`；而 v1 没有上一版 ⇒
   * 400 VALIDATION_FAILED（刻意不退化成"拿 v1 跟自己比"—— 那会返回"一切未变"这个
   * 看起来成功的错答案）。`changed` 只由服务端判定，客户端不得自己比 left/right。
   */
  static async getRevisionDiff(appointmentId: number, version: number,
    against: number = 0): Promise<RevisionDiff> {
    MockDoctorState.initialize();
    MockDoctorRepository.requireOwnVisit(appointmentId);
    if (version <= 0) {
      throw new ApiError(ErrorCode.VALIDATION_FAILED, '版本号必须是正整数（第一版是 1）', 400);
    }
    const effectiveAgainst = against > 0 ? against : version - 1;
    if (effectiveAgainst <= 0 || effectiveAgainst === version) {
      throw new ApiError(ErrorCode.VALIDATION_FAILED,
        '要对比的版本号非法（第一版没有上一版，必须显式指定 against）', 400);
    }
    const left = MockDoctorRepository.findRevision(appointmentId, effectiveAgainst);
    if (left === undefined) {
      throw new ApiError(ErrorCode.REVISION_NOT_FOUND, '要对比的那一版不存在', 404);
    }
    const right = MockDoctorRepository.findRevision(appointmentId, version);
    if (right === undefined) {
      throw new ApiError(ErrorCode.REVISION_NOT_FOUND, '该病历没有这一版修订', 404);
    }
    const result = new RevisionDiff();
    result.appointmentId = appointmentId;
    result.left = MockDoctorRepository.revisionItemOf(left);
    result.right = MockDoctorRepository.revisionItemOf(right);
    result.statusChanged = left.status !== right.status;
    const sections: RevisionDiffSection[] = [];
    let changedCount = 0;
    for (const section of right.sections) {
      const row = new RevisionDiffSection();
      row.key = section.key;
      row.label = section.label;
      row.left = MockDoctorRepository.valueOf(left, section.key);
      row.right = section.value;
      row.changed = row.left !== row.right;
      if (row.changed) {
        changedCount++;
      }
      sections.push(row);
    }
    result.sections = sections;
    result.changedCount = changedCount;
    return result;
  }

  private static revisionList(appointmentId: number): MockRevision[] {
    const existing = MockDoctorState.revisions[appointmentId];
    return existing === undefined ? [] : existing;
  }

  private static findRevision(appointmentId: number, version: number): MockRevision | undefined {
    for (const revision of MockDoctorRepository.revisionList(appointmentId)) {
      if (revision.version === version) {
        return revision;
      }
    }
    return undefined;
  }

  private static valueOf(revision: MockRevision, key: string): string {
    for (const section of revision.sections) {
      if (section.key === key) {
        return section.value;
      }
    }
    return '';
  }

  private static revisionItemOf(revision: MockRevision): RevisionItem {
    const result = new RevisionItem();
    MockDoctorRepository.fillRevisionItem(result, revision);
    return result;
  }

  private static fillRevisionItem(target: RevisionItem, source: MockRevision): void {
    target.version = source.version;
    target.status = source.status;
    target.operation = source.operation;
    target.reason = source.reason;
    target.operatorUserId = source.operatorUserId;
    target.operatorRole = source.operatorRole;
    target.createdAt = source.createdAt;
  }

  private static requireOwnVisit(appointmentId: number): VisitItem {
    // 复用 find 的 404 语义：不是我的号 / 挂号单不存在。
    return MockDoctorRepository.find(appointmentId);
  }

  private static treatedPatientIds(): number[] {
    const result: number[] = [];
    for (const item of MockDoctorState.visits) {
      if (result.indexOf(item.patientId) < 0) {
        result.push(item.patientId);
      }
    }
    for (const past of MockDoctorState.historical) {
      if (result.indexOf(past.record.patientId) < 0) {
        result.push(past.record.patientId);
      }
    }
    return result;
  }

  private static find(appointmentId: number): VisitItem {
    for (const item of MockDoctorState.visits) {
      if (item.appointmentId === appointmentId) {
        return item;
      }
    }
    throw new ApiError(ErrorCode.APPOINTMENT_NOT_FOUND, '挂号单不存在或不属于你', 404);
  }

  // 非 private：MockDoctorState 的夹具工厂要复用它（私有静态成员不能被类外访问，
  // ArkTS 编译期直接报错），理由同上面的 skeleton/section。
  static countFilled(record: EmrRecord): number {
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
