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
  /*
   * 乐观锁与修订历史（改进 3 / §5.29-§5.30，2026-10-15 起服务端启用）。
   * ⚠ 这两个 409 语义完全不同，**不能合并处理**：EMR_LOCKED 是"病历已定稿，得先去调解锁"
   * （医生自己没权限），EMR_CHANGED 才是"重读最新版再合并就能写"。服务端也正是为此
   * 把 EMR_LOCKED 的判定放在版本比较之前（否则客户端会把"要调解锁"误当成"刷新一下就好"）。
   */
  static readonly EMR_LOCKED: string = 'EMR_LOCKED';
  static readonly EMR_CHANGED: string = 'EMR_CHANGED';
  static readonly REVISION_NOT_FOUND: string = 'REVISION_NOT_FOUND';
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
    // ⚠ 这里是兜底文案：病历页对这两个 409 各自有更贴切的处理（EMR_CHANGED 要拉服务端最新版
    //   供逐段核对，EMR_LOCKED 只提示去调解锁），走不到这个分支。留着是为了别的页面
    //   （如版本历史）直接 userMessage() 时不至于露出服务端原文或空白。
    if (this.code === ErrorCode.EMR_LOCKED) {
      return '病历已定稿，需管理员解锁后才能修改';
    }
    if (this.code === ErrorCode.EMR_CHANGED) {
      return '病历已被其他端修改，请核对最新内容后再保存';
    }
    if (this.code === ErrorCode.REVISION_NOT_FOUND) {
      return '该病历没有这一版修订';
    }
    if (this.status === 401 || this.code === ErrorCode.AUTH_REQUIRED ||
      this.code === ErrorCode.AUTH_TOKEN_EXPIRED) {
      return '登录已过期，请重新登录';
    }
    if (this.code === ErrorCode.NETWORK_ERROR) {
      // 原始 message 保留供排障，界面统一使用中文连接失败提示。
      return '网络连接失败，请检查服务地址或网络';
    }
    return this.message || '请求失败，请稍后重试';
  }
}
