import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { SecureStore } from './SecureStore';

const STORE_NAME: string = 'smart_hospital_session';

/*
 * ★ 2026-10-17（评审 P2-14）：令牌**不再**用 preferences 明文存。
 *
 * `KEY_TOKEN` 这个名字**保留**，但只剩一个用途：**迁移**旧版本已明文落盘的令牌
 * （读一次 → 写进安全存储 → 把 preferences 里的值清成空串）。新写入永远不碰它。
 *
 * ⚠ 为什么不在 `initialize` 里同步改写：`asset.*` 只有 Promise API，没有同步版；
 *   而 `HttpClient` 取令牌、`Index` 判断"是否已登录"都是**同步**调用。
 *   所以保留内存缓存 `tokenValue`，由 `ready()` 在启动时异步填满 ——
 *   入口必须在 `loadContent` 之前 `await SessionStore.ready()`，
 *   否则首帧会把"令牌还没读出来"误判成"未登录"（会闪一下登录页）。
 */
const KEY_TOKEN: string = 'token';
/* 安全存储里的别名：应用内唯一即可（Asset 按 bundle + 别名定位一条记录）。 */
const SECURE_ALIAS_TOKEN: string = 'smart_hospital.session.token';
const KEY_EXPIRES_AT: string = 'expires_at';
const KEY_USER_ID: string = 'user_id';
const KEY_ROLE: string = 'role';
const KEY_REF_ID: string = 'ref_id';
const KEY_PATIENT_ID: string = 'patient_id';
const KEY_DISPLAY_NAME: string = 'display_name';
const KEY_DEVICE_ID: string = 'device_id';
const KEY_API_MODE: string = 'api_mode';
const KEY_BASE_URL: string = 'base_url';
const KEY_PREVISIT_SESSION_ID: string = 'previsit_session_id';

export class SessionStore {
  private static store?: preferences.Preferences;
  private static tokenValue: string = '';
  private static expiresAtValue: number = 0;
  private static userIdValue: number = 0;
  private static roleValue: string = '';
  private static refIdValue: number = 0;
  private static patientIdValue: number = 0;
  private static displayNameValue: string = '';
  private static deviceIdValue: string = '';
  private static apiModeValue: string = 'live';
  private static baseUrlValue: string = 'http://127.0.0.1:8091';
  private static previsitSessionIdValue: string = '';
  /* 令牌是否真的存进了系统安全存储（false ⇒ 只在本进程内存里，重启要重登）。 */
  private static tokenPersistedSecurely: boolean = false;
  /* 启动时的"令牌已就绪"闸门；见 `ready()`。 */
  private static readyPromise?: Promise<void>;

  static initialize(context: common.UIAbilityContext): void {
    SessionStore.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    SessionStore.expiresAtValue = SessionStore.getNumber(KEY_EXPIRES_AT, 0);
    SessionStore.userIdValue = SessionStore.getNumber(KEY_USER_ID, 0);
    SessionStore.roleValue = SessionStore.getString(KEY_ROLE, '');
    SessionStore.refIdValue = SessionStore.getNumber(KEY_REF_ID, 0);
    SessionStore.patientIdValue = SessionStore.getNumber(KEY_PATIENT_ID, 0);
    SessionStore.displayNameValue = SessionStore.getString(KEY_DISPLAY_NAME, '');
    SessionStore.apiModeValue = SessionStore.getString(KEY_API_MODE, 'live');
    SessionStore.baseUrlValue = SessionStore.getString(KEY_BASE_URL, 'http://127.0.0.1:8091');
    SessionStore.previsitSessionIdValue = SessionStore.getString(KEY_PREVISIT_SESSION_ID, '');
    SessionStore.deviceIdValue = SessionStore.getString(KEY_DEVICE_ID, '');
    if (SessionStore.deviceIdValue.length === 0) {
      SessionStore.deviceIdValue = SessionStore.newDeviceId();
      SessionStore.putString(KEY_DEVICE_ID, SessionStore.deviceIdValue);
    }
    /*
     * 令牌是**异步**读出来的：preferences 里若还留着旧版本明文的 token，
     * 这里读完立刻搬进安全存储并清掉明文（一次性迁移，不丢用户已有登录）。
     */
    SessionStore.readyPromise = SessionStore.loadToken();
  }

  /*
   * 等令牌读完。**入口必须 await 它**（在 `loadContent` 之前），
   * 否则 `Index.aboutToAppear` 里 `hasToken()` 会读到空串、把用户踢回登录页。
   * 没调过 `initialize` 时直接 resolve（不阻塞）。
   */
  static ready(): Promise<void> {
    if (SessionStore.readyPromise === undefined) {
      return Promise.resolve();
    }
    return SessionStore.readyPromise;
  }

