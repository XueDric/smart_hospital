import { http } from '@kit.NetworkKit';
import { ApiConfig } from '../config/ApiConfig';
import { AppRouter, RouteName } from '../router/AppRouter';
import { SessionStore } from '../storage/SessionStore';
import { ApiError, ErrorCode } from './ApiError';

export enum HttpMethod {
  GET = 'GET',
  POST = 'POST',
  PUT = 'PUT',
  DELETE = 'DELETE'
}

export class HttpClient {
  private static instance: HttpClient = new HttpClient();

  static getInstance(): HttpClient {
    return HttpClient.instance;
  }

  async get(path: string, authenticated: boolean = true): Promise<Object> {
    return this.request(HttpMethod.GET, path, undefined, authenticated);
  }

  async post(path: string, body: Object, authenticated: boolean = true): Promise<Object> {
    return this.request(HttpMethod.POST, path, body, authenticated);
  }

  async put(path: string, body: Object, authenticated: boolean = true): Promise<Object> {
    return this.request(HttpMethod.PUT, path, body, authenticated);
  }

  async delete(path: string, authenticated: boolean = true): Promise<Object> {
    return this.request(HttpMethod.DELETE, path, undefined, authenticated);
  }

  async getRoot(path: string): Promise<Object> {
    return this.request(HttpMethod.GET, path, undefined, false);
  }

  buildHeaders(authenticated: boolean): Record<string, string> {
    const headers: Record<string, string> = {
      'Accept': 'application/json',
      'Content-Type': 'application/json',
      'X-Device-Id': SessionStore.getDeviceId(),
      'X-Device-Name': 'HarmonyOS'
    };
    if (authenticated && SessionStore.hasToken()) {
      headers['Authorization'] = `Bearer ${SessionStore.getToken()}`;
    }
    return headers;
  }

  private async request(method: HttpMethod, path: string, body: Object | undefined,
    authenticated: boolean): Promise<Object> {
    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: this.requestMethod(method),
        header: this.buildHeaders(authenticated),
        readTimeout: 20000,
        connectTimeout: 10000,
        usingCache: false,
        expectDataType: http.HttpDataType.STRING
      };
      if (body !== undefined) {
        options.extraData = JSON.stringify(body);
      }
      const response = await request.request(ApiConfig.url(path), options);
      const status = response.responseCode as number;
      const text = response.result as string;
      const retryAfter = this.readRetryAfter(response.header);
      return this.parseResponse(status, text, retryAfter);
    } catch (error) {
      if (error instanceof ApiError) {
        throw error;
      }
      throw new ApiError(ErrorCode.NETWORK_ERROR, (error as Error).message || '网络请求失败');
    } finally {
      request.destroy();
    }
  }

  private requestMethod(method: HttpMethod): http.RequestMethod {
    if (method === HttpMethod.POST) {
      return http.RequestMethod.POST;
    }
    if (method === HttpMethod.PUT) {
      return http.RequestMethod.PUT;
    }
    if (method === HttpMethod.DELETE) {
      return http.RequestMethod.DELETE;
    }
    return http.RequestMethod.GET;
  }

  private parseResponse(status: number, text: string, retryAfter: number): Object {
    if (text.length === 0) {
      if (status >= 200 && status < 300) {
        const empty: Record<string, Object> = {};
        return empty;
      }
      throw new ApiError(`HTTP_${status}`, `请求失败（HTTP ${status}）`, status, undefined, retryAfter);
    }

    let root: Record<string, Object>;
    try {
      root = JSON.parse(text) as Record<string, Object>;
    } catch (error) {
      throw new ApiError(ErrorCode.INVALID_RESPONSE, '服务端返回了无法解析的数据', status);
    }

    const okValue = root['ok'];
    if (okValue === undefined) {
      return this.parseFrameworkError(root, status);
    }

    const ok = okValue as boolean;
    if (!ok) {
      const errorObject = root['error'] as Record<string, Object>;
      if (errorObject === undefined) {
        throw new ApiError(`HTTP_${status}`, `请求失败（HTTP ${status}）`, status, undefined, retryAfter);
      }
      const code = this.asString(errorObject['code'], `HTTP_${status}`);
      const message = this.asString(errorObject['message'], '请求失败');
      const fieldsValue = errorObject['fields'];
      const fields = fieldsValue === undefined ? undefined : fieldsValue as Record<string, string>;
      this.handleAuthStatus(code, status);
      throw new ApiError(code, message, status, fields, retryAfter);
    }

    if (status < 200 || status >= 300) {
      throw new ApiError(`HTTP_${status}`, `请求失败（HTTP ${status}）`, status, undefined, retryAfter);
    }
    const data = root['data'];
    if (data === undefined || data === null) {
      const empty: Record<string, Object> = {};
      return empty;
    }
    return data;
  }

  private parseFrameworkError(root: Record<string, Object>, status: number): Object {
    const code = this.asString(root['code'], `HTTP_${status}`);
    const message = this.asString(root['message'], '');
    const path = this.asString(root['path'], '');
    if (code === '400' && message === 'Invalid JSON body') {
      throw new ApiError(ErrorCode.INVALID_RESPONSE, '请求内容格式错误', status);
    }
    if (status === 404 && path.length > 0) {
      throw new ApiError('HTTP_404', `接口不存在：${path}`, status);
    }
    throw new ApiError(code, message.length > 0 ? message : `请求失败（HTTP ${status}）`, status);
  }

  private handleAuthStatus(code: string, status: number): void {
    if (status === 401 || code === ErrorCode.AUTH_REQUIRED || code === ErrorCode.AUTH_TOKEN_EXPIRED) {
      const role = SessionStore.getRole();
      /*
       * ★ 2026-10-17（评审 P2-14）：`clearLogin()` 变异步了（要清系统安全存储里的令牌）。
       * 这里在**响应处理路径**上（不能 await），所以用 `.then` 把"清干净 → 回登录页"串起来；
       * 失败也照样跳转（本地内存里的令牌已经清空，界面必须跟着走）。
       */
      SessionStore.clearLogin().catch(() => {
      }).then(() => {
        if (role === 'doctor') {
          AppRouter.getInstance().replace(RouteName.DOCTOR_LOGIN);
        } else if (role === 'admin') {
          AppRouter.getInstance().replace(RouteName.ADMIN_LOGIN);
        } else {
          AppRouter.getInstance().replace(RouteName.LOGIN);
        }
      });
    }
  }

  private readRetryAfter(header: Object): number {
    const values = header as Record<string, string>;
    const rawValue = values['retry-after'] ?? values['Retry-After'];
    if (rawValue === undefined) {
      return 0;
    }
    const value = Number.parseInt(rawValue, 10);
    return Number.isNaN(value) ? 0 : value;
  }

  private asString(value: Object | undefined, fallback: string): string {
    return value === undefined ? fallback : String(value);
  }
}
