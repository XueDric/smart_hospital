import { ApiError, ErrorCode } from 'common-core';
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

class MockAdminState {
  static initialized: boolean = false;
  static departments: Department[] = [];
  static doctors: Doctor[] = [];
  static schedules: Schedule[] = [];
  static users: AdminUser[] = [];
  static aiSettings: AiSetting[] = [];
  static aiPrompts: AiPrompt[] = [];
  static aiTools: AiTool[] = [];
  static kbDocs: KbDoc[] = [];
  static nextDepartmentId: number = 10;
  static nextDoctorId: number = 30;
  static nextScheduleId: number = 520;
  static nextDocId: number = 10;

  static initialize(): void {
    if (MockAdminState.initialized) {
      return;
    }
    MockAdminState.initialized = true;
    MockAdminState.departments = [
      MockAdminState.dept(3, '呼吸内科', 'RESP', '门诊楼 3F', 1, true),
      MockAdminState.dept(4, '骨科', 'ORTH', '门诊楼 2F', 2, true),
      MockAdminState.dept(5, '皮肤科', 'DERM', '门诊楼 4F', 3, false),
      MockAdminState.dept(6, '消化内科', 'DIGE', '门诊楼 3F', 4, true)
    ];
    MockAdminState.doctors = [
      MockAdminState.doc(9, '李医生', 3, '呼吸内科', '副主任医师', '慢性咳嗽、哮喘', true),
      MockAdminState.doc(10, '王医生', 3, '呼吸内科', '主治医师', '呼吸系统感染', true),
      MockAdminState.doc(11, '张医生', 4, '骨科', '主治医师', '运动损伤', true),
      MockAdminState.doc(12, '韩医生', 6, '消化内科', '主治医师', '胃肠疾病', true),
      MockAdminState.doc(13, '陈医生', 5, '皮肤科', '主治医师', '皮肤过敏', false)
    ];
    MockAdminState.schedules = [
      MockAdminState.schedule(501, 9, 3, '2026-11-20', 'AM', 20, 5, true),
      MockAdminState.schedule(502, 10, 3, '2026-11-20', 'PM', 16, 0, true),
      MockAdminState.schedule(503, 9, 3, '2026-11-21', 'AM', 20, 11, true),
      MockAdminState.schedule(504, 11, 4, '2026-11-20', 'AM', 18, 4, true),
      MockAdminState.schedule(505, 12, 6, '2026-11-21', 'PM', 18, 8, true)
    ];
    MockAdminState.users = [
      MockAdminState.user(1, 'admin', 'admin', 1, '管理员', 'active'),
      MockAdminState.user(22, 'D1001', 'doctor', 9, '李医生', 'active'),
      MockAdminState.user(40, '13800006021', 'patient', 7, '张三', 'active')
    ];
    MockAdminState.aiSettings = [
      MockAdminState.setting('ai.endpoint', 'AI 接口地址', 'https://api.example.com/v1', false),
      MockAdminState.setting('ai.model', '模型名称', 'deepseek-chat', false),
      MockAdminState.setting('ai.api_key', 'API 密钥', '已设置（引用类型：env）', true)
    ];
    MockAdminState.aiPrompts = [
      MockAdminState.prompt('prompt.triage', '分诊提示词', '含 {complaint} {options} 占位符', true),
      MockAdminState.prompt('prompt.previsit', '预问诊提示词', '含 {slot} {history} 占位符', true)
    ];
    MockAdminState.aiTools = [
      MockAdminState.tool('tool.triage', '智能分诊', true),
      MockAdminState.tool('tool.previsit', '智能预问诊', true),
      MockAdminState.tool('tool.rag', '知识库检索', false)
    ];
    MockAdminState.kbDocs = [
      MockAdminState.doc2(1, '呼吸内科就诊指引', '呼吸内科', true, 18, 1760544000),
      MockAdminState.doc2(2, '常见危急征象识别手册', '急诊', true, 25, 1760284800),
      MockAdminState.doc2(3, '门诊退费流程说明', '流程', true, 7, 1759766400)
    ];
  }

  private static dept(id: number, name: string, code: string, location: string, sort: number,
    enabled: boolean): Department {
    const result = new Department();
    result.id = id;
    result.name = name;
    result.code = code;
    result.location = location;
    result.sort = sort;
    result.enabled = enabled;
    result.createdAt = 1750000000;
    return result;
  }