  /* 令牌是否已安全落盘（false = 只在内存；UI 可据此提示"下次需重新登录"）。 */
  static isTokenPersistedSecurely(): boolean {
    return SessionStore.tokenPersistedSecurely;
  }

  private static async loadToken(): Promise<void> {
    let token: string = await SecureStore.get(SECURE_ALIAS_TOKEN);
    SessionStore.tokenPersistedSecurely = token.length > 0;
    if (token.length === 0) {
      /* 迁移：旧版本的明文令牌（存在就搬走，并**立刻**把明文清空）。 */
      const legacy: string = SessionStore.getString(KEY_TOKEN, '');
      if (legacy.length > 0) {
        const ok: boolean = await SecureStore.put(SECURE_ALIAS_TOKEN, legacy);
        SessionStore.putString(KEY_TOKEN, '');
        SessionStore.flush();
        if (ok) {
          token = legacy;
          SessionStore.tokenPersistedSecurely = true;
        } else {
          /* 搬不动就**只用内存**，不把明文留着（宁可让用户重登一次）。 */
          token = legacy;
          SessionStore.tokenPersistedSecurely = false;
        }
      }
    }
    SessionStore.tokenValue = token;
  }

  static getToken(): string {
    return SessionStore.tokenValue;
  }

  static hasToken(): boolean {
    return SessionStore.tokenValue.length > 0;
  }

  /*
   * ★ 2026-10-17 复查：服务端会**滑动续期**（每次鉴权请求都可能把 expires_at 推后，
   * 见 server/src/acceptance.cj 的 AC-14「有效期必须回给客户端」），
   * 但客户端只在登录那一刻取过一次有效期 ⇒ 有效期一过，冷启动就把仍然有效的会话
   * 挡在登录页前。这里补一条回写 + 一个统一的"令牌是否还有效"判据。
   */
  static updateExpiresAt(expiresAt: number): void {
    if (expiresAt <= 0 || expiresAt === SessionStore.expiresAtValue) {
      return;
    }
    SessionStore.expiresAtValue = expiresAt;
    SessionStore.putNumber(KEY_EXPIRES_AT, expiresAt);
    SessionStore.flush();
  }

  /** 有令牌且（服务端给过有效期时）尚未过期。过期判据统一收在这里，别在页面里各写一遍。 */
  static hasValidToken(): boolean {
    if (!SessionStore.hasToken()) {
      return false;
    }
    const expiresAt: number = SessionStore.expiresAtValue;
    if (expiresAt <= 0) {
      return true;
    }
    return expiresAt > Math.floor(Date.now() / 1000);
  }

  static getRole(): string {
    return SessionStore.roleValue;
  }

  static getPatientId(): number {
    return SessionStore.patientIdValue;
  }

  static getUserId(): number {
    return SessionStore.userIdValue;
  }

  static getRefId(): number {
    return SessionStore.refIdValue;
  }

  static getDisplayName(): string {
    return SessionStore.displayNameValue;
  }

  /*
   * ★ 2026-10-17：「同步身份信息」原先只刷角色/档案号，**不刷显示名**，
   * 于是改名后界面仍显示登录那一刻的旧名字（实测："我的"页显示 4 个问号，
   * 而服务端 `/api/v1/auth/me` 早已返回正确姓名）。这里补一个显式 setter，
   * 让"同步"真的同步，而不是只同步一半。
   */
  static setDisplayName(displayName: string): void {
    SessionStore.displayNameValue = displayName;
    SessionStore.putString(KEY_DISPLAY_NAME, displayName);
    SessionStore.flush();
  }

  static getExpiresAt(): number {
    return SessionStore.expiresAtValue;
  }

  static getDeviceId(): string {
    return SessionStore.deviceIdValue;
  }

  static getApiMode(): string {
    return SessionStore.apiModeValue;
  }

  static getBaseUrl(): string {
    return SessionStore.baseUrlValue;
  }

  static getPrevisitSessionId(): string {
    return SessionStore.previsitSessionIdValue;
  }

  static setPrevisitSessionId(sessionId: string): void {
    SessionStore.previsitSessionIdValue = sessionId;
    SessionStore.putString(KEY_PREVISIT_SESSION_ID, sessionId);
    SessionStore.flush();
  }

  static setApiConfig(mode: string, baseUrl: string): void {
    SessionStore.apiModeValue = mode;
    SessionStore.baseUrlValue = baseUrl;
    SessionStore.putString(KEY_API_MODE, mode);
    SessionStore.putString(KEY_BASE_URL, baseUrl);
    SessionStore.flush();
  }

