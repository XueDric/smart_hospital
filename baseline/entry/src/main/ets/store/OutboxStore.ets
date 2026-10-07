// 负责人：彭翌菲
// 使用本地存储维护待同步的幂等写请求队列，
// 支持入队、列表、失败标记、移除和退出登录时清空。

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const STORE_NAME = 'app_outbox';
const STORE_KEY = 'outbox_v1';
const LOG_DOMAIN = 0x0000;
const LOG_TAG = 'OutboxStore';

export interface OutboxItem {
  id: string;
  method: string;
  path: string;
  body: string;
  label: string;
  created_at: number;
  attempts: number;
  last_error: string;
}

export interface EnqueueOutboxInput {
  method: string;
  path: string;
  body: string;
  label: string;
}

export class OutboxStore {
  private static instance: OutboxStore;
  private prefs: preferences.Preferences | null = null;
  private items: OutboxItem[] = [];

  private constructor() {
  }

  static getInstance(): OutboxStore {
    if (!OutboxStore.instance) {
      OutboxStore.instance = new OutboxStore();
    }
    return OutboxStore.instance;
  }

  async init(context: common.Context): Promise<void> {
    if (this.prefs !== null) {
      return;
    }
    try {
      const options: preferences.Options = { name: STORE_NAME };
      this.prefs = await preferences.getPreferences(context, options);
      const raw = await this.prefs.get(STORE_KEY, '[]');
      this.items = this.parse(raw);
    } catch (err) {
      this.prefs = null;
      this.items = [];
      hilog.error(LOG_DOMAIN, LOG_TAG, 'init failed: %{public}s', JSON.stringify(err));
    }
  }

  private parse(raw: preferences.ValueType): OutboxItem[] {
    if (typeof raw !== 'string') {
      return [];
    }
    try {
      return JSON.parse(raw) as OutboxItem[];
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'parse failed: %{public}s', JSON.stringify(err));
      return [];
    }
  }

  async list(): Promise<OutboxItem[]> {
    return this.items.slice();
  }

  async count(): Promise<number> {
    return this.items.length;
  }

  async enqueue(input: EnqueueOutboxInput): Promise<void> {
    const item: OutboxItem = {
      id: `${Date.now()}-${Math.floor(Math.random() * 1000000)}`,
      method: input.method,
      path: input.path,
      body: input.body,
      label: input.label,
      created_at: Date.now(),
      attempts: 0,
      last_error: '',
    };
    this.items.push(item);
    await this.save();
  }

  async remove(id: string): Promise<void> {
    const next: OutboxItem[] = [];
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].id !== id) {
        next.push(this.items[i]);
      }
    }
    this.items = next;
    await this.save();
  }

  async markFailure(id: string, message: string): Promise<void> {
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].id === id) {
        this.items[i].attempts += 1;
        this.items[i].last_error = message;
        break;
      }
    }
    await this.save();
  }

  async clear(): Promise<void> {
    this.items = [];
    if (this.prefs === null) {
      return;
    }
    try {
      await this.prefs.delete(STORE_KEY);
      await this.prefs.flush();
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'clear failed: %{public}s', JSON.stringify(err));
    }
  }

  private async save(): Promise<void> {
    if (this.prefs === null) {
      return;
    }
    try {
      await this.prefs.put(STORE_KEY, JSON.stringify(this.items));
      await this.prefs.flush();
    } catch (err) {
      hilog.error(LOG_DOMAIN, LOG_TAG, 'save failed: %{public}s', JSON.stringify(err));
    }
  }
}
