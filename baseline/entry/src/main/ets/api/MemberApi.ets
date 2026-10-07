/**
 * 负责人：杨睿（前端组长）—— 待分配审批（pending / assign / assignBatch）、管理（transferPresidency / resetPassword）、注册口令（get / set / rotate）
 * 成员相关 API（成员名录 / 详情接口由 D / E 负责）
 * 后端 Part 3.2–3.5：成员名录、待分配、授权、会长移交、注册配置
 * 后端来源：backend-src/h_member.cj · h_auth.cj · views.cj
 */
import { HttpClient, ApiResponse } from './HttpClient';
import type { MemberBrief, DeptBrief } from './AuthApi';

// ─── 扩展类型 ───

/** 待分配成员视图 = MemberBrief + dept_hint + registered_at（+ risk，见下） */
export interface PendingMemberView extends MemberBrief {
  dept_hint: DeptBrief | null;
  registered_at: string | null;
  /**
   * 邀请风控的风险分档（docs/api-design.md §7.5）。
   * ⚠ 当前服务端尚未实现该字段（`GET /members/pending` 响应里不含），
   *   前端只做「有则展示、无则跳过」的防御式渲染，不依赖它。
   */
  risk?: PendingRisk | null;
}

/** 待审批申请的风险分档（低 / 中 / 高 + 理由），来源与 AiSource 同口径。 */
export interface PendingRisk {
  level: 'low' | 'medium' | 'high';
  reasons: string[];
  source: 'model' | 'fallback' | 'none';
}

/** GET /api/v1/members/{id} 响应 */
export interface MemberStats {
  owned_tasks: number;
  open_tasks: number;
  done_tasks: number;
  overdue_tasks: number;
  owned_plans: number;
}

export interface MemberDetailResponse {
  member: MemberBrief;
  stats: MemberStats;
}

/** 注册口令配置 */
export interface RegisterCodeConfig {
  code: string;
  updated_at: string | null;
  updated_by: MemberBrief | null;
}

/** 批量分配失败记录 */
export interface BatchFailItem {
  id: number;
  code: string;
}

/** 批量分配响应 */
export interface AssignBatchResponse {
  succeeded: number[];
  failed: BatchFailItem[];
}

/** GET /api/v1/members 响应 */
export interface MemberListResponse {
  items: MemberBrief[];
  total: number;
  page?: number;
  size?: number;
}

/** GET /api/v1/members/pending 响应 */
export interface PendingMemberListResponse {
  items: PendingMemberView[];
}

/** 会长移交响应 */
export interface TransferPresidencyResponse {
  president: MemberBrief;
  previous: MemberBrief;
}

/** 重置密码响应 —— 一次性临时密码（仅本次返回可见，需立即转告目标成员） */
export interface ResetPasswordResponse {
  temporary_password: string;
}

// ─── 请求类型 ───

export interface AssignRequest {
  dept_id: number;
  role: string;
}

export interface AssignBatchRequest {
  dept_id: number;
  role: string;
  member_ids: number[];
}

export interface UpdateMemberRequest {
  name?: string;
  dept_id?: number;
  role?: string;
}

export interface TransferPresidencyRequest {
  /** 原会长降为什么角色，默认 "vice_president" */
  self_role?: string;
}

export interface SetRegisterCodeRequest {
  code: string;
}

/** GET /api/v1/members 查询参数 — 全部可选 */
export interface MemberListParams {
  dept_id?: number;
  role?: string;
  status?: 'active' | 'pending' | 'disabled';
  q?: string;
  page?: number;
  size?: number;
}

// ─── API 类 ───

export class MemberApi {
  private client: HttpClient;

  constructor() {
    this.client = HttpClient.getInstance();
  }

  /** GET /api/v1/members — 成员名录（可按部门/状态筛选） */
  async list(params?: MemberListParams): Promise<ApiResponse<MemberListResponse>> {
    const parts: string[] = [];
    if (params !== undefined) {
      if (params.dept_id !== undefined) parts.push(`dept_id=${params.dept_id}`);
      if (params.role !== undefined && params.role.length > 0) parts.push(`role=${encodeURIComponent(params.role)}`);
      if (params.status !== undefined) parts.push(`status=${params.status}`);
      if (params.q !== undefined && params.q.length > 0) parts.push(`q=${encodeURIComponent(params.q)}`);
      if (params.page !== undefined) parts.push(`page=${params.page}`);
      if (params.size !== undefined) parts.push(`size=${params.size}`);
    }
    const qs = parts.join('&');
    return this.client.get<MemberListResponse>(`/members${qs.length > 0 ? '?' + qs : ''}`);
  }

  /** GET /api/v1/members/pending — 待分配成员列表 */
  async pending(): Promise<ApiResponse<PendingMemberListResponse>> {
    return this.client.get<PendingMemberListResponse>('/members/pending');
  }

  /** GET /api/v1/members/{id} — 成员详情（含统计数据） */
  async detail(id: number): Promise<ApiResponse<MemberDetailResponse>> {
    return this.client.get<MemberDetailResponse>(`/members/${id}`);
  }

  /** POST /api/v1/members/{id}/disable — 移出社团（有未完成任务会拒绝） */
  async disable(id: number): Promise<ApiResponse<MemberBrief>> {
    return this.client.post<MemberBrief>(`/members/${id}/disable`);
  }

  /** POST /api/v1/members/{id}/assign — 分配部门与角色 */
  async assign(id: number, data: AssignRequest): Promise<ApiResponse<MemberBrief>> {
    return this.client.post<MemberBrief>(`/members/${id}/assign`, data);
  }

  /** POST /api/v1/members/assign-batch — 批量分配 */
  async assignBatch(data: AssignBatchRequest): Promise<ApiResponse<AssignBatchResponse>> {
    return this.client.post<AssignBatchResponse>('/members/assign-batch', data);
  }

  /** PATCH /api/v1/members/{id} — 编辑成员（姓名/部门/角色，全部可选） */
  async update(id: number, data: UpdateMemberRequest): Promise<ApiResponse<MemberBrief>> {
    return this.client.patch<MemberBrief>(`/members/${id}`, data);
  }

  /** POST /api/v1/members/{id}/transfer-presidency — 会长移交 */
  async transferPresidency(id: number, data?: TransferPresidencyRequest): Promise<ApiResponse<TransferPresidencyResponse>> {
    return this.client.post<TransferPresidencyResponse>(`/members/${id}/transfer-presidency`, data);
  }

  /** POST /api/v1/members/{id}/reset-password — 重置密码（签发一次性临时密码） */
  async resetPassword(id: number): Promise<ApiResponse<ResetPasswordResponse>> {
    return this.client.post<ResetPasswordResponse>(`/members/${id}/reset-password`);
  }

  /** GET /api/v1/register-config — 获取注册口令 */
  async getRegisterCode(): Promise<ApiResponse<RegisterCodeConfig>> {
    return this.client.get<RegisterCodeConfig>('/register-config');
  }

  /** PUT /api/v1/register-config/code — 设置注册口令 */
  async setRegisterCode(data: SetRegisterCodeRequest): Promise<ApiResponse<RegisterCodeConfig>> {
    return this.client.put<RegisterCodeConfig>('/register-config/code', data);
  }

  /** POST /api/v1/register-config/rotate — 轮换注册口令 */
  async rotateRegisterCode(): Promise<ApiResponse<RegisterCodeConfig>> {
    return this.client.post<RegisterCodeConfig>('/register-config/rotate');
  }
}
