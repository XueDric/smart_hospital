export class AdminLoginResult {
  token: string = '';
  expiresAt: number = 0;
  userId: number = 0;
  role: string = '';
  refId: number = 0;
  displayName: string = '';
}

export class Department {
  id: number = 0;
  name: string = '';
  code: string = '';
  location: string = '';
  sort: number = 0;
  enabled: boolean = true;
  createdAt: number = 0;
}

export class Doctor {
  id: number = 0;
  name: string = '';
  departmentId: number = 0;
  departmentName: string = '';
  title: string = '';
  specialty: string = '';
  enabled: boolean = true;
  createdAt: number = 0;
}

export class Schedule {
  id: number = 0;
  doctorId: number = 0;
  departmentId: number = 0;
  workDate: string = '';
  period: string = '';
  totalNum: number = 0;
  remainNum: number = 0;
  version: number = 0;
  enabled: boolean = true;
  departmentName: string = '';
  doctorName: string = '';
  doctorTitle: string = '';
}

export class AdminUser {
  userId: number = 0;
  loginName: string = '';
  role: string = '';
  refId: number = 0;
  displayName: string = '';
  status: string = '';
}

export class AiSetting {
  key: string = '';
  label: string = '';
  secret: boolean = false;
  refKind: string = '';
  value: string = '';
  defaultValue: string = '';
  redacted: boolean = false;
  isDefault: boolean = false;
}

export class AiPrompt {
  name: string = '';
  label: string = '';
  required: string[] = [];
  maxLen: number = 0;
  customized: boolean = false;
  body: string = '';
}

export class AiTool {
  name: string = '';
  label: string = '';
  defaultOn: boolean = false;
  enabled: boolean = false;
}

export class TrendPoint {
  label: string = '';
  count: number = 0;
}

export class LabelCount {
  label: string = '';
  count: number = 0;
}

export class Dashboard {
  departments: number = 0;
  doctors: number = 0;
  patients: number = 0;
  appointmentTotal: number = 0;
  appointmentDone: number = 0;
  appointmentNoShow: number = 0;
  cancelPermille: number = 0;
  noShowPermille: number = 0;
  totalSlots: number = 0;
  remainSlots: number = 0;
  scheduleCount: number = 0;
  enabledScheduleCount: number = 0;
  slotUsagePct: number = 0;
  triageHitPct: number = 0;
  previsitCompletionPct: number = 0;
  trend: TrendPoint[] = [];
  byDepartment: LabelCount[] = [];
  recordTotal: number = 0;
  recordLocked: number = 0;
  recordDraft: number = 0;
  recordEmpty: number = 0;
  lockedPermille: number = 0;
  sectionsPerRecord: number = 0;
  aiEnabled: boolean = false;
  aiModel: string = '';
  aiToolsEnabled: number = 0;
  aiToolsTotal: number = 0;
  aiPromptsTotal: number = 0;
  aiPromptsCustomized: number = 0;
  kbDocs: number = 0;
  kbDocsEnabled: number = 0;
  kbChunks: number = 0;
  kbChunksEmbedded: number = 0;
  kbEmbeddingCoveragePct: number = 0;
}

export class KbDoc {
  id: number = 0;
  title: string = '';
  category: string = '';
  enabled: boolean = true;
  chunkCount: number = 0;
  updatedAt: number = 0;
}
