// 调试用：持久化自定义服务器地址（baseUrl），联调时改 IP 无需重新编译，
// 应用启动时读取并覆盖默认 BASE_URL，供后端同学与真机联调快速切换环境。

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREFS_NAME = 'server_config';
const KEY_BASE_URL = 'custom_base_url';

export class ServerConfigStore {
  private static instance: ServerConfigStore;

  private constructor() {
  }

  static getInstance(): ServerConfigStore {
    if (!ServerConfigStore.instance) {
      ServerConfigStore.instance = new ServerConfigStore();
    }
    return ServerConfigStore.instance;
  }

  /** 读取已保存的自定义 baseUrl，未设置时返回 null */
  async getCustomBaseUrl(context: common.Context): Promise<string | null> {
    try {
      const prefs = await preferences.getPreferences(context, { name: PREFS_NAME });
      const raw = await prefs.get(KEY_BASE_URL, '');
      if (typeof raw === 'string' && raw.trim().length > 0) {
        return raw.trim();
      }
    } catch (err) {
      // 读取失败按未设置处理，回退到默认地址
    }
    return null;
  }

  /** 保存自定义 baseUrl */
  async setCustomBaseUrl(context: common.Context, url: string): Promise<void> {
    const prefs = await preferences.getPreferences(context, { name: PREFS_NAME });
    await prefs.put(KEY_BASE_URL, url.trim());
    await prefs.flush();
  }

  /** 清除自定义 baseUrl，恢复默认地址 */
  async clearCustomBaseUrl(context: common.Context): Promise<void> {
    const prefs = await preferences.getPreferences(context, { name: PREFS_NAME });
    await prefs.delete(KEY_BASE_URL);
    await prefs.flush();
  }
}
