// 负责人：彭翌菲
// 封装全局 HTTP 请求、鉴权头注入、401/403 处理与错误码映射，
// 并为网络异常和各业务 API 提供统一的请求出口。
import { http } from '@kit.NetworkKit';
import { promptAction } from '@kit.ArkUI';
import { TokenStore } from '../store/TokenStore';
import { SessionStore } from '../store/SessionStore';
import { OutboxStore, EnqueueOutboxInput, OutboxItem } from '../store/OutboxStore';
import { replaceTo } from '../utils/RouterUtils';

export interface ApiResponse<T> {
  ok: boolean;
  data?: T;
  error?: ApiError;
}

export interface ApiError {
  code: string;
  message: string;
  fields?: Record<string, string>;
}

export interface PagedResponse<T> {
  items: T[];
  total: number;
  page?: number;
  size?: number;
}

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';

export interface OutboxMeta {
  label: string;
}

export interface RequestOptions {
  method?: HttpMethod;
  headers?: Record<string, string>;
  body?: object;
  outbox?: OutboxMeta;
  skipOutbox?: boolean;
}

export class ApiRequestError extends Error {
  code: string;
  statusCode: number;
  fields?: Record<string, string>;

  constructor(code: string, message: string, statusCode: number, fields?: Record<string, string>) {
    super(message);
    this.name = 'ApiRequestError';
    this.code = code;
    this.statusCode = statusCode;
    this.fields = fields;
  }
}

function showToast(message: string): void {
  try {
    promptAction.showToast({ message: message, duration: 2000 });
  } catch (_) {
  }
}

function friendlyMessage(statusCode: number, code: string): string {
  if (code === 'AUTH_BAD_CREDENTIALS') return '手机号或密码不正确';
  if (code === 'REGISTER_CODE_INVALID') return '注册口令不正确';
  if (code === 'VALIDATION_FAILED' || code === 'ALREADY_EXISTS') return '请检查填写内容';
  if (code === 'MEMBER_PENDING') return '你还未被分配部门与角色';
  if (code === 'MEMBER_DISABLED') return '该成员已退出社团';
  if (code === 'FORBIDDEN_ROLE') return '不能对同权限或更高权限的人执行此操作';
  if (code === 'FORBIDDEN_LAST_PRESIDENT') return '社团必须始终有一位会长';
  if (code === 'FORBIDDEN_NOT_IN_DEPT') return '只能操作本部门范围内的人与事';
  if (code === 'TOO_MANY_ATTEMPTS') return '尝试过于频繁，请稍后再试';
  if (code === 'BLOCKER_REQUIRED') return '进入阻塞状态必须填写阻塞原因';
  if (code === 'PLAN_CYCLE_DETECTED') return '不能移动到自身或其子课题下';
  if (code === 'PLAN_DEPTH_EXCEEDED') return '课题层级已达上限（6 层）';
  if (code === 'DEPT_NOT_EMPTY') return '该部门下还有成员或顶层课题';
  if (code === 'MEMBER_HAS_OPEN_TASKS') return '该成员名下还有未完成任务，需先转交';
  if (code === 'AI_RATE_LIMITED') return '操作过于频繁，请稍后再试';
  if (code.endsWith('_NOT_FOUND')) return '请求的内容不存在';
  if (statusCode >= 500) return '服务器开小差了，请稍后再试';
  if (statusCode === 403) return '无权限执行此操作';
  if (statusCode === 429) return '尝试过于频繁，请稍后再试';
  return '请求失败，请稍后重试';
}

export class HttpClient {
  private static instance: HttpClient;
  private baseUrl: string;
  private pendingGets: Map<string, Promise<ApiResponse<object>>> = new Map();

  private constructor() {
    this.baseUrl = '';
  }

  static getInstance(): HttpClient {
    if (!HttpClient.instance) {
      HttpClient.instance = new HttpClient();
    }
    return HttpClient.instance;
  }

  setBaseUrl(url: string): void {
    this.baseUrl = url;
  }

  getBaseUrl(): string {
    return this.baseUrl;
  }

  hasBaseUrl(): boolean {
    return this.baseUrl.length > 0;
  }

  clearBaseUrl(): void {
    this.baseUrl = '';
    this.pendingGets.clear();
  }

