/**
 * 作者：刘运泽
 * 功能：日历映射表持久化（task_id ↔ event_id，Preferences）
 * 修改记录：
 *   2026-09-16  首次编写（任务接入系统日历同步）
 *
 * 日历映射表持久化：task_id -> { event_id, cached_due_at, cached_status }
 * 用 Preferences 存一份 JSON（与 TokenStore 同套路）。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const STORE_NAME = 'calendar_mapping';
const STORE_KEY = 'mapping_v1';

export interface CalendarMapEntry {
  event_id: number;
  cached_due_at: string | null;
  cached_status: string;
}

export class CalendarMapStore {
  private static instance: CalendarMapStore;
  private prefs: preferences.Preferences | null = null;
  private entries: Record<string, CalendarMapEntry> = {};

  private constructor() {
    // 单例
  }

  static getInstance(): CalendarMapStore {
    if (!CalendarMapStore.instance) {
      CalendarMapStore.instance = new CalendarMapStore();
    }
    return CalendarMapStore.instance;
  }

  async init(context: common.Context): Promise<void> {
    if (this.prefs) {
      return;
    }
    this.prefs = await preferences.getPreferences(context, STORE_NAME);
    const raw = await this.prefs.get(STORE_KEY, '{}');
    this.entries = this.parse(raw as string);
  }

  private parse(raw: string): Record<string, CalendarMapEntry> {
    try {
      return JSON.parse(raw) as Record<string, CalendarMapEntry>;
    } catch (e) {
      return {};
    }
  }

  async get(taskId: number): Promise<CalendarMapEntry | undefined> {
    return this.entries[String(taskId)];
  }

  async getAll(): Promise<Record<string, CalendarMapEntry>> {
    return this.entries;
  }

  async taskIds(): Promise<number[]> {
    const ids: number[] = [];
    const keys = Object.keys(this.entries);
    for (let i = 0; i < keys.length; i++) {
      ids.push(Number(keys[i]));
    }
    return ids;
  }

  async put(taskId: number, entry: CalendarMapEntry): Promise<void> {
    this.entries[String(taskId)] = entry;
    await this.save();
  }

  async remove(taskId: number): Promise<void> {
    const next: Record<string, CalendarMapEntry> = {};
    const keys = Object.keys(this.entries);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== String(taskId)) {
        next[keys[i]] = this.entries[keys[i]];
      }
    }
    this.entries = next;
    await this.save();
  }

  async clear(): Promise<void> {
    this.entries = {};
    if (this.prefs === null) {
      return;
    }
    await this.prefs.delete(STORE_KEY);
    await this.prefs.flush();
  }

  private async save(): Promise<void> {
    if (!this.prefs) {
      return;
    }
    await this.prefs.put(STORE_KEY, JSON.stringify(this.entries));
    await this.prefs.flush();
  }
}