  private static doc(id: number, name: string, departmentId: number, departmentName: string, title: string,
    specialty: string, enabled: boolean): Doctor {
    const result = new Doctor();
    result.id = id;
    result.name = name;
    result.departmentId = departmentId;
    result.departmentName = departmentName;
    result.title = title;
    result.specialty = specialty;
    result.enabled = enabled;
    result.createdAt = 1750000000;
    return result;
  }

  private static schedule(id: number, doctorId: number, departmentId: number, workDate: string, period: string,
    totalNum: number, remainNum: number, enabled: boolean): Schedule {
    const result = new Schedule();
    result.id = id;
    result.doctorId = doctorId;
    result.departmentId = departmentId;
    result.workDate = workDate;
    result.period = period;
    result.totalNum = totalNum;
    result.remainNum = remainNum;
    result.version = 1;
    result.enabled = enabled;
    result.doctorName = MockAdminState.doctorName(doctorId);
    result.doctorTitle = MockAdminState.doctorTitle(doctorId);
    result.departmentName = MockAdminState.deptName(departmentId);
    return result;
  }

  private static doctorName(doctorId: number): string {
    return '李医生';
  }

  private static doctorTitle(doctorId: number): string {
    return '副主任医师';
  }

  private static deptName(departmentId: number): string {
    if (departmentId === 3) {
      return '呼吸内科';
    }
    if (departmentId === 4) {
      return '骨科';
    }
    if (departmentId === 6) {
      return '消化内科';
    }
    return '科室';
  }

  private static user(userId: number, loginName: string, role: string, refId: number, displayName: string,
    status: string): AdminUser {
    const result = new AdminUser();
    result.userId = userId;
    result.loginName = loginName;
    result.role = role;
    result.refId = refId;
    result.displayName = displayName;
    result.status = status;
    return result;
  }

  private static setting(key: string, label: string, value: string, secret: boolean): AiSetting {
    const result = new AiSetting();
    result.key = key;
    result.label = label;
    result.value = value;
    result.secret = secret;
    result.refKind = secret ? 'env' : '';
    result.redacted = secret;
    return result;
  }

  private static prompt(name: string, label: string, body: string, customized: boolean): AiPrompt {
    const result = new AiPrompt();
    result.name = name;
    result.label = label;
    result.body = body;
    result.customized = customized;
    result.required = ['complaint'];
    result.maxLen = 2000;
    return result;
  }

  private static tool(name: string, label: string, defaultOn: boolean): AiTool {
    const result = new AiTool();
    result.name = name;
    result.label = label;
    result.defaultOn = defaultOn;
    result.enabled = defaultOn;
    return result;
  }

  private static doc2(id: number, title: string, category: string, enabled: boolean, chunkCount: number,
    updatedAt: number): KbDoc {
    const result = new KbDoc();
    result.id = id;
    result.title = title;
    result.category = category;
    result.enabled = enabled;
    result.chunkCount = chunkCount;
    result.updatedAt = updatedAt;
    return result;
  }
}

export class MockAdminRepository {
  static async login(loginName: string, password: string): Promise<AdminLoginResult> {
    if (loginName.trim().length === 0 || password.length === 0) {
      throw new ApiError(ErrorCode.VALIDATION_FAILED, '请输入账号和密码', 400);
    }
    const result = new AdminLoginResult();
    result.token = 'mock-admin-token';
    result.expiresAt = Math.floor(Date.now() / 1000) + 7 * 24 * 3600;
    result.userId = 1;
    result.role = 'admin';
    result.refId = 1;
    result.displayName = '管理员';
    return result;
  }