  private async request<T>(path: string, options?: RequestOptions): Promise<ApiResponse<T>> {
    const method: HttpMethod = options?.method ?? 'GET';
    if (!this.hasBaseUrl()) {
      return {
        ok: false,
        error: {
          code: 'SERVER_NOT_CONFIGURED',
          message: '请先设置服务端地址',
        },
      } as ApiResponse<T>;
    }
    const url = `${this.baseUrl}${path}`;
    const requestBody: string = options?.body === undefined ? '' : JSON.stringify(options.body);
    const httpRequest = http.createHttp();

    try {
      const headerObj: Record<string, string> = {};
      headerObj['Content-Type'] = 'application/json';
      if (options?.headers) {
        const keys = Object.keys(options.headers);
        for (let i = 0; i < keys.length; i++) {
          headerObj[keys[i]] = options.headers[keys[i]];
        }
      }

      const token = await TokenStore.getInstance().getToken();
      if (token !== null && token.length > 0) {
        headerObj['Authorization'] = `Bearer ${token}`;
      }

      const reqOptions: http.HttpRequestOptions = {
        header: headerObj as Object,
        expectDataType: http.HttpDataType.OBJECT,
      };
      if (method === 'PATCH') {
        reqOptions.method = http.RequestMethod.POST;
        reqOptions.customMethod = 'PATCH';
      } else {
        reqOptions.method = method as http.RequestMethod;
      }
      if (requestBody.length > 0) {
        reqOptions.extraData = requestBody;
      }

      const resp = await httpRequest.request(url, reqOptions);
      const statusCode = resp.responseCode;
      const resultData = this.asObject(resp.result);

      if (statusCode === 401) {
        const errObj = resultData?.['error'] as Record<string, Object> | undefined;
        const code: string = (errObj?.['code'] as string) ?? '';
        /*
         * 登录和本人改密都用 AUTH_BAD_CREDENTIALS + 401 表示“当前密码错误”，
         * 这不是 token 失效；只有其它 401 才按登录态过期处理。
         */
        if (code === 'AUTH_BAD_CREDENTIALS' || path === '/auth/login') {
          return {
            ok: false,
            error: {
              code: 'AUTH_BAD_CREDENTIALS',
              message: path === '/auth/password' ? '当前密码错误' : friendlyMessage(401, 'AUTH_BAD_CREDENTIALS'),
            },
          } as ApiResponse<T>;
        }
        await SessionStore.clearAll();
        showToast('登录已过期，请重新登录');
        replaceTo('pages/LoginPage');
        return {
          ok: false,
          error: { code: 'AUTH_EXPIRED', message: '登录已过期，请重新登录' },
        } as ApiResponse<T>;
      }

      if (statusCode >= 400) {
        return await this.handleError<T>(resultData, statusCode, path);
      }

      return {
        ok: true,
        data: resultData?.['data'] as T,
      } as ApiResponse<T>;
    } catch (err) {
      if (options?.outbox !== undefined && options.skipOutbox !== true) {
        const input: EnqueueOutboxInput = {
          method: method,
          path: path,
          body: requestBody,
          label: options.outbox.label,
        };
        await OutboxStore.getInstance().enqueue(input);
        return {
          ok: false,
          error: { code: 'NETWORK_QUEUED', message: '网络不可用，已保存到待同步' },
        } as ApiResponse<T>;
      }
      return {
        ok: false,
        error: {
          code: 'NETWORK_ERROR',
          message: '网络不可用，请检查服务端是否可访问',
        },
      } as ApiResponse<T>;
    } finally {
      httpRequest.destroy();
    }
  }

  private asObject(value: string | Object): Record<string, Object> | undefined {
    if (typeof value === 'object' && value !== null) {
      return value as Record<string, Object>;
    }
    return undefined;
  }

  private async handleError<T>(
    result: Record<string, Object> | undefined,
    statusCode: number,
    path: string
  ): Promise<ApiResponse<T>> {
    const errObj = result?.['error'] as Record<string, Object> | undefined;
    const code: string = (errObj?.['code'] as string) ?? 'UNKNOWN_ERROR';
    const message: string = friendlyMessage(statusCode, code);

    let fields: Record<string, string> | undefined;
    const rawFields = errObj?.['fields'];
    if (rawFields !== undefined && rawFields !== null && !Array.isArray(rawFields)) {
      fields = rawFields as Record<string, string>;
    }

    if (code === 'MEMBER_PENDING') {
      replaceTo('pages/PendingPage');
    } else if (code === 'MEMBER_DISABLED') {
      await SessionStore.clearAll();
      showToast('你已被移出社团');
      replaceTo('pages/LoginPage');
    } else if (statusCode === 403) {
      showToast(message);
    } else if (statusCode === 429 || code === 'TOO_MANY_ATTEMPTS') {
      showToast(message);
    }

    return {
      ok: false,
      error: { code, message, fields },
    } as ApiResponse<T>;
  }

  async replayOutbox(item: OutboxItem): Promise<ApiResponse<object>> {
    let body: object | undefined = undefined;
    if (item.body.length > 0) {
      body = JSON.parse(item.body) as object;
    }
    const options: RequestOptions = {
      method: item.method as HttpMethod,
      body: body,
      skipOutbox: true,
    };
    return this.request<object>(item.path, options);
  }

  async get<T>(path: string): Promise<ApiResponse<T>> {
    const pending = this.pendingGets.get(path);
    if (pending !== undefined) {
      return pending as Promise<ApiResponse<T>>;
    }
    const request = this.request<object>(path, { method: 'GET' });
    this.pendingGets.set(path, request);
    request.then((): void => {
      this.pendingGets.delete(path);
    }, (_reason: Error): void => {
      this.pendingGets.delete(path);
    });
    return request as Promise<ApiResponse<T>>;
  }

  async post<T>(path: string, body?: object, outbox?: OutboxMeta): Promise<ApiResponse<T>> {
    return this.request<T>(path, { method: 'POST', body: body, outbox: outbox });
  }

  async patch<T>(path: string, body?: object, outbox?: OutboxMeta): Promise<ApiResponse<T>> {
    return this.request<T>(path, { method: 'PATCH', body: body, outbox: outbox });
  }

  async put<T>(path: string, body?: object, outbox?: OutboxMeta): Promise<ApiResponse<T>> {
    return this.request<T>(path, { method: 'PUT', body: body, outbox: outbox });
  }

  async delete_<T>(path: string, outbox?: OutboxMeta): Promise<ApiResponse<T>> {
    return this.request<T>(path, { method: 'DELETE', outbox: outbox });
  }
}
