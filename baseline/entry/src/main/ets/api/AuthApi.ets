// 负责人：彭翌菲
// 认证相关 API，封装登录、注册、退出、获取当前用户、修改密码和邀请预览等接口，
// 统一供认证流程及各业务页面调用。

import { HttpClient, ApiResponse } from './HttpClient';

export interface DeptBrief {
  id: number;
  name: string;
}

export interface MemberBrief {
  id: number;
  name: string;
  role: string | null;
  dept: DeptBrief | null;
  status: 'active' | 'pending' | 'disabled';
  joined_at: string | null;
}

export interface MemberSelf extends MemberBrief {
  phone: string;
}

export interface UserPermissions {
  view_scope: 'none' | 'self' | 'dept' | 'all';
  manage_members: boolean;
  set_role: boolean;
  create_plan: boolean;
  create_task: boolean;
  update_any_task: boolean;
  // 管理页四张分区卡的显示开关（2026-09-16，D-1；仅用于画界面，不能替代服务端校验）
  manage_depts?: boolean;         // 部门增删改 —— 仅会长
  view_register_code?: boolean;   // 注册口令明文 —— 会长 / 副会长
  change_register_code?: boolean; // 更换 / 轮换口令 —— 仅会长
  manage_invite_links?: boolean;  // 招募链接增删启停 —— 会长 / 副会长
  transfer_presidency?: boolean;  // 会长移交 —— 仅会长
}

export interface LoginRequest {
  phone: string;
  password: string;
}

export interface LoginResponse {
  token: string;
  expires_at: string;
  member: MemberSelf;
  permissions: UserPermissions;
  dept_hint: DeptBrief | null;
}

export interface RegisterRequest {
  register_code: string;
  phone: string;
  name: string;
  password: string;
  dept_id?: number;
  invite_token?: string;
  client_token: string;
}

export type RegisterResponse = LoginResponse;

export interface MeResponse {
  member: MemberSelf;
  permissions: UserPermissions;
}

export interface ChangePasswordRequest {
  old_password: string;
  new_password: string;
}

export interface InvitePreview {
  dept: DeptBrief | null;
  enabled: boolean;
}

export class AuthApi {
  private client: HttpClient;

  constructor() {
    this.client = HttpClient.getInstance();
  }

  async login(data: LoginRequest): Promise<ApiResponse<LoginResponse>> {
    return this.client.post<LoginResponse>('/auth/login', data);
  }

  async register(data: RegisterRequest): Promise<ApiResponse<RegisterResponse>> {
    return this.client.post<RegisterResponse>('/auth/register', data);
  }

  async logout(): Promise<ApiResponse<Record<string, never>>> {
    return this.client.post<Record<string, never>>('/auth/logout');
  }

  async me(): Promise<ApiResponse<MeResponse>> {
    return this.client.get<MeResponse>('/auth/me');
  }

  async changePassword(data: ChangePasswordRequest): Promise<ApiResponse<Record<string, never>>> {
    return this.client.put<Record<string, never>>('/auth/password', data);
  }

  async previewInvite(token: string): Promise<ApiResponse<InvitePreview>> {
    return this.client.get<InvitePreview>(`/join/${token}`);
  }
}
