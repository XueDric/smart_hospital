/**
 * 作者：刘运泽
 * 功能：任务模块 REST 接口封装（8 个接口）+ 请求/响应类型定义
 * 修改记录：
 *   2026-09-16  用我方版本修复 4 个 API 文件的编译错误、对齐后端字段
 *
 * 任务相关 API
 * 后端 Part 4：任务 8 个接口
 * 后端来源：backend-src/h_task.cj · views.cj
 */
import { HttpClient, ApiResponse, PagedResponse } from './HttpClient';
import type { MemberBrief, DeptBrief } from './AuthApi';

// ─── 课题简要引用 ───

export interface PlanRef {
  id: number;
  title: string;
}

/** 阻塞任务的求助对象（部门和具体成员均可为空）。 */
export interface NeedsHelp {
  dept: DeptBrief | null;
  member: MemberBrief | null;
}

// ─── 任务类型 ───

export type TaskStatus = 'todo' | 'doing' | 'blocked' | 'done';

/** TaskBrief — views.cj:taskBrief */
export interface TaskBrief {
  id: number;
  title: string;
  status: TaskStatus;
  owner: MemberBrief | null;
  dept: DeptBrief | null;
  plan: PlanRef | null;
  due_at: string | null;  // ISO 8601，null = 无截止时间
  is_overdue: boolean;    // 服务端计算的派生量
  overdue_days?: number;  // 逾期天数，未逾期为 0
  blocked: boolean;       // 服务端计算的派生量 (status === 'blocked')
  blocker?: string | null; // blocked 时的原因
  needs_help?: NeedsHelp | null; // 求助对象；无求助对象时为 null
  updated_at: string;     // 服务端生成
}

/** TaskDetail = TaskBrief + — views.cj:taskDetail */
export interface TaskDetail extends TaskBrief {
  desc: string;
  blocker: string | null;  // blocked 时填值，否则 null
  plan_path: PlanRef[];    // 课题祖先链（从根到直属）
  created_by: MemberBrief | null;
  created_at: string;
  completed_at: string | null;  // 未完成 = null
}

// ─── 请求类型 ───

export interface CreateTaskRequest {
  title: string;
  owner_id: number;
  desc?: string;
  plan_id?: number;
  due_at?: string | null;
  /** 客户端生成的幂等 token，防重复提交 */
  client_token?: string;
}

export interface UpdateTaskRequest {
  title?: string;
  owner_id?: number;
  desc?: string;
  plan_id?: number;
  due_at?: string | null;
}

export interface UpdateTaskStatusRequest {
  status: TaskStatus;
  /** status=blocked 时必填 */
  blocker?: string;
  /** status=blocked 时可选：求助部门 id，或与 help_member_id 二选一 */
  help_dept_id?: number;
  /** status=blocked 时可选：求助成员 id（服务端会补齐其部门） */
  help_member_id?: number;
}

export interface TaskLookupRequest {
  task_ids: number[];
}

/** GET /api/v1/tasks 查询参数 — 全部可选，服务端过滤 */
export interface TaskListParams {
  dept_id?: number;
  owner_id?: number;
  status?: TaskStatus;
  plan_id?: number;
  overdue?: boolean;
  include_subplans?: boolean;
  page?: number;
  size?: number;
}

/** POST /api/v1/tasks/lookup 响应 */
export interface TaskLookupResponse {
  items: TaskBrief[];
  missing: number[];
}

/** POST /api/v1/tasks 响应 — 服务端把任务包在 data.task 下（幂等命中时附 duplicated） */
export interface CreateTaskResponse {
  task: TaskDetail;
  duplicated?: boolean;
}

/** GET /api/v1/tasks/mine 响应 — MineGroups */
export interface MineCounts {
  overdue: number;
  blocked: number;
  open_total: number;
  /** 本部门别人负责、但被阻塞的任务数量（部长/副部长首页）。 */
  borrowed_blocked?: number;
}

export interface MineGroups {
  overdue: TaskBrief[];
  blocked: TaskBrief[];
  due_today: TaskBrief[];
  due_week: TaskBrief[];
  later: TaskBrief[];
  no_due: TaskBrief[];
  counts: MineCounts;
}

// ─── API 类 ───

export class TaskApi {
  private client: HttpClient;

  constructor() {
    this.client = HttpClient.getInstance();
  }

  /** GET /api/v1/tasks/mine — 我的任务分组 */
  async mine(): Promise<ApiResponse<MineGroups>> {
    return this.client.get<MineGroups>('/tasks/mine');
  }

  /** GET /api/v1/tasks — 任务列表（筛选 + 分页） */
  async list(params?: TaskListParams): Promise<ApiResponse<PagedResponse<TaskBrief>>> {
    const parts: string[] = [];
    if (params !== undefined) {
      if (params.dept_id !== undefined) parts.push(`dept_id=${params.dept_id}`);
      if (params.owner_id !== undefined) parts.push(`owner_id=${params.owner_id}`);
      if (params.status !== undefined) parts.push(`status=${params.status}`);
      if (params.plan_id !== undefined) parts.push(`plan_id=${params.plan_id}`);
      if (params.overdue !== undefined) parts.push(`overdue=${params.overdue}`);
      if (params.include_subplans !== undefined) parts.push(`include_subplans=${params.include_subplans}`);
      if (params.page !== undefined) parts.push(`page=${params.page}`);
      if (params.size !== undefined) parts.push(`size=${params.size}`);
    }
    const qs = parts.join('&');
    return this.client.get<PagedResponse<TaskBrief>>(`/tasks${qs.length > 0 ? '?' + qs : ''}`);
  }

  /** GET /api/v1/tasks/{id} — 任务详情 */
  async detail(id: number): Promise<ApiResponse<TaskDetail>> {
    return this.client.get<TaskDetail>(`/tasks/${id}`);
  }

  /** POST /api/v1/tasks — 创建任务（响应在 data.task 下） */
  async create(data: CreateTaskRequest): Promise<ApiResponse<CreateTaskResponse>> {
    return this.client.post<CreateTaskResponse>('/tasks', data, { label: '新建任务' });
  }

  /** PATCH /api/v1/tasks/{id} — 更新任务（只改传了的值） */
  async update(id: number, data: UpdateTaskRequest): Promise<ApiResponse<TaskDetail>> {
    return this.client.patch<TaskDetail>(`/tasks/${id}`, data);
  }

  /** PUT /api/v1/tasks/{id}/status — 改状态 */
  async updateStatus(id: number, data: UpdateTaskStatusRequest): Promise<ApiResponse<TaskDetail>> {
    return this.client.put<TaskDetail>(`/tasks/${id}/status`, data);
  }

  /** DELETE /api/v1/tasks/{id} — 删除任务（软删除） */
  async delete_(id: number): Promise<ApiResponse<Record<string, never>>> {
    return this.client.delete_<Record<string, never>>(`/tasks/${id}`);
  }

  /** POST /api/v1/tasks/lookup — 批量查询任务（日历同步用） */
  async lookup(data: TaskLookupRequest): Promise<ApiResponse<TaskLookupResponse>> {
    return this.client.post<TaskLookupResponse>('/tasks/lookup', data);
  }
}
