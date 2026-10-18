export class LoginResult {
  token: string = '';
  expiresAt: number = 0;
  userId: number = 0;
  role: string = '';
  refId: number = 0;
  displayName: string = '';
  patientId: number = 0;
}

export class CurrentUser {
  userId: number = 0;
  role: string = '';
  patientId: number = 0;
  doctorId: number = 0;
  deviceId: string = '';
  /** ★ 2026-10-17：服务端 `/api/v1/auth/me` 一直返回 `display_name`，此前客户端没解析 ⇒ "同步身份"刷不到姓名。 */
  displayName: string = '';
  /**
   * ★ 2026-10-17：服务端**滑动续期**后的新有效期。此前客户端只在登录时取过一次，
   * 于是有效期一过就冷启动掉回登录页（而服务端其实还认这个令牌）。
   */
  expiresAt: number = 0;
}

export class TriageOption {
  departmentId: number = 0;
  departmentName: string = '';
  doctorId: number = 0;
  doctorName: string = '';
  doctorTitle: string = '';
  scheduleId: number = 0;
  workDate: string = '';
  period: string = '';
  remainNum: number = 0;
  totalRemain: number = 0;
}

export class TriageResult {
  redFlag: boolean = false;
  reasonCode: string = '';
  source: string = '';
  patientNote: string = '';
  truncated: boolean = false;
  aiNote: string = '';
  aiReason: string = '';
  options: TriageOption[] = [];
  count: number = 0;
}

export class PrevisitSession {
  sessionId: string = '';
  turn: number = 0;
  filled: number = 0;
  totalSlots: number = 6;
  complete: boolean = false;
  nextSlot: string = '';
  nextQuestion: string = '';
  form: Record<string, string> = {};
}

export class Schedule {
  id: number = 0;
  doctorId: number = 0;
  departmentId: number = 0;
  workDate: string = '';
  period: string = '';
  totalNum: number = 0;
  remainNum: number = 0;
  enabled: boolean = true;
}

export class Appointment {
  appointmentId: number = 0;
  scheduleId: number = 0;
  patientId: number = 0;
  doctorId: number = 0;
  departmentId: number = 0;
  visitDate: string = '';
  period: string = '';
  seqNo: number = 0;
  /** 机器判据：分支逻辑只经 VisitStatus 谓词读它，不要拿它比字面量 */
  status: string = '';
  /** 服务端下发的权威中文名（visitStatusLabel，server/src/domain_emr.cj:1455） */
  statusLabel: string = '';
  /** 到院 / 接诊 / 完成的时间戳；0 = 该步还没发生（服务端口径，见 http_app.cj:631-636） */
  arrivedAt: number = 0;
  startedAt: number = 0;
  finishedAt: number = 0;
  /** 科室名与医生名：服务端已下发，避免界面只能显示「科室 #3 医生 #9」 */
  departmentName: string = '';
  doctorName: string = '';
  doctorTitle: string = '';
  slotRestored: boolean = true;
  warning: string = '';
}

export class MedicalRecordSummary {
  id: number = 0;
  appointmentId: number = 0;
  patientId: number = 0;
  doctorId: number = 0;
  status: string = '';
  locked: boolean = false;
  filled: number = 0;
  totalSections: number = 7;
  complete: boolean = false;
  updatedBy: number = 0;
  createdAt: number = 0;
  updatedAt: number = 0;
  missingRequired: string[] = [];
}

export class MedicalRecordSection {
  key: string = '';
  label: string = '';
  value: string = '';
  maxLen: number = 0;
  requiredToLock: boolean = false;
}

export class MedicalRecordDetail extends MedicalRecordSummary {
  sections: MedicalRecordSection[] = [];
}

export class DoctorIdentity {
  doctorId: number = 0;
  displayName: string = '';
  title: string = '';
}

export class PatientNotice {
  id: number = 0;
  title: string = '';
  body: string = '';
  date: string = '';
  category: string = '';
}

export class SlotDefinition {
  key: string = '';
  label: string = '';
  question: string = '';
  hint: string = '';
  maxLen: number = 0;

  constructor(key: string = '', label: string = '', question: string = '', hint: string = '',
    maxLen: number = 0) {
    this.key = key;
    this.label = label;
    this.question = question;
    this.hint = hint;
    this.maxLen = maxLen;
  }
}

export class PrevisitSlots {
  static readonly ALL: SlotDefinition[] = [
    new SlotDefinition('chief', '主诉', '您这次主要哪里不舒服？', '例如：咳嗽、胃痛、头晕', 200),
    new SlotDefinition('duration', '持续时间', '这个情况持续多久了？', '例如：3 天、2 周、半年', 60),
    new SlotDefinition('severity', '影响程度', '对日常生活影响大吗？', '例如：轻微 / 影响睡眠 / 无法工作', 60),
    new SlotDefinition('associated', '伴随症状', '还有其它不舒服吗？', '没有就写「无」', 200),
    new SlotDefinition('history', '既往史', '以前有没有得过什么病、或长期吃药？', '没有就写「无」', 300),
    new SlotDefinition('allergy', '过敏史', '有没有药物或食物过敏？', '没有就写「无」', 200)
  ];

  static find(key: string): SlotDefinition {
    for (const slot of PrevisitSlots.ALL) {
      if (slot.key === key) {
        return slot;
      }
    }
    return new SlotDefinition();
  }

  static label(key: string): string {
    const slot = PrevisitSlots.find(key);
    return slot.label.length > 0 ? slot.label : key;
  }
}

export function asRecord(value: Object | undefined): Record<string, Object> {
  if (value === undefined || value === null || Array.isArray(value)) {
    return {};
  }
  return value as Record<string, Object>;
}

export function asString(value: Object | undefined, fallback: string = ''): string {
  if (value === undefined || value === null) {
    return fallback;
  }
  return String(value);
}

export function asNumber(value: Object | undefined, fallback: number = 0): number {
  if (value === undefined || value === null) {
    return fallback;
  }
  const parsed = Number(value);
  return Number.isNaN(parsed) ? fallback : parsed;
}

export function asBool(value: Object | undefined, fallback: boolean = false): boolean {
  if (value === undefined || value === null) {
    return fallback;
  }
  return Boolean(value);
}

export function asArray(value: Object | undefined): Object[] {
  return Array.isArray(value) ? value as Object[] : [];
}

export function asStringMap(value: Object | undefined): Record<string, string> {
  const result: Record<string, string> = {};
  const source = asRecord(value);
  const keys = Object.keys(source);
  for (const key of keys) {
    result[key] = asString(source[key], '');
  }
  return result;
}