  static async dashboard(): Promise<Dashboard> {
    MockAdminState.initialize();
    const result = new Dashboard();
    result.departments = MockAdminState.departments.length;
    result.doctors = MockAdminState.doctors.length;
    result.patients = 1284;
    result.appointmentTotal = 1284;
    result.appointmentDone = 902;
    result.appointmentNoShow = 26;
    result.cancelPermille = 18;
    result.noShowPermille = 20;
    let totalSlots = 0;
    let remainSlots = 0;
    for (const schedule of MockAdminState.schedules) {
      totalSlots += schedule.totalNum;
      remainSlots += schedule.remainNum;
    }
    result.totalSlots = totalSlots;
    result.remainSlots = remainSlots;
    result.scheduleCount = MockAdminState.schedules.length;
    result.enabledScheduleCount = MockAdminState.schedules.filter((s: Schedule) => s.enabled).length;
    result.slotUsagePct = totalSlots > 0 ? Math.round((totalSlots - remainSlots) / totalSlots * 100) : 0;
    result.triageHitPct = 73;
    result.previsitCompletionPct = 91;
    const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    const pcts = [46, 62, 38, 78, 88, 34, 22];
    for (let i = 0; i < labels.length; i++) {
      const point = new TrendPoint();
      point.label = labels[i];
      point.count = pcts[i];
      result.trend.push(point);
    }
    for (const department of MockAdminState.departments) {
      const item = new LabelCount();
      item.label = department.name;
      item.count = 20 + department.id * 7;
      result.byDepartment.push(item);
    }
    result.recordTotal = 902;
    result.recordLocked = 820;
    result.recordDraft = 55;
    result.recordEmpty = 27;
    result.lockedPermille = 909;
    result.sectionsPerRecord = 6;
    result.aiEnabled = true;
    result.aiModel = 'deepseek-chat';
    result.aiToolsEnabled = MockAdminState.aiTools.filter((t: AiTool) => t.enabled).length;
    result.aiToolsTotal = MockAdminState.aiTools.length;
    result.aiPromptsTotal = MockAdminState.aiPrompts.length;
    result.aiPromptsCustomized = MockAdminState.aiPrompts.filter((p: AiPrompt) => p.customized).length;
    result.kbDocs = MockAdminState.kbDocs.length;
    result.kbDocsEnabled = MockAdminState.kbDocs.filter((d: KbDoc) => d.enabled).length;
    result.kbChunks = 50;
    result.kbChunksEmbedded = 46;
    result.kbEmbeddingCoveragePct = 92;
    return result;
  }

  static async departments(): Promise<Department[]> {
    MockAdminState.initialize();
    return MockAdminState.departments;
  }

  static async createDepartment(body: Record<string, Object>): Promise<Department> {
    MockAdminState.initialize();
    const name = String(body['name'] ?? '').trim();
    const code = String(body['code'] ?? '').trim();
    MockAdminRepository.ensureUnique(name, code, 0);
    const result = new Department();
    result.id = MockAdminState.nextDepartmentId++;
    result.name = name;
    result.code = code;
    result.location = String(body['location'] ?? '');
    result.sort = Number(body['sort'] ?? 0);
    result.enabled = body['enabled'] === undefined ? true : Boolean(body['enabled']);
    MockAdminState.departments.push(result);
    return result;
  }

  static async updateDepartment(id: number, body: Record<string, Object>): Promise<Department> {
    MockAdminState.initialize();
    const target = MockAdminRepository.findDepartment(id);
    const name = String(body['name'] ?? target.name).trim();
    const code = String(body['code'] ?? target.code).trim();
    MockAdminRepository.ensureUnique(name, code, id);
    target.name = name;
    target.code = code;
    if (body['location'] !== undefined) {
      target.location = String(body['location']);
    }
    if (body['sort'] !== undefined) {
      target.sort = Number(body['sort']);
    }
    if (body['enabled'] !== undefined) {
      target.enabled = Boolean(body['enabled']);
    }
    return target;
  }

  static async deleteDepartment(id: number): Promise<void> {
    MockAdminState.initialize();
    const inUse = MockAdminState.schedules.some((s: Schedule) => s.departmentId === id);
    if (inUse) {
      throw new ApiError('BASE_IN_USE', '该科室正被号源引用，不能删除', 409);
    }
    MockAdminState.departments = MockAdminState.departments.filter((d: Department) => d.id !== id);
  }

  private static ensureUnique(name: string, code: string, excludeId: number): void {
    if (name.length === 0 || code.length === 0) {
      throw new ApiError(ErrorCode.VALIDATION_FAILED, '名称与编码均必填', 400);
    }
    for (const department of MockAdminState.departments) {
      if (department.id !== excludeId && department.name === name) {
        throw new ApiError('BASE_NAME_TAKEN', '同名科室已存在', 409);
      }
      if (department.id !== excludeId && department.code === code) {
        throw new ApiError('BASE_CODE_TAKEN', '同编码科室已存在', 409);
      }
    }
  }

  private static findDepartment(id: number): Department {
    for (const department of MockAdminState.departments) {
      if (department.id === id) {
        return department;
      }
    }
    throw new ApiError(ErrorCode.SCHEDULE_NOT_FOUND, '科室不存在', 404);
  }

