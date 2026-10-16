import {
  ApiConfig,
  HttpClient,
  asArray,
  asBool,
  asNumber,
  asRecord,
  asString
} from 'common-core';
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

  /*
   * ⚠ 2026-10-16（复核 D3）：服务端在改进 6 里把状态机收窄成
   *   `booked → arrived → waiting → visiting → done`，`start` 只接受 waiting。
   *   此前客户端只有 startVisit，于是"开始接诊"按钮对着 booked 的单按下去必然 409
   *   VISIT_BAD_STATE —— 医生端主流程整个走不通。这两个方法就是缺失的前两步。
   */
  async arriveVisit(appointmentId: number): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.arriveVisit(appointmentId);
    }
    const body: Record<string, Object> = {};
    await HttpClient.getInstance().post(`/api/v1/doctor/visits/${appointmentId}/arrive`, body);
  }

  async waitingVisit(appointmentId: number): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.waitingVisit(appointmentId);
    }
    const body: Record<string, Object> = {};
    await HttpClient.getInstance().post(`/api/v1/doctor/visits/${appointmentId}/waiting`, body);
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

  /*
   * 保存草稿（幂等；重复同内容不落修订版本，可放心高频调用）。
   * `expectedUpdatedAt` = 上一次响应里的 `updated_at`，服务端拿它做乐观锁：
   *   与库里不一致 ⇒ 409 EMR_CHANGED（冲突详情在 error.fields，见 §5.30.2）。
   * ⚠ 契约要求该字段是**整数**：值不是整数会直接 400。所以这里只在 >0 时才带上 ——
   *   `0` 的语义本来就是"不校验"（首次保存时还没有"当前版本"可比），
   *   带上去不如不带，少一个被服务端解析器挑刺的机会。
   */
  async saveDraft(appointmentId: number, sections: Record<string, string>,
    useIntakeSession: string = '', expectedUpdatedAt: number = 0): Promise<EmrRecord> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.saveDraft(appointmentId, sections, expectedUpdatedAt);
    }
    const body: Record<string, Object> = {};
    const keys = Object.keys(sections);
    for (const key of keys) {
      body[key] = sections[key];
    }
    if (useIntakeSession.length > 0) {
      body['use_intake_session'] = useIntakeSession;
    }
    if (expectedUpdatedAt > 0) {
      body['expected_updated_at'] = expectedUpdatedAt;
    }
    const response = asRecord(await HttpClient.getInstance()
      .put(`/api/v1/doctor/visits/${appointmentId}/record`, body));
    return this.parseRecord(response);
  }

  /*
   * **仅 Mock 的演示开关**（见 MockDoctorRepository.simulateConcurrentEdit）：
   * 制造一次"病历被另一端改过"，好在单机上走通 409 EMR_CHANGED 的核对流程。
   * live 模式下是**空操作** —— 真实竞态只能由真并发产生，没有"模拟"一说，
   * 更不能在真机上悄悄改数据。
   */
  async simulateConcurrentEdit(appointmentId: number): Promise<void> {
    if (ApiConfig.isMock()) {
      MockDoctorRepository.simulateConcurrentEdit(appointmentId);
    }
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

  async logout(): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.logout();
    }
    const body: Record<string, Object> = {};
    await HttpClient.getInstance().post('/api/v1/auth/logout', body);
  }

  // 读该单的预问诊摘要（服务端 2026-10-14 新增；仅医生，且必须是「我的号」）。
  async getPrevisit(appointmentId: number): Promise<PrevisitSummary> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.getPrevisit(appointmentId);
    }
    const response = asRecord(await HttpClient.getInstance()
      .get(`/api/v1/doctor/visits/${appointmentId}/previsit`));
    const result = new PrevisitSummary();
    result.sessionId = asString(response['session_id']);
    result.bound = asBool(response['bound']);
    result.turn = asNumber(response['turn']);
    result.completed = asBool(response['completed']);
    result.filled = asNumber(response['filled']);
    result.total = asNumber(response['total'], 6);
    result.capturedAt = asNumber(response['captured_at']);
    const sections: PrevisitSlot[] = [];
    for (const item of asArray(response['sections'])) {
      const source = asRecord(item);
      const slot = new PrevisitSlot();
      slot.key = asString(source['key']);
      slot.label = asString(source['label']);
      slot.value = asString(source['value']);
      slot.maxLen = asNumber(source['max_len']);
      sections.push(slot);
    }
    result.sections = sections;
    return result;
  }

  /*
   * 该患者的既往已定稿病历（改进 2，§5.30.1）。医生端"同屏看本次 + 既往"用的就是它。
   * - `limit` 非法/超 20 时服务端**回落 5**（不报 400），所以这里不必做本地校验。
   * - `excludeAppointmentId` 排除本次（否则既往列表里会混进正在编辑的这张草稿单）。
   * - 该医生没接诊过这位患者 ⇒ 404 APPOINTMENT_NOT_FOUND（刻意的隐私边界：不区分 403，
   *   避免"这位患者是否看过病"的枚举面）。这是**正常态**，调用方静默即可。
   */
  async getPatientRecords(patientId: number, limit: number = 5,
    excludeAppointmentId: number = 0): Promise<PastRecord[]> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.getPatientRecords(patientId, limit, excludeAppointmentId);
    }
    const response = asRecord(await HttpClient.getInstance().get(
      `/api/v1/doctor/patients/${patientId}/records?limit=${limit}` +
      `&exclude_appointment_id=${excludeAppointmentId}`));
    const result: PastRecord[] = [];
    for (const item of asArray(response['items'])) {
      const source = asRecord(item);
      const past = new PastRecord();
      past.record = this.parseRecord(source);
      past.departmentId = asNumber(source['department_id']);
      past.visitDate = asString(source['visit_date']);
      past.period = asString(source['period']);
      past.departmentName = asString(source['department_name']);
      past.doctorName = asString(source['doctor_name']);
      past.doctorTitle = asString(source['doctor_title']);
      result.push(past);
    }
    return result;
  }

  /*
   * 病历修订历史（改进 3，§5.29.2）：**按 version 升序**（v1 在前），
   * 列表**不含 sections 正文**，要正文得再取详情。要"最新在上"由调用方自己反转 ——
   * 别指望服务端给两种顺序。
   */
  async getRevisions(appointmentId: number): Promise<RevisionItem[]> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.getRevisions(appointmentId);
    }
    const response = asRecord(await HttpClient.getInstance()
      .get(`/api/v1/doctor/visits/${appointmentId}/record/revisions`));
    const result: RevisionItem[] = [];
    for (const item of asArray(response['items'])) {
      result.push(this.parseRevisionItem(asRecord(item)));
    }
    return result;
  }

  // 某一版详情（§5.29.3）。取不到的版本是 404 REVISION_NOT_FOUND，不是空对象。
  async getRevision(appointmentId: number, version: number): Promise<RevisionDetail> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.getRevision(appointmentId, version);
    }
    const response = asRecord(await HttpClient.getInstance()
      .get(`/api/v1/doctor/visits/${appointmentId}/record/revisions/${version}`));
    const result = new RevisionDetail();
    this.fillRevisionItem(result, response);
    result.recordId = asNumber(response['record_id']);
    result.appointmentId = asNumber(response['appointment_id']);
    const sections: EmrSection[] = [];
    // 修订版的 sections 与病历同形状但**没有 required_to_lock** —— 少读一个字段，
    // 不要因此把段标成必填。
    for (const item of asArray(response['sections'])) {
      const source = asRecord(item);
      const section = new EmrSection();
      section.key = asString(source['key']);
      section.label = asString(source['label']);
      section.value = asString(source['value']);
      section.maxLen = asNumber(source['max_len']);
      sections.push(section);
    }
    result.sections = sections;
    return result;
  }

  /*
   * 两版逐段对比（§5.29.4）。`against` 缺省时服务端取 `version - 1`，而
   * **v1 没有上一版 ⇒ 400 VALIDATION_FAILED**（刻意不退化成"拿 v1 跟自己比"）。
   * 所以这里同样只在 against > 0 时才带参数，调用方对 v1 应当不给"对比上一版"入口。
   * `changed` 由服务端逐字符判定，客户端**不得**自己比 left/right 重算。
   */
  async getRevisionDiff(appointmentId: number, version: number,
    against: number = 0): Promise<RevisionDiff> {
    if (ApiConfig.isMock()) {
      return MockDoctorRepository.getRevisionDiff(appointmentId, version, against);
    }
    const query = against > 0 ? `?against=${against}` : '';
    const response = asRecord(await HttpClient.getInstance()
      .get(`/api/v1/doctor/visits/${appointmentId}/record/revisions/${version}/diff${query}`));
    const result = new RevisionDiff();
    result.appointmentId = asNumber(response['appointment_id']);
    result.left = this.parseRevisionItem(asRecord(response['left']));
    result.right = this.parseRevisionItem(asRecord(response['right']));
    result.statusChanged = asBool(response['status_changed']);
    result.changedCount = asNumber(response['changed_count']);
    const sections: RevisionDiffSection[] = [];
    for (const item of asArray(response['sections'])) {
      const source = asRecord(item);
      const section = new RevisionDiffSection();
      section.key = asString(source['key']);
      section.label = asString(source['label']);
      section.changed = asBool(source['changed']);
      section.left = asString(source['left']);
      section.right = asString(source['right']);
      sections.push(section);
    }
    result.sections = sections;
    return result;
  }

  private parseRevisionItem(response: Record<string, Object>): RevisionItem {
    const result = new RevisionItem();
    this.fillRevisionItem(result, response);
    return result;
  }

  private fillRevisionItem(target: RevisionItem, response: Record<string, Object>): void {
    target.version = asNumber(response['version']);
    target.status = asString(response['status']);
    target.operation = asString(response['operation']);
    target.reason = asString(response['reason']);
    target.operatorUserId = asNumber(response['operator_user_id']);
    // 空串 = 未知（存量补录那一版），**不是**"没有权限"—— UI 别渲染成空白。
    target.operatorRole = asString(response['operator_role']);
    target.createdAt = asNumber(response['created_at']);
  }

  private parseVisit(response: Record<string, Object>): VisitItem {
    const result = new VisitItem();
    result.appointmentId = asNumber(response['appointment_id']);
    result.patientId = asNumber(response['patient_id']);
    result.patientName = asString(response['patient_name']);
    result.patientGender = asString(response['patient_gender']);
    result.doctorId = asNumber(response['doctor_id']);
    result.departmentId = asNumber(response['department_id']);
    result.visitDate = asString(response['visit_date']);
    result.period = asString(response['period']);
    result.seqNo = asNumber(response['seq_no']);
    result.status = asString(response['status']);
    result.visitStatus = asString(response['visit_status'], result.status);
    // 服务端从改进 6 起同时下发人话标签与三个时间戳（0 = 这一步还没发生）。
    // 解析它们而不是在客户端再写一份映射：中文名只该有一份权威实现（服务端）。
    result.statusLabel = asString(response['status_label'], '');
    result.arrivedAt = asNumber(response['arrived_at']);
    result.startedAt = asNumber(response['started_at']);
    result.finishedAt = asNumber(response['finished_at']);
    result.previsitReady = asBool(response['previsit_ready']);
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
    result.patientName = asString(response['patient_name']);
    result.patientGender = asString(response['patient_gender']);
    result.doctorId = asNumber(response['doctor_id']);
    result.status = asString(response['status'], 'none');
    result.locked = asBool(response['locked']);
    result.filled = asNumber(response['filled']);
    result.totalSections = asNumber(response['total_sections'], 7);
    result.complete = asBool(response['complete']);
    result.updatedBy = asNumber(response['updated_by']);
    result.createdAt = asNumber(response['created_at']);
    result.updatedAt = asNumber(response['updated_at']);
    // 只在 lock/reopen 的成功响应里存在；0 = 审计行没写上（病历动作本身已成功，不是失败）。
    result.revisionVersion = asNumber(response['revision_version']);
    const missing: string[] = [];
    for (const value of asArray(response['missing_required'])) {
      missing.push(asString(value));
    }
    result.missingRequired = missing;
    // 预问诊来源痕迹：只在服务端确实下发该字段时才解析（缺失 = 没有预填过）。
    const previsitRef = asRecord(response['previsit_ref']);
    if (Object.keys(previsitRef).length > 0) {
      result.previsitRefSessionId = asString(previsitRef['session_id']);
      result.previsitRefAt = asNumber(previsitRef['at']);
      const refSections: string[] = [];
      for (const value of asArray(previsitRef['sections'])) {
        refSections.push(asString(value));
      }
      result.previsitRefSections = refSections;
    }
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
