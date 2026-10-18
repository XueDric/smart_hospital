import {
  ApiConfig,
  ApiError,
  HttpClient,
  asArray,
  asBool,
  asNumber,
  asRecord,
  asString
} from 'common-core';
import {
  AdminLoginResult,
  AdminUser,
  AiPrompt,
  AiSetting,
  AiTool,
  Dashboard,
  Department,
  Doctor,
  KbDoc,
  LabelCount,
  Schedule,
  TrendPoint
} from '../model/AdminModels';
import { MockAdminRepository } from './MockAdminRepository';

export class AdminRepository {
  private static instance: AdminRepository = new AdminRepository();

  static getInstance(): AdminRepository {
    return AdminRepository.instance;
  }

  async login(loginName: string, password: string): Promise<AdminLoginResult> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.login(loginName, password);
    }
    const body: Record<string, Object> = {
      'login_name': loginName,
      'password': password
    };
    const response = asRecord(await HttpClient.getInstance().post('/api/v1/auth/login', body, false));
    const result = new AdminLoginResult();
    result.token = asString(response['token']);
    result.expiresAt = asNumber(response['expires_at']);
    result.userId = asNumber(response['user_id']);
    result.role = asString(response['role']);
    result.refId = asNumber(response['ref_id']);
    result.displayName = asString(response['display_name']);
    return result;
  }

  /*
   * ★ 2026-10-17 复查：管理端登出原来只清本地，服务端令牌继续有效到 TTL ——
   * "登出"只登出了一半。这里补上服务端注销；401 视为"已经登出"，其它错误上抛。
   */
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

  async dashboard(): Promise<Dashboard> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.dashboard();
    }
    const response = asRecord(await HttpClient.getInstance().get('/api/v1/admin/dashboard'));
    return this.parseDashboard(response);
  }

  async departments(): Promise<Department[]> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.departments();
    }
    const response = asRecord(await HttpClient.getInstance().get('/api/v1/admin/departments'));
    const result: Department[] = [];
    for (const item of asArray(response['items'])) {
      result.push(this.parseDepartment(asRecord(item)));
    }
    return result;
  }

  async createDepartment(body: Record<string, Object>): Promise<Department> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.createDepartment(body);
    }
    return this.parseDepartment(asRecord(await HttpClient.getInstance()
      .post('/api/v1/admin/departments', body)));
  }

  async updateDepartment(id: number, body: Record<string, Object>): Promise<Department> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.updateDepartment(id, body);
    }
    return this.parseDepartment(asRecord(await HttpClient.getInstance()
      .put(`/api/v1/admin/departments/${id}`, body)));
  }

  async deleteDepartment(id: number): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.deleteDepartment(id);
    }
    await HttpClient.getInstance().delete(`/api/v1/admin/departments/${id}?force=true`);
  }

  async doctors(): Promise<Doctor[]> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.doctors();
    }
    const response = asRecord(await HttpClient.getInstance().get('/api/v1/admin/doctors'));
    const result: Doctor[] = [];
    for (const item of asArray(response['items'])) {
      result.push(this.parseDoctor(asRecord(item)));
    }
    return result;
  }

  async createDoctor(body: Record<string, Object>): Promise<Doctor> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.createDoctor(body);
    }
    return this.parseDoctor(asRecord(await HttpClient.getInstance()
      .post('/api/v1/admin/doctors', body)));
  }

  async updateDoctor(id: number, body: Record<string, Object>): Promise<Doctor> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.updateDoctor(id, body);
    }
    return this.parseDoctor(asRecord(await HttpClient.getInstance()
      .put(`/api/v1/admin/doctors/${id}`, body)));
  }

  async deleteDoctor(id: number): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.deleteDoctor(id);
    }
    await HttpClient.getInstance().delete(`/api/v1/admin/doctors/${id}`);
  }

  async schedules(): Promise<Schedule[]> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.schedules();
    }
    const response = asRecord(await HttpClient.getInstance().get('/api/v1/schedules'));
    const result: Schedule[] = [];
    for (const item of asArray(response['schedules'])) {
      result.push(this.parseSchedule(asRecord(item)));
    }
    return result;
  }

  async createSchedule(body: Record<string, Object>): Promise<Schedule> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.createSchedule(body);
    }
    return this.parseSchedule(asRecord(await HttpClient.getInstance()
      .post('/api/v1/admin/schedules', body)));
  }

  async users(loginName: string = ''): Promise<AdminUser[]> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.users();
    }
    const query = loginName.length > 0 ? `?login_name=${encodeURIComponent(loginName)}` : '';
    const response = asRecord(await HttpClient.getInstance().get(`/api/v1/admin/users${query}`));
    const result: AdminUser[] = [];
    for (const item of asArray(response['items'])) {
      result.push(this.parseUser(asRecord(item)));
    }
    return result;
  }

  async createUser(body: Record<string, Object>): Promise<AdminUser> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.createUser(body);
    }
    return this.parseUser(asRecord(await HttpClient.getInstance()
      .post('/api/v1/admin/users', body)));
  }

  async resetPassword(id: number, password: string): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.resetPassword(id, password);
    }
    const body: Record<string, Object> = { 'password': password };
    await HttpClient.getInstance().post(`/api/v1/admin/users/${id}/password`, body);
  }

  async aiSettings(): Promise<AiSetting[]> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.aiSettings();
    }
    const response = asRecord(await HttpClient.getInstance().get('/api/v1/admin/ai/settings'));
    const result: AiSetting[] = [];
    for (const item of asArray(response['items'])) {
      result.push(this.parseAiSetting(asRecord(item)));
    }
    return result;
  }

  async updateAiSetting(key: string, value: string): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.updateAiSetting(key, value);
    }
    const body: Record<string, Object> = { 'value': value };
    await HttpClient.getInstance().put(`/api/v1/admin/ai/settings/${key}`, body);
  }

  async aiPrompts(): Promise<AiPrompt[]> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.aiPrompts();
    }
    const response = asRecord(await HttpClient.getInstance().get('/api/v1/admin/ai/prompts'));
    const result: AiPrompt[] = [];
    for (const item of asArray(response['prompts'])) {
      result.push(this.parseAiPrompt(asRecord(item)));
    }
    return result;
  }

  async updateAiPrompt(name: string, body: string): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.updateAiPrompt(name, body);
    }
    const payload: Record<string, Object> = { 'body': body };
    await HttpClient.getInstance().put(`/api/v1/admin/ai/prompts/${name}`, payload);
  }

  async deleteAiPrompt(name: string): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.deleteAiPrompt(name);
    }
    await HttpClient.getInstance().delete(`/api/v1/admin/ai/prompts/${name}`);
  }

  async aiTools(): Promise<AiTool[]> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.aiTools();
    }
    const response = asRecord(await HttpClient.getInstance().get('/api/v1/admin/ai/tools'));
    const result: AiTool[] = [];
    for (const item of asArray(response['tools'])) {
      result.push(this.parseAiTool(asRecord(item)));
    }
    return result;
  }

  async updateAiTool(name: string, enabled: boolean): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.updateAiTool(name, enabled);
    }
    const body: Record<string, Object> = { 'enabled': enabled };
    await HttpClient.getInstance().put(`/api/v1/admin/ai/tools/${name}`, body);
  }

  async kbDocs(): Promise<KbDoc[]> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.kbDocs();
    }
    const response = asRecord(await HttpClient.getInstance().get('/api/v1/admin/kb/docs'));
    const result: KbDoc[] = [];
    for (const item of asArray(response['items'])) {
      result.push(this.parseKbDoc(asRecord(item)));
    }
    return result;
  }

  async createKbDoc(body: Record<string, Object>): Promise<KbDoc> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.createKbDoc(body);
    }
    return this.parseKbDoc(asRecord(await HttpClient.getInstance()
      .post('/api/v1/admin/kb/docs', body)));
  }

  async updateKbDoc(id: number, body: Record<string, Object>): Promise<KbDoc> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.updateKbDoc(id, body);
    }
    return this.parseKbDoc(asRecord(await HttpClient.getInstance()
      .put(`/api/v1/admin/kb/docs/${id}`, body)));
  }

  async deleteKbDoc(id: number): Promise<void> {
    if (ApiConfig.isMock()) {
      return MockAdminRepository.deleteKbDoc(id);
    }
    await HttpClient.getInstance().delete(`/api/v1/admin/kb/docs/${id}`);
  }

  private parseDashboard(response: Record<string, Object>): Dashboard {
    const result = new Dashboard();
    const scale = asRecord(response['scale']);
    result.departments = asNumber(scale['departments']);
    result.doctors = asNumber(scale['doctors']);
    result.patients = asNumber(scale['patients']);
    const appointments = asRecord(response['appointments']);
    result.appointmentTotal = asNumber(appointments['total']);
    result.appointmentDone = asNumber(appointments['done']);
    result.appointmentNoShow = asNumber(appointments['no_show']);
    result.cancelPermille = asNumber(appointments['cancel_permille']);
    result.noShowPermille = asNumber(appointments['no_show_permille']);
    const trend: TrendPoint[] = [];
    for (const item of asArray(response['trend'])) {
      const source = asRecord(item);
      const point = new TrendPoint();
      point.label = asString(source['label']);
      point.count = asNumber(source['count']);
      trend.push(point);
    }
    result.trend = trend;
    result.trendDays = asNumber(response['trend_days']);
    const byDepartment: LabelCount[] = [];
    for (const item of asArray(response['by_department'])) {
      const source = asRecord(item);
      const entry = new LabelCount();
      entry.label = asString(source['label']);
      entry.count = asNumber(source['count']);
      byDepartment.push(entry);
    }
    result.byDepartment = byDepartment;
    const slots = asRecord(response['slots']);
    result.totalSlots = asNumber(slots['total_slots']);
    result.remainSlots = asNumber(slots['remain_slots']);
    result.scheduleCount = asNumber(slots['schedule_count']);
    result.enabledScheduleCount = asNumber(slots['enabled_schedule_count']);
    result.slotUsagePct = result.totalSlots > 0 ?
      Math.round((result.totalSlots - result.remainSlots) / result.totalSlots * 100) : 0;
    const previsit = asRecord(response['previsit']);
    result.previsitCompletionPct = asNumber(previsit['completion_permille']) > 100 ?
      Math.round(asNumber(previsit['completion_permille']) / 10) : asNumber(previsit['completion_permille']);
    const records = asRecord(response['medical_records']);
    result.recordTotal = asNumber(records['records']);
    result.recordLocked = asNumber(records['locked']);
    result.recordDraft = asNumber(records['draft']);
    result.recordEmpty = asNumber(records['empty']);
    result.lockedPermille = asNumber(records['locked_permille']);
    result.sectionsPerRecord = asNumber(records['sections_per_record']);
    const ai = asRecord(response['ai']);
    result.aiEnabled = asBool(ai['enabled']);
    result.aiModel = asString(ai['model']);
    result.aiToolsEnabled = asNumber(ai['tools_enabled']);
    result.aiToolsTotal = asNumber(ai['tools_total']);
    result.aiPromptsTotal = asNumber(ai['prompts_total']);
    result.aiPromptsCustomized = asNumber(ai['prompts_customized']);
    const knowledgeBase = asRecord(response['knowledge_base']);
    result.kbDocs = asNumber(knowledgeBase['docs']);
    result.kbDocsEnabled = asNumber(knowledgeBase['docs_enabled']);
    result.kbChunks = asNumber(knowledgeBase['chunks']);
    result.kbChunksEmbedded = asNumber(knowledgeBase['chunks_embedded']);
    result.kbEmbeddingCoveragePct = asNumber(knowledgeBase['embedding_coverage_pct']);
    /*
     * ★★ 2026-10-18 三端联调修：这里原本写着 `result.triageHitPct = 0;` ——
     *   一个**写死的 0**。服务端 `/admin/dashboard` 里根本没有命中率字段
     *   （顶层只有 scale / appointments / trend_days / trend / by_department /
     *   slots / triage / previsit / medical_records / ai / knowledge_base），
     *   于是界面上「分诊命中率」永远是 0%（Mock 里却是 73）——典型的假指标，
     *   和评审 P2-7 的「看板硬编码 source=rules」是同一类问题。
     *   现在改为读 `triage.total_calls`（真实计数），卡片标签也改成「分诊调用」，
     *   不再假装有一个算不出来的百分比。
     */
    const triage = asRecord(response['triage']);
    result.triageCalls = asNumber(triage['total_calls']);
    result.triageRedFlagCalls = asNumber(triage['red_flag_calls']);
    return result;
  }

  private parseDepartment(response: Record<string, Object>): Department {
    const result = new Department();
    result.id = asNumber(response['id']);
    result.name = asString(response['name']);
    result.code = asString(response['code']);
    result.location = asString(response['location']);
    result.sort = asNumber(response['sort']);
    result.enabled = asBool(response['enabled'], true);
    result.createdAt = asNumber(response['created_at']);
    return result;
  }

  private parseDoctor(response: Record<string, Object>): Doctor {
    const result = new Doctor();
    result.id = asNumber(response['id']);
    result.name = asString(response['name']);
    result.departmentId = asNumber(response['department_id']);
    result.departmentName = asString(response['department_name']);
    result.title = asString(response['title']);
    result.specialty = asString(response['specialty']);
    result.enabled = asBool(response['enabled'], true);
    result.createdAt = asNumber(response['created_at']);
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
    result.version = asNumber(response['version']);
    result.enabled = asBool(response['enabled'], true);
    result.departmentName = asString(response['department_name']);
    result.doctorName = asString(response['doctor_name']);
    result.doctorTitle = asString(response['doctor_title']);
    return result;
  }

  private parseUser(response: Record<string, Object>): AdminUser {
    const result = new AdminUser();
    result.userId = asNumber(response['user_id']);
    result.loginName = asString(response['login_name']);
    result.role = asString(response['role']);
    result.refId = asNumber(response['ref_id']);
    result.displayName = asString(response['display_name']);
    result.status = asString(response['status']);
    return result;
  }

  private parseAiSetting(response: Record<string, Object>): AiSetting {
    const result = new AiSetting();
    result.key = asString(response['key']);
    result.label = asString(response['label']);
    result.secret = asBool(response['secret']);
    result.refKind = asString(response['ref_kind']);
    result.value = asString(response['value']);
    result.defaultValue = asString(response['default']);
    result.redacted = asBool(response['redacted']);
    result.isDefault = asBool(response['is_default']);
    return result;
  }

  private parseAiPrompt(response: Record<string, Object>): AiPrompt {
    const result = new AiPrompt();
    result.name = asString(response['name']);
    result.label = asString(response['label']);
    const required: string[] = [];
    for (const value of asArray(response['required'])) {
      required.push(asString(value));
    }
    result.required = required;
    result.maxLen = asNumber(response['max_len']);
    result.customized = asBool(response['customized']);
    result.body = asString(response['body']);
    return result;
  }

  private parseAiTool(response: Record<string, Object>): AiTool {
    const result = new AiTool();
    result.name = asString(response['name']);
    result.label = asString(response['label']);
    result.defaultOn = asBool(response['default_on']);
    result.enabled = asBool(response['enabled']);
    return result;
  }

  private parseKbDoc(response: Record<string, Object>): KbDoc {
    const result = new KbDoc();
    result.id = asNumber(response['id']);
    result.title = asString(response['title']);
    result.category = asString(response['category']);
    result.enabled = asBool(response['enabled'], true);
    result.chunkCount = asNumber(response['chunk_count']);
    result.updatedAt = asNumber(response['updated_at']);
    return result;
  }
}