  static async doctors(): Promise<Doctor[]> {
    MockAdminState.initialize();
    return MockAdminState.doctors;
  }

  static async createDoctor(body: Record<string, Object>): Promise<Doctor> {
    MockAdminState.initialize();
    const name = String(body['name'] ?? '').trim();
    const departmentId = Number(body['department_id'] ?? 0);
    if (name.length === 0 || departmentId === 0) {
      throw new ApiError(ErrorCode.VALIDATION_FAILED, '姓名与科室均必填', 400);
    }
    const result = new Doctor();
    result.id = MockAdminState.nextDoctorId++;
    result.name = name;
    result.departmentId = departmentId;
    result.departmentName = MockAdminState.deptName(departmentId);
    result.title = String(body['title'] ?? '');
    result.specialty = String(body['specialty'] ?? '');
    result.enabled = body['enabled'] === undefined ? true : Boolean(body['enabled']);
    MockAdminState.doctors.push(result);
    return result;
  }

  static async updateDoctor(id: number, body: Record<string, Object>): Promise<Doctor> {
    MockAdminState.initialize();
    const target = MockAdminRepository.findDoctor(id);
    target.name = String(body['name'] ?? target.name).trim();
    if (body['department_id'] !== undefined) {
      target.departmentId = Number(body['department_id']);
      target.departmentName = MockAdminState.deptName(target.departmentId);
    }
    if (body['title'] !== undefined) {
      target.title = String(body['title']);
    }
    if (body['specialty'] !== undefined) {
      target.specialty = String(body['specialty']);
    }
    if (body['enabled'] !== undefined) {
      target.enabled = Boolean(body['enabled']);
    }
    return target;
  }

  static async deleteDoctor(id: number): Promise<void> {
    MockAdminState.initialize();
    MockAdminState.doctors = MockAdminState.doctors.filter((d: Doctor) => d.id !== id);
  }

  private static findDoctor(id: number): Doctor {
    for (const doctor of MockAdminState.doctors) {
      if (doctor.id === id) {
        return doctor;
      }
    }
    throw new ApiError(ErrorCode.SCHEDULE_NOT_FOUND, '医生不存在', 404);
  }

  static async schedules(): Promise<Schedule[]> {
    MockAdminState.initialize();
    return MockAdminState.schedules;
  }

  static async createSchedule(body: Record<string, Object>): Promise<Schedule> {
    MockAdminState.initialize();
    const doctorId = Number(body['doctor_id'] ?? 0);
    const departmentId = Number(body['department_id'] ?? 0);
    const workDate = String(body['work_date'] ?? '').trim();
    const period = String(body['period'] ?? 'AM');
    const totalNum = Number(body['total_num'] ?? 0);
    if (doctorId === 0 || departmentId === 0 || workDate.length === 0 || totalNum <= 0) {
      throw new ApiError(ErrorCode.VALIDATION_FAILED, '医生、科室、日期与号数均必填', 400);
    }
    const result = new Schedule();
    result.id = MockAdminState.nextScheduleId++;
    result.doctorId = doctorId;
    result.departmentId = departmentId;
    result.workDate = workDate;
    result.period = period;
    result.totalNum = totalNum;
    result.remainNum = totalNum;
    result.version = 1;
    result.enabled = true;
    result.doctorName = MockAdminState.doctorName(doctorId);
    result.doctorTitle = MockAdminState.doctorTitle(doctorId);
    result.departmentName = MockAdminState.deptName(departmentId);
    MockAdminState.schedules.push(result);
    return result;
  }

  static async users(): Promise<AdminUser[]> {
    MockAdminState.initialize();
    return MockAdminState.users;
  }

  static async createUser(body: Record<string, Object>): Promise<AdminUser> {
    MockAdminState.initialize();
    const loginName = String(body['login_name'] ?? '').trim();
    const password = String(body['password'] ?? '');
    const role = String(body['role'] ?? '');
    if (loginName.length === 0 || password.length < 6 || role.length === 0) {
      throw new ApiError(ErrorCode.VALIDATION_FAILED, '登录名、密码（≥6 位）与角色均必填', 400);
    }
    const result = new AdminUser();
    result.userId = MockAdminState.nextDocId + 100;
    result.loginName = loginName;
    result.role = role;
    result.refId = Number(body['ref_id'] ?? 0);
    result.displayName = String(body['display_name'] ?? '');
    result.status = 'active';
    MockAdminState.users.push(result);
    return result;
  }

