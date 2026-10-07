/**
 * 作者：刘运泽
 * 功能：课题模块 REST 接口封装（6 个接口）+ 类型定义
 * 修改记录：
 *   2026-09-16  用我方版本修复 4 个 API 文件的编译错误、对齐后端字段
 *
 * 课题相关 API
 * 后端 Part 5：课题 6 个接口
 * 后端来源：backend-src/h_plan.cj · views.cj
 */
import { HttpClient, ApiResponse, PagedResponse } from './HttpClient';
import type { MemberBrief, DeptBrief } from './AuthApi';
import type { TaskBrief, PlanRef } from './TaskApi';

// ─── 课题类型 ───

/** 课题进度聚合 */
export interface PlanProgress {
  done: number;
  total: number;
}

/** PlanBrief — views.cj:planBrief */
export interface PlanBrief {
  id: number;
  title: string;
  owner: MemberBrief | null;
  dept: DeptBrief | null;
  due_at: string | null;
  progress: PlanProgress;        // 递归聚合值，恒有 {done,total}，total=0 时为 {0,0}
  task_count: number;
  child_count: number;
  created_at: string;
  updated_at: string;
}

/** PlanDetail = PlanBrief + — views.cj:planDetail */
export interface PlanDetail extends PlanBrief {
  desc: string;
  parent_id: number;     // 0 = 根级
}

/** PlanNode = PlanBrief + children — views.cj:planNode */
export interface PlanNode extends PlanBrief {
  children: PlanNode[];
}

/** GET /api/v1/plans/{id} 返回 */
export interface PlanDetailResponse {
  plan: PlanDetail;
  path: PlanRef[];
  children: PlanNode[];
  tasks: PagedResponse<TaskBrief>;
}

/** POST /api/v1/plans 响应 — 课题对象在 data.plan 下 */
export interface CreatePlanResponse {
  plan: PlanDetail;
  duplicated?: boolean;
}

/** PATCH /api/v1/plans/{id} / POST /api/v1/plans/{id}/move 响应 */
export interface PlanWriteResponse {
  plan: PlanDetail;
}

// ─── 请求类型 ───

export interface CreatePlanRequest {
  title: string;
  owner_id: number;
  parent_id?: number;
  dept_id?: number;
  desc?: string;
  due_at?: string | null;
  /** 客户端生成的幂等 token，防重复提交 */
  client_token?: string;
}

export interface UpdatePlanRequest {
  title?: string;
  desc?: string;
  owner_id?: number;
  due_at?: string | null;
}

export interface MovePlanRequest {
  /** 目标父课题 id，null 表示提升为顶层 */
  new_parent_id?: number | null;
}

/** GET /api/v1/plans 响应 */
export interface PlanListResponse {
  items: PlanNode[];
}

// ─── API 类 ───

export class PlanApi {
  private client: HttpClient;

  constructor() {
    this.client = HttpClient.getInstance();
  }

  /** GET /api/v1/plans — 获取课题树 */
  async list(): Promise<ApiResponse<PlanListResponse>> {
    return this.client.get<PlanListResponse>('/plans');
  }

  /** GET /api/v1/plans/{id} — 课题详情（含路径、子树、任务） */
  async detail(id: number): Promise<ApiResponse<PlanDetailResponse>> {
    return this.client.get<PlanDetailResponse>(`/plans/${id}`);
  }

  /** POST /api/v1/plans — 创建课题（响应在 data.plan 下） */
  async create(data: CreatePlanRequest): Promise<ApiResponse<CreatePlanResponse>> {
    return this.client.post<CreatePlanResponse>('/plans', data, { label: '新建课题' });
  }

  /** PATCH /api/v1/plans/{id} — 更新课题（响应在 data.plan 下） */
  async update(id: number, data: UpdatePlanRequest): Promise<ApiResponse<PlanWriteResponse>> {
    return this.client.patch<PlanWriteResponse>(`/plans/${id}`, data);
  }

  /** POST /api/v1/plans/{id}/move — 移动课题（改父级，响应在 data.plan 下） */
  async move(id: number, data: MovePlanRequest): Promise<ApiResponse<PlanWriteResponse>> {
    return this.client.post<PlanWriteResponse>(`/plans/${id}/move`, data);
  }

  /** DELETE /api/v1/plans/{id} — 删除课题（子课题上提一级，任务保留） */
  async delete_(id: number): Promise<ApiResponse<Record<string, never>>> {
    return this.client.delete_<Record<string, never>>(`/plans/${id}`);
  }
}
