import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { util } from '@kit.ArkTS';

const STORE_NAME: string = 'smart_hospital_session';

const KEY_TOKEN: string = 'token';
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

  static initialize(context: common.UIAbilityContext): void {
    SessionStore.store = preferences.getPreferencesSync(context, { name: STORE_NAME });
    SessionStore.tokenValue = SessionStore.getString(KEY_TOKEN, '');
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
  }

  static getToken(): string {
    return SessionStore.tokenValue;
  }

  static hasToken(): boolean {
    return SessionStore.tokenValue.length > 0;
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

  static saveLogin(token: string, expiresAt: number, userId: number, role: string, refId: number,
    patientId: number, displayName: string): void {
    SessionStore.tokenValue = token;
    SessionStore.expiresAtValue = expiresAt;
    SessionStore.userIdValue = userId;
    SessionStore.roleValue = role;
    SessionStore.refIdValue = refId;
    SessionStore.patientIdValue = patientId;
    SessionStore.displayNameValue = displayName;
    SessionStore.putString(KEY_TOKEN, token);
    SessionStore.putNumber(KEY_EXPIRES_AT, expiresAt);
    SessionStore.putNumber(KEY_USER_ID, userId);
    SessionStore.putString(KEY_ROLE, role);
    SessionStore.putNumber(KEY_REF_ID, refId);
    SessionStore.putNumber(KEY_PATIENT_ID, patientId);
    SessionStore.putString(KEY_DISPLAY_NAME, displayName);
    SessionStore.flush();
  }

  static clearLogin(): void {
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
    SessionStore.flush();
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