  static async resetPassword(id: number, password: string): Promise<void> {
    MockAdminState.initialize();
    if (password.length < 6) {
      throw new ApiError(ErrorCode.VALIDATION_FAILED, '密码至少 6 位', 400);
    }
  }

  static async aiSettings(): Promise<AiSetting[]> {
    MockAdminState.initialize();
    return MockAdminState.aiSettings;
  }

  static async updateAiSetting(key: string, value: string): Promise<void> {
    MockAdminState.initialize();
    for (const setting of MockAdminState.aiSettings) {
      if (setting.key === key) {
        if (setting.secret) {
          if (!value.startsWith('env:') && !value.startsWith('file:')) {
            throw new ApiError(ErrorCode.VALIDATION_FAILED, '密钥只接受 env: / file: 引用', 400);
          }
          setting.value = `已设置（引用类型：${value.startsWith('env:') ? 'env' : 'file'}）`;
        } else {
          setting.value = value;
        }
        return;
      }
    }
    throw new ApiError(ErrorCode.SCHEDULE_NOT_FOUND, '配置项不存在', 404);
  }

  static async aiPrompts(): Promise<AiPrompt[]> {
    MockAdminState.initialize();
    return MockAdminState.aiPrompts;
  }

  static async updateAiPrompt(name: string, body: string): Promise<void> {
    MockAdminState.initialize();
    for (const prompt of MockAdminState.aiPrompts) {
      if (prompt.name === name) {
        prompt.body = body;
        prompt.customized = true;
        return;
      }
    }
    throw new ApiError(ErrorCode.SCHEDULE_NOT_FOUND, '提示词模板不存在', 404);
  }

  static async deleteAiPrompt(name: string): Promise<void> {
    MockAdminState.initialize();
    MockAdminState.aiPrompts = MockAdminState.aiPrompts.filter((p: AiPrompt) => p.name !== name);
  }

  static async aiTools(): Promise<AiTool[]> {
    MockAdminState.initialize();
    return MockAdminState.aiTools;
  }

  static async updateAiTool(name: string, enabled: boolean): Promise<void> {
    MockAdminState.initialize();
    for (const tool of MockAdminState.aiTools) {
      if (tool.name === name) {
        tool.enabled = enabled;
        return;
      }
    }
    throw new ApiError(ErrorCode.SCHEDULE_NOT_FOUND, '工具不存在', 404);
  }

  static async kbDocs(): Promise<KbDoc[]> {
    MockAdminState.initialize();
    return MockAdminState.kbDocs;
  }

  static async createKbDoc(body: Record<string, Object>): Promise<KbDoc> {
    MockAdminState.initialize();
    const title = String(body['title'] ?? '').trim();
    const docBody = String(body['body'] ?? '').trim();
    if (title.length === 0 || docBody.length === 0) {
      throw new ApiError(ErrorCode.VALIDATION_FAILED, '标题与正文均必填', 400);
    }
    const result = new KbDoc();
    result.id = MockAdminState.nextDocId++;
    result.title = title;
    result.category = String(body['category'] ?? '');
    result.enabled = true;
    result.chunkCount = Math.max(1, Math.ceil(docBody.length / 200));
    result.updatedAt = Math.floor(Date.now() / 1000);
    MockAdminState.kbDocs.push(result);
    return result;
  }

  static async updateKbDoc(id: number, body: Record<string, Object>): Promise<KbDoc> {
    MockAdminState.initialize();
    const target = MockAdminRepository.findKbDoc(id);
    if (body['title'] !== undefined) {
      target.title = String(body['title']);
    }
    if (body['category'] !== undefined) {
      target.category = String(body['category']);
    }
    if (body['enabled'] !== undefined) {
      target.enabled = Boolean(body['enabled']);
    }
    target.updatedAt = Math.floor(Date.now() / 1000);
    return target;
  }

  static async deleteKbDoc(id: number): Promise<void> {
    MockAdminState.initialize();
    MockAdminState.kbDocs = MockAdminState.kbDocs.filter((d: KbDoc) => d.id !== id);
  }

  private static findKbDoc(id: number): KbDoc {
    for (const doc of MockAdminState.kbDocs) {
      if (doc.id === id) {
        return doc;
      }
    }
    throw new ApiError(ErrorCode.SCHEDULE_NOT_FOUND, '文档不存在', 404);
  }
}
