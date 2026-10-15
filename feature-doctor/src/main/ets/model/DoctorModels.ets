export class LoginResult {
  token: string = '';
  expiresAt: number = 0;
  userId: number = 0;
  role: string = '';
  refId: number = 0;
  displayName: string = '';
}

export class VisitItem {
  appointmentId: number = 0;
  patientId: number = 0;
  doctorId: number = 0;
  departmentId: number = 0;
  visitDate: string = '';
  period: string = '';
  seqNo: number = 0;
  status: string = '';
  // 真实就诊阶段（arrived/waiting/visiting/…）；服务端在兼容字段 `status` 之外
  // 单独下发，缺失时客户端回退到 `status`（见 DoctorRepository.parseVisit）。
  visitStatus: string = '';
  // 本单是否绑定了患者预问诊单（服务端 2026-10-14 新增）——队列页据此显示「预问诊」徽标。
  previsitReady: boolean = false;
  recordId: number = 0;
  recordStatus: string = 'none';
  recordFilled: number = 0;
  recordTotal: number = 7;
}

export class EmrSection {
  key: string = '';
  label: string = '';
  value: string = '';
  maxLen: number = 0;
  requiredToLock: boolean = false;
}

export class EmrRecord {
  id: number = 0;
  appointmentId: number = 0;
  patientId: number = 0;
  doctorId: number = 0;
  status: string = 'none';
  locked: boolean = false;
  filled: number = 0;
  totalSections: number = 7;
  complete: boolean = false;
  updatedBy: number = 0;
  createdAt: number = 0;
  updatedAt: number = 0;
  missingRequired: string[] = [];
  sections: EmrSection[] = [];
  // 预问诊来源痕迹（服务端 2026-10-14 新增；只在单查且确实由预问诊预填过时才下发）。
  // 语义是「初值来源快照」：医生后续编辑不会改它，角标文案用「患者自述（已由医生编辑）」。
  previsitRefSessionId: string = '';
  previsitRefSections: string[] = [];
  previsitRefAt: number = 0;
}

// 预问诊摘要里的一项已作答槽位（GET /api/v1/doctor/visits/:id/previsit 的 sections[]）。
export class PrevisitSlot {
  key: string = '';
  label: string = '';
  value: string = '';
  maxLen: number = 0;
}

// 医生端读到的患者预问诊摘要（服务端 2026-10-14 新增端点，见 FRONTEND-INTEGRATION §5.28）。
export class PrevisitSummary {
  sessionId: string = '';
  // true = 绑定了本次就诊的会话；false = 本单未绑定，回退到该患者最近一次已完成的会话。
  bound: boolean = false;
  turn: number = 0;
  completed: boolean = false;
  filled: number = 0;
  total: number = 6;
  capturedAt: number = 0;
  sections: PrevisitSlot[] = [];
}
