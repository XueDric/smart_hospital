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
  /*
   * ⚠ 2026-10-16（复核 D3）：服务端从改进 6 起额外下发
   *   ① `status_label` —— 人话状态名（与 `status` 同源，改文案不影响机器判据）；
   *   ② `arrived_at` / `started_at` / `finished_at` —— epoch 秒，**0 = 这一步还没发生**
   *      （不是"时间是 1970"）。队列页要显示"已到院 09:12 / 候诊 18 分钟"就必须读它们；
   *      此前客户端完全不解析，于是医生看不出患者等了多久。
   */
  statusLabel: string = '';
  arrivedAt: number = 0;
  startedAt: number = 0;
  finishedAt: number = 0;
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
  /*
   * 本次定稿落下的修订版本号（服务端改进 3 起在 lock/reopen 的成功响应里下发）。
   * ⚠ `0` = 审计行没写上，**病历本身已经锁定成功** —— 当「版本号未知」展示，
   *   绝不能当失败去重试（重试会走幂等分支，见 FRONTEND-INTEGRATION §5.29.6）。
   * PUT/GET 病历的响应不含该字段，所以默认 0 = 「本次没落版」。
   */
  revisionVersion: number = 0;
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

/*
 * 既往已定稿病历（改进 2，GET /doctor/patients/:patientId/records，契约见 §5.30.1）。
 * 为什么包一层而不是把上下文塞进 EmrRecord：这条端点的 item **就是**病历对象就地展开
 * 再补就诊上下文，复用 parseRecord 才能保证"同一份数据只有一份解析"。
 */
export class PastRecord {
  record: EmrRecord = new EmrRecord();
  // 以下三个只在挂号单还在时下发，否则保持默认 0/空串。
  departmentId: number = 0;
  visitDate: string = '';
  period: string = '';
  // 以下三个总是下发，找不到就写空串（不是缺失）。
  departmentName: string = '';
  doctorName: string = '';
  doctorTitle: string = '';
}

/*
 * 一条修订记录（改进 3，§5.29.2/§5.29.3）。
 * ⚠ `operatorRole` 可能是**空串**：存量病历由 migrateSchema 补写的那一版没有操作者角色，
 *   空串的语义是「未知」，不是「没有权限」—— UI 上要显示成「系统补录」，别显示成空白。
 */
export class RevisionItem {
  version: number = 0;
  status: string = '';
  // lock = 定稿落的版；reopen = 解锁落的版（解锁前那一版）。
  operation: string = '';
  // 仅 operation=reopen 时非空（4–255 字符）；lock 恒为空串。
  reason: string = '';
  operatorUserId: number = 0;
  operatorRole: string = '';
  createdAt: number = 0;
}

// 某一版详情（§5.29.3）：比列表项多 record_id / appointment_id / sections 正文。
export class RevisionDetail {
  version: number = 0;
  status: string = '';
  operation: string = '';
  reason: string = '';
  operatorUserId: number = 0;
  operatorRole: string = '';
  createdAt: number = 0;
  recordId: number = 0;
  appointmentId: number = 0;
  // 含全部七段（空段也在，value 为空串）—— 既能看出写了什么，也能看出没写什么。
  sections: EmrSection[] = [];
}

// 逐段对比里的一段（§5.29.4）。`changed` **由服务端判定**，客户端不得重算。
export class RevisionDiffSection {
  key: string = '';
  label: string = '';
  changed: boolean = false;
  left: string = '';
  right: string = '';
}

// 两版之间的逐段对比（§5.29.4）：语义是「从 left 改到 right」。
export class RevisionDiff {
  appointmentId: number = 0;
  left: RevisionItem = new RevisionItem();
  right: RevisionItem = new RevisionItem();
  statusChanged: boolean = false;
  // 服务端给的变更段数 = 客户端角标数量，**不要**自己比 left/right 重数。
  changedCount: number = 0;
  sections: RevisionDiffSection[] = [];
}
