/**
 * 负责人：杨睿（前端组长）
 * 部门/组织相关 API —— 部门 CRUD（建 / 改 / 删）+ 招募链接（列表 / 生成 / 停用）
 * 后端 Part 3.1：部门 CRUD + Part 3.7：招募链接
 * 后端来源：backend-src/h_dept.cj · h_link.cj · views.cj
 */
import { HttpClient, ApiResponse } from './HttpClient';
import type { MemberBrief, DeptBrief } from './AuthApi';

// ─── 部门类型 ───

/** DeptView — views.cj:deptView */
export interface DeptView {
  id: number;
  name: string;
  sort: number;
  lead: MemberBrief | null;
  member_count: number;
}

/** InviteLinkView — views.cj:inviteLinkView */
export interface InviteLinkView {
  token: string;
  url: string;
  dept: DeptBrief | null;
  enabled: boolean;
  created_at: string | null;
}

/** GET /api/v1/depts 响应 */
export interface DeptListResponse {
  items: DeptView[];
}

/** GET /api/v1/dept-invite-links 响应 */
export interface DeptLinksResponse {
  items: InviteLinkView[];
}

// ─── 请求类型 ───

export interface CreateDeptRequest {
  name: string;
  sort?: number;
}

export interface UpdateDeptRequest {
  name?: string;
  sort?: number;
}

export interface CreateLinkRequest {
  dept_id: number;
}

/** POST /api/v1/dept-invite-links 响应 —— 后端把完整视图包在 data.link 里，另附 token/url */
export interface CreateLinkResponse {
  link?: InviteLinkView;
  token: string;
  url: string;
  dept?: DeptBrief | null;
  enabled?: boolean;
  created_at?: string | null;
}

// ─── API 类 ───

export class DeptApi {
  private client: HttpClient;

  constructor() {
    this.client = HttpClient.getInstance();
  }

  /** GET /api/v1/depts — 获取所有部门 */
  async list(): Promise<ApiResponse<DeptListResponse>> {
    return this.client.get<DeptListResponse>('/depts');
  }

  /** POST /api/v1/depts — 创建部门 */
  async create(data: CreateDeptRequest): Promise<ApiResponse<DeptView>> {
    return this.client.post<DeptView>('/depts', data);
  }

  /** PATCH /api/v1/depts/{id} — 更新部门 */
  async update(id: number, data: UpdateDeptRequest): Promise<ApiResponse<DeptView>> {
    return this.client.patch<DeptView>(`/depts/${id}`, data);
  }

  /** DELETE /api/v1/depts/{id} — 删除部门（需无成员） */
  async delete_(id: number): Promise<ApiResponse<Record<string, never>>> {
    return this.client.delete_<Record<string, never>>(`/depts/${id}`);
  }

  /** GET /api/v1/dept-invite-links — 获取所有招募链接 */
  async listLinks(): Promise<ApiResponse<DeptLinksResponse>> {
    return this.client.get<DeptLinksResponse>('/dept-invite-links');
  }

  /** POST /api/v1/dept-invite-links — 创建招募链接（响应 data 为 {link, token, url}） */
  async createLink(deptId: number): Promise<ApiResponse<CreateLinkResponse>> {
    const data: CreateLinkRequest = { dept_id: deptId };
    return this.client.post<CreateLinkResponse>('/dept-invite-links', data);
  }

  /** DELETE /api/v1/dept-invite-links/{token} — 停用招募链接 */
  async toggleLink(token: string): Promise<ApiResponse<InviteLinkView>> {
    return this.client.delete_<InviteLinkView>(`/dept-invite-links/${token}`);
  }
}
