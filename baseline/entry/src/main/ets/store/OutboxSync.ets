// 负责人：彭翌菲
// 在应用恢复前台时逐条重试离线队列中的请求，
// 成功后移除任务，失败则保留并记录错误供后续重试。

import { HttpClient, ApiResponse } from '../api/HttpClient';
import { OutboxItem, OutboxStore } from './OutboxStore';

export interface OutboxSyncResult {
  synced: number;
  remaining: number;
  last_error: string;
}

export class OutboxSync {
  static async syncAll(): Promise<OutboxSyncResult> {
    const store = OutboxStore.getInstance();
    const items: OutboxItem[] = await store.list();
    let synced = 0;
    let lastError = '';
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      const response: ApiResponse<object> = await HttpClient.getInstance().replayOutbox(item);
      if (response.ok) {
        await store.remove(item.id);
        synced += 1;
        continue;
      }
      const message = response.error?.message ?? '同步失败';
      lastError = message;
      await store.markFailure(item.id, message);
      if (response.error?.code === 'AUTH_EXPIRED') {
        break;
      }
    }
    return {
      synced: synced,
      remaining: await store.count(),
      last_error: lastError,
    };
  }
}
