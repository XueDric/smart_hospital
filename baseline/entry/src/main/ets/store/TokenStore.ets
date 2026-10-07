// 负责人：彭翌菲
// 负责登录 token 的安全持久化、读取、迁移和清除，
// 为启动路由守卫、会话校验和退出登录提供登录状态来源。

/**
 * Token 使用 Asset Store 安全存储，不再落明文 Preferences。
 * 首次升级时会把旧版 Preferences 中的 token 迁移到 Asset Store 后删除。
 */
import { asset } from '@kit.AssetStoreKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TOKEN_ALIAS = 'club_auth_token';
const LEGACY_PREFERENCES_NAME = 'app_preferences';
const LEGACY_TOKEN_KEY = 'auth_token';
const LOG_DOMAIN = 0x0000;
const LOG_TAG = 'TokenStore';

function bytesOf(value: string): Uint8Array {
  return new util.TextEncoder().encodeInto(value);
}

function stringOf(value: Uint8Array): string {
  return new util.TextDecoder().decodeToString(value);
}

export class TokenStore {
  private static instance: TokenStore;
  private cachedToken: string | null = null;
  private initialized: boolean = false;

  private constructor() {
  }

  static getInstance(): TokenStore {
    if (!TokenStore.instance) {
      TokenStore.instance = new TokenStore();
    }
    return TokenStore.instance;
  }

  async init(context: common.Context): Promise<void> {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    await this.migrateLegacyToken(context);
  }

  private aliasAttrs(): asset.AssetMap {
    const attrs: asset.AssetMap = new Map();
    attrs.set(asset.Tag.ALIAS, bytesOf(TOKEN_ALIAS));
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    return attrs;
  }

  private async migrateLegacyToken(context: common.Context): Promise<void> {
    try {
      const options: preferences.Options = { name: LEGACY_PREFERENCES_NAME };
      const prefs = await preferences.getPreferences(context, options);
      const raw = await prefs.get(LEGACY_TOKEN_KEY, '');
      if (typeof raw === 'string' && raw.length > 0) {
        await this.setToken(raw);
        await prefs.delete(LEGACY_TOKEN_KEY);
        await prefs.flush();
      }
    } catch (err) {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'legacy migration skipped: %{public}s', JSON.stringify(err));
    }
  }

  async getToken(): Promise<string | null> {
    if (this.cachedToken !== null) {
      return this.cachedToken;
    }
    try {
      const query = this.aliasAttrs();
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const rows: asset.AssetMap[] = await asset.query(query);
      if (rows.length === 0) {
        return null;
      }
      const secret = rows[0].get(asset.Tag.SECRET);
      if (secret instanceof Uint8Array) {
        this.cachedToken = stringOf(secret);
        return this.cachedToken;
      }
    } catch (err) {
      const error = err as BusinessError;
      if (error.code !== 24000002) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'getToken failed: %{public}s', JSON.stringify(err));
      }
    }
    return null;
  }

  async setToken(token: string): Promise<void> {
    this.cachedToken = token;
    const attrs = this.aliasAttrs();
    attrs.set(asset.Tag.SECRET, bytesOf(token));
    attrs.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try {
      await asset.add(attrs);
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'setToken failed: %{public}s', JSON.stringify(err));
      throw new Error('安全存储写入失败');
    }
  }

  async clearToken(): Promise<void> {
    this.cachedToken = null;
    try {
      await asset.remove(this.aliasAttrs());
    } catch (err) {
      const error = err as BusinessError;
      if (error.code !== 24000002) {
        hilog.error(LOG_DOMAIN, LOG_TAG, 'clearToken failed: %{public}s', JSON.stringify(err));
      }
    }
  }

  async isLoggedIn(): Promise<boolean> {
    const token = await this.getToken();
    return token !== null && token.length > 0;
  }
}
