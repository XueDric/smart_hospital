// 负责人：杨睿（前端组长）
// AI 能力接口封装 —— 服务端 4 个智能接口（POST /ai/*）。
// 关键纪律：智能调用【不传】outbox（post 第三参留空），绝不进离线队列，见 docs/llm-frontend-guide.md §6。

import { HttpClient, ApiResponse } from './HttpClient';
import type { MemberBrief } from './AuthApi';

/** 智能结果来源（服务端 data.source）：model=模型给出 / fallback=退回规则·历史 / none=连兜底都没有 */
export type AiSource = 'model' | 'fallback' | 'none';

interface AiEnvelope {
  source: AiSource;
  note?: string;
}

/** /ai/task-suggest —— 创建任务时的建议（负责人 / 截止 / 拆分 / 依据） */
export interface TaskSuggestion extends AiEnvelope {
  owner: MemberBrief | null;
  due_at: string | null;      // ISO 8601 带时区
  granularity: string | null;
  reasons: string[];
}

/** /ai/notice-draft —— 起草通知（纯文本草稿，v1 无发送能力） */
export interface NoticeDraft extends AiEnvelope {
  title: string;
  body: string;
  audience: string;
  suggest_send_at: string | null;
}

export interface RetroCause {
  kind: string;
  detail: string;
}

/** /ai/retrospective 的延期归因块 */
export interface OverdueSummary {
  is_overdue: boolean;
  days: number;
  causes: RetroCause[];
}

/** /ai/retrospective —— 成效总结与延期归因（taskId / planId 二选一） */
export interface Retrospective extends AiEnvelope {
  summary: string;
  overdue: OverdueSummary;
  suggestions: string[];
}

export interface AskBasis {
  kind: string;
  ref: string;
}

/** /ai/ask —— 权限感知问答，回答下方必须展示 basis */
export interface AskAnswer extends AiEnvelope {
  answer: string;
  basis: AskBasis[];
}

/** /ai/agent 工具循环里的一步 —— 助手「查了什么」（allowed=false 是正常降级，不是错误） */
export interface AgentStep {
  tool: string;
  allowed: boolean;
  summary: string;
  payload: string;
}

/** proposal.diff 的一行：服务端读当前值算出的 from → to（G6，用户确认的是它） */
export interface AgentDiffLine {
  field: string;
  from: string;
  to: string;
}

/** /ai/agent 产出的写操作提议 —— 待用户确认，服务端此时【不执行】 */
export interface AgentProposal {
  tool: string;
  title: string;
  target: string;
  diff: AgentDiffLine[];
  token: string;
}

/** /ai/agent —— 智能体：先查数据再回答。basis 与 ask 同形状（服务端 18ec6b6 已对齐为 [{kind,ref}]），正常消费 */
export interface AgentAnswer extends AiEnvelope {
  answer: string;
  basis: AskBasis[];
  steps: AgentStep[];
  rounds: number;
  calls: number;
  proposal?: AgentProposal;
}

/** /ai/agent/confirm —— 确认并执行提议的结果 */
export interface AgentConfirmResult {
  tool: string;
  resource_id: number;
  summary: string;
}

// ─── 请求体（ArkTS 禁止内联对象字面量当类型声明，故全部抽成命名接口） ───

export interface TaskSuggestRequest {
  title: string;
  desc?: string;
  plan_id?: number;
  dept_id?: number;
}

export interface NoticeDraftRequest {
  task_id: number;
  audience: string;
}

/** TS 侧参数用 camelCase，线上请求体走 snake_case */
export interface RetrospectiveRequest {
  taskId?: number;
  planId?: number;
}

interface RetrospectiveBody {
  task_id?: number;
  plan_id?: number;
}

export interface AskRequest {
  question: string;
}

export interface AgentRequest {
  question: string;
}

export interface AgentConfirmRequest {
  token: string;
}

export class AiApi {
  private client: HttpClient = HttpClient.getInstance();

  /** POST /api/v1/ai/task-suggest —— 创建任务时的建议（不传 outbox） */
  async taskSuggest(data: TaskSuggestRequest): Promise<ApiResponse<TaskSuggestion>> {
    return this.client.post<TaskSuggestion>('/ai/task-suggest', data);
  }

  /** POST /api/v1/ai/notice-draft —— 起草通知 */
  async noticeDraft(taskId: number, audience: string): Promise<ApiResponse<NoticeDraft>> {
    const body: NoticeDraftRequest = { task_id: taskId, audience };
    return this.client.post<NoticeDraft>('/ai/notice-draft', body);
  }

  /** POST /api/v1/ai/retrospective —— 成效总结与延期归因（taskId / planId 二选一） */
  async retrospective(p: RetrospectiveRequest): Promise<ApiResponse<Retrospective>> {
    const body: RetrospectiveBody = {};
    if (p.taskId !== undefined) {
      body.task_id = p.taskId;
    }
    if (p.planId !== undefined) {
      body.plan_id = p.planId;
    }
    return this.client.post<Retrospective>('/ai/retrospective', body);
  }

  /** POST /api/v1/ai/ask —— 权限感知问答 */
  async ask(question: string): Promise<ApiResponse<AskAnswer>> {
    const body: AskRequest = { question };
    return this.client.post<AskAnswer>('/ai/ask', body);
  }

  /** POST /api/v1/ai/agent —— 智能体：工具循环，先查数据再回答（只读；可能带 proposal，不传 outbox） */
  async agent(question: string): Promise<ApiResponse<AgentAnswer>> {
    const body: AgentRequest = { question };
    return this.client.post<AgentAnswer>('/ai/agent', body);
  }

  /** POST /api/v1/ai/agent/confirm —— 确认并执行 AI 提议（写操作；失败必须显式展示，不传 outbox） */
  async confirm(token: string): Promise<ApiResponse<AgentConfirmResult>> {
    const body: AgentConfirmRequest = { token };
    return this.client.post<AgentConfirmResult>('/ai/agent/confirm', body);
  }
}
