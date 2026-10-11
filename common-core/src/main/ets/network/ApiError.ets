export class ErrorCode {
  static readonly AUTH_REQUIRED: string = 'AUTH_REQUIRED';
  static readonly AUTH_BAD_CREDENTIALS: string = 'AUTH_BAD_CREDENTIALS';
  static readonly AUTH_TOKEN_EXPIRED: string = 'AUTH_TOKEN_EXPIRED';
  static readonly AUTH_RATE_LIMITED: string = 'AUTH_RATE_LIMITED';
  static readonly FORBIDDEN_ROLE: string = 'FORBIDDEN_ROLE';
  static readonly VALIDATION_FAILED: string = 'VALIDATION_FAILED';
  static readonly SLOT_GONE: string = 'SLOT_GONE';
  static readonly SCHEDULE_NOT_FOUND: string = 'SCHEDULE_NOT_FOUND';
  static readonly APPOINTMENT_NOT_FOUND: string = 'APPOINTMENT_NOT_FOUND';
  static readonly PREVISIT_NOT_FOUND: string = 'PREVISIT_NOT_FOUND';
  static readonly EMR_NOT_FOUND: string = 'EMR_NOT_FOUND';
  static readonly NETWORK_ERROR: string = 'NETWORK_ERROR';
  static readonly INVALID_RESPONSE: string = 'INVALID_RESPONSE';
  static readonly SSE_INCOMPLETE: string = 'SSE_INCOMPLETE';
}

export class ApiError extends Error {
  readonly code: string;
  readonly status: number;
  readonly fields?: Record<string, string>;
  readonly retryAfter?: number;

  constructor(code: string, message: string, status: number = 0, fields?: Record<string, string>,
    retryAfter?: number) {
    super(message);
    this.name = 'ApiError';
    this.code = code;
    this.status = status;
    this.fields = fields;
    this.retryAfter = retryAfter;
  }

  static from(error: Error): ApiError {
    if (error instanceof ApiError) {
      return error;
    }
    return new ApiError(ErrorCode.NETWORK_ERROR, error.message || '网络请求失败');
  }

  userMessage(): string {
    if (this.code === ErrorCode.AUTH_BAD_CREDENTIALS) {
      return '账号或密码错误';
    }
    if (this.code === ErrorCode.AUTH_RATE_LIMITED) {
      if (this.retryAfter !== undefined && this.retryAfter > 0) {
        return `尝试过于频繁，请在 ${this.retryAfter} 秒后重试`;
      }
      return '尝试过于频繁，请稍后再试';
    }
    if (this.code === ErrorCode.FORBIDDEN_ROLE) {
      return '当前账号无权使用患者端功能';
    }
    if (this.code === ErrorCode.SLOT_GONE) {
      return '号源刚刚被约满，请刷新后选择其他号源';
    }
    if (this.code === ErrorCode.PREVISIT_NOT_FOUND) {
      return '预问诊会话不存在或已过期';
    }
    if (this.code === ErrorCode.EMR_NOT_FOUND) {
      return '病历尚未提交，请稍后再查看';
    }
    if (this.status === 401 || this.code === ErrorCode.AUTH_REQUIRED ||
      this.code === ErrorCode.AUTH_TOKEN_EXPIRED) {
      return '登录已过期，请重新登录';
    }
    return this.message || '请求失败，请稍后重试';
  }
}