  /*
   * 保存登录态。★ 2026-10-17（P2-14）：令牌走**安全存储**，其余（非敏感）字段仍走
   * preferences（这些是"下次打开要显示什么"的界面状态，泄露不构成凭证泄露）。
   *
   * ⚠ 改成 `async` 的原因：Asset 只有 Promise API。调用方**必须 await** ——
   *   否则用户登录后立刻杀进程，令牌可能还没落到安全存储（重启就丢登录）。
   *   这是"可靠性"与"同步 API 顺手"之间的取舍，选了可靠性。
   */
  static async saveLogin(token: string, expiresAt: number, userId: number, role: string,
    refId: number, patientId: number, displayName: string): Promise<void> {
    SessionStore.tokenValue = token;
    SessionStore.expiresAtValue = expiresAt;
    SessionStore.userIdValue = userId;
    SessionStore.roleValue = role;
    SessionStore.refIdValue = refId;
    SessionStore.patientIdValue = patientId;
    SessionStore.displayNameValue = displayName;
    /*
     * ⚠ 显式把旧键清空：老版本升级上来时 preferences 里可能还留着明文令牌，
     *   不清就等于"新代码在存安全的、旧明文还在盘上"（评审要是翻出来照样算没修）。
     */
    SessionStore.putString(KEY_TOKEN, '');
    SessionStore.putNumber(KEY_EXPIRES_AT, expiresAt);
    SessionStore.putNumber(KEY_USER_ID, userId);
    SessionStore.putString(KEY_ROLE, role);
    SessionStore.putNumber(KEY_REF_ID, refId);
    SessionStore.putNumber(KEY_PATIENT_ID, patientId);
    SessionStore.putString(KEY_DISPLAY_NAME, displayName);
    SessionStore.flush();
    SessionStore.tokenPersistedSecurely = await SecureStore.put(SECURE_ALIAS_TOKEN, token);
  }

  /*
   * 清登录态（登出 / 令牌失效）。
   * ⚠ 必须是 async 且调用方要 await：登出的语义是"凭证不能再用了"，
   *   如果删安全存储这步还在飞、UI 已经跳回登录页，那么"别人拿到手机
   *   立刻杀掉进程"仍可能带着旧令牌 —— 删干净再走。
   */
  static async clearLogin(): Promise<void> {
    SessionStore.tokenValue = '';
    SessionStore.expiresAtValue = 0;
    SessionStore.userIdValue = 0;
    SessionStore.roleValue = '';
    SessionStore.refIdValue = 0;
    SessionStore.patientIdValue = 0;
    SessionStore.displayNameValue = '';
    SessionStore.putString(KEY_TOKEN, '');
    SessionStore.putNumber(KEY_EXPIRES_AT, 0);
    SessionStore.putNumber(KEY_USER_ID, 0);
    SessionStore.putString(KEY_ROLE, '');
    SessionStore.putNumber(KEY_REF_ID, 0);
    SessionStore.putNumber(KEY_PATIENT_ID, 0);
    SessionStore.putString(KEY_DISPLAY_NAME, '');
    /*
     * ★ 2026-10-17 复查：原来只有 ProfilePage 手工清预问诊会话，
     * 别的登出路径（HttpClient 的 401、管理端登出）都不清 ⇒ 换账号后首进预问诊
     * 会先拿旧 session_id 打一次 404。服务端按患者归属校验，不会串数据，
     * 但这属于"本该在这里清"的状态。
     */
    SessionStore.previsitSessionIdValue = '';
    SessionStore.putString(KEY_PREVISIT_SESSION_ID, '');
    SessionStore.flush();
    SessionStore.tokenPersistedSecurely = false;
    await SecureStore.remove(SECURE_ALIAS_TOKEN);
  }

  private static getString(key: string, defaultValue: string): string {
    if (SessionStore.store === undefined) {
      return defaultValue;
    }
    const value = SessionStore.store.getSync(key, defaultValue);
    return typeof value === 'string' ? value : defaultValue;
  }

  private static getNumber(key: string, defaultValue: number): number {
    if (SessionStore.store === undefined) {
      return defaultValue;
    }
    const value = SessionStore.store.getSync(key, defaultValue);
    return typeof value === 'number' ? value : defaultValue;
  }

  private static putString(key: string, value: string): void {
    if (SessionStore.store !== undefined) {
      SessionStore.store.putSync(key, value);
    }
  }

  private static putNumber(key: string, value: number): void {
    if (SessionStore.store !== undefined) {
      SessionStore.store.putSync(key, value);
    }
  }

  private static flush(): void {
    if (SessionStore.store !== undefined) {
      SessionStore.store.flush().catch(() => {
      });
    }
  }

  private static newDeviceId(): string {
    const random = Math.floor(Math.random() * 0xFFFFFFFF).toString(16);
    return `${Date.now().toString(16)}-${random.padStart(8, '0')}`.substring(0, 64);
  }
}
