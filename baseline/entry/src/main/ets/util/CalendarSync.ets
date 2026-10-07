/**
 * 作者：刘运泽
 * 功能：系统日历同步（加入/移除/对账，全天事件 + .ics 降级）
 * 修改记录：
 *   2026-09-16  首次编写（任务接入系统日历同步）
 *   2026-09-16  修复权限配置与 ArkTS 编译错误（review 第三轮）
 */
// 日历同步（客户端本地机制，服务端不存任何日历字段）。
// 映射表：task_id -> { event_id, cached_due_at, cached_status }
// - 触发：任务详情页「加入系统日历」按钮（单任务建/更新）；任务 done / 删除时自动移除事件。
// - 事件形式：全天事件（截止当天 00:00 ~ 次日 00:00）。
// - 权限被拒：提示用户；.ics 导出降级（TODO，见文件尾部说明）。
//
// ⚠️ 所有日历 API 调用都集中在这个文件，若 DevEco 报类型/签名不符，只改这里即可。

import { calendarManager } from '@kit.CalendarKit';
import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { TaskApi, TaskBrief, TaskDetail } from '../api/TaskApi';
import { CalendarMapStore, CalendarMapEntry } from '../store/CalendarMapStore';
import { fileIo as fs, picker } from '@kit.CoreFileKit';

const CAL_NAME = '社团管家';

interface TimeRange {
  start: number;
  end: number;
}

export interface CalendarSyncResult {
  created: number;
  updated: number;
  deleted: number;
}

export interface CalendarDiffResult {
  toCreate: TaskBrief[];
  toUpdate: TaskBrief[];
  toDelete: number[];
}

// ─── 纯比对逻辑（与存储 / 日历 API 无关，可单测） ───

export function shouldSyncToCalendar(task: TaskBrief): boolean {
  return task.due_at !== null && task.status !== 'done';
}

export function computeDiff(local: Record<string, CalendarMapEntry>, server: TaskBrief[]): CalendarDiffResult {
  const toCreate: TaskBrief[] = [];
  const toUpdate: TaskBrief[] = [];
  const toDelete: number[] = [];

  const serverMap: Record<string, TaskBrief> = {};
  for (const t of server) {
    serverMap[String(t.id)] = t;
  }

  const localKeys = Object.keys(local);
  for (let i = 0; i < localKeys.length; i++) {
    const taskId = Number(localKeys[i]);
    const entry = local[localKeys[i]];
    const found = serverMap[localKeys[i]];
    if (found === undefined || found.status === 'done') {
      toDelete.push(taskId);
    } else if (found.due_at !== entry.cached_due_at) {
      toUpdate.push(found);
    }
  }

  for (const t of server) {
    if (!shouldSyncToCalendar(t)) {
      continue;
    }
    if (local[String(t.id)] === undefined) {
      toCreate.push(t);
    }
  }

  const result: CalendarDiffResult = { toCreate: toCreate, toUpdate: toUpdate, toDelete: toDelete };
  return result;
}

function allDayRange(dueAt: string): TimeRange {
  const d = new Date(dueAt);
  const start = new Date(d.getFullYear(), d.getMonth(), d.getDate(), 0, 0, 0, 0).getTime();
  const end = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, 0, 0, 0, 0).getTime();
  const r: TimeRange = { start: start, end: end };
  return r;
}

async function ensureCalendarPermission(context: common.Context): Promise<boolean> {
  const atManager = abilityAccessCtrl.createAtManager();
  const perms: Array<Permissions> = ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR'];
  const result = await atManager.requestPermissionsFromUser(context, perms);
  const results = result.authResults;
  for (let i = 0; i < results.length; i++) {
    if (results[i] !== 0) {
      return false;
    }
  }
  return results.length > 0;
}

// ─── .ics 降级（日历权限被拒时的兜底） ───

function pad2(n: number): string {
  return n < 10 ? '0' + n : String(n);
}

function formatIcsDate(ms: number): string {
  const d = new Date(ms);
  return String(d.getFullYear()) + pad2(d.getMonth() + 1) + pad2(d.getDate());
}

function escapeIcsText(s: string): string {
  let r = s;
  r = r.replace(/\\/g, '\\\\');
  r = r.replace(/\n/g, '\\n');
  r = r.replace(/,/g, '\\,');
  r = r.replace(/;/g, '\\;');
  return r;
}

// 把单个任务拼成 .ics（VCALENDAR/VEVENT），全天事件用 DTSTART/DTEND 的 VALUE=DATE。
export function buildTaskIcs(id: number, title: string, desc: string, dueAt: string): string {
  const range = allDayRange(dueAt);
  const lines: string[] = [];
  lines.push('BEGIN:VCALENDAR');
  lines.push('VERSION:2.0');
  lines.push('PRODID:-//OpenHarmonyClub//Tasks//ZH');
  lines.push('BEGIN:VEVENT');
  lines.push('UID:task-' + String(id) + '-' + formatIcsDate(range.start) + '@club.local');
  lines.push('SUMMARY:' + escapeIcsText(title));
  if (desc.length > 0) {
    lines.push('DESCRIPTION:' + escapeIcsText(desc));
  }
  lines.push('DTSTART;VALUE=DATE:' + formatIcsDate(range.start));
  lines.push('DTEND;VALUE=DATE:' + formatIcsDate(range.end));
  lines.push('END:VEVENT');
  lines.push('END:VCALENDAR');
  return lines.join('\r\n');
}

// ─── 服务 ───

export class CalendarSyncService {
  private static instance: CalendarSyncService;
  private storeInited = false;
  private calendarMgr: calendarManager.CalendarManager | null = null;
  private calendar: calendarManager.Calendar | null = null;

  private constructor() {
    // 单例
  }

  static getInstance(): CalendarSyncService {
    if (!CalendarSyncService.instance) {
      CalendarSyncService.instance = new CalendarSyncService();
    }
    return CalendarSyncService.instance;
  }

  private async ensureStore(context: common.Context): Promise<void> {
    if (this.storeInited) {
      return;
    }
    await CalendarMapStore.getInstance().init(context);
    this.storeInited = true;
  }

  private async ensureCalendar(context: common.Context): Promise<void> {
    if (this.calendar !== null) {
      return;
    }
    this.calendarMgr = calendarManager.getCalendarManager(context);
    const account: calendarManager.CalendarAccount = {
      name: CAL_NAME,
      type: calendarManager.CalendarType.LOCAL,
      displayName: CAL_NAME
    };
    // CalendarManager 只有 getCalendar（按账户取单个日历），没有 getCalendars 批量接口；
    // 账户日历不存在时 getCalendar 会 reject，此时退化为 createCalendar。
    try {
      this.calendar = await this.calendarMgr.getCalendar(account);
    } catch (e) {
      this.calendar = await this.calendarMgr.createCalendar(account);
    }
  }

  private async doCreate(cal: calendarManager.Calendar, taskId: number, title: string, desc: string, dueAt: string): Promise<void> {
    const range = allDayRange(dueAt);
    const evt: calendarManager.Event = {
      title: title,
      type: calendarManager.EventType.NORMAL,
      startTime: range.start,
      endTime: range.end,
      isAllDay: true,
      description: desc
    };
    const eventId = await cal.addEvent(evt);
    const entry: CalendarMapEntry = { event_id: eventId, cached_due_at: dueAt, cached_status: 'todo' };
    await CalendarMapStore.getInstance().put(taskId, entry);
  }

  private async doUpdate(cal: calendarManager.Calendar, taskId: number, eventId: number, title: string, desc: string, dueAt: string): Promise<void> {
    const range = allDayRange(dueAt);
    const evt: calendarManager.Event = {
      id: eventId,
      title: title,
      type: calendarManager.EventType.NORMAL,
      startTime: range.start,
      endTime: range.end,
      isAllDay: true,
      description: desc
    };
    await cal.updateEvent(evt);
    const entry: CalendarMapEntry = { event_id: eventId, cached_due_at: dueAt, cached_status: 'todo' };
    await CalendarMapStore.getInstance().put(taskId, entry);
  }

  // 详情页按钮：单个任务建/更新全天事件，返回给用户的提示文案。
  async addOrUpdateTask(task: TaskDetail, context: common.Context): Promise<string> {
    if (task.due_at === null || task.status === 'done') {
      return '该任务无截止时间或已完成，无需加入日历';
    }
    await this.ensureStore(context);
    const granted = await ensureCalendarPermission(context);
    if (!granted) {
      return await this.exportTaskIcs(task, context);
    }
    await this.ensureCalendar(context);
    const cal = this.calendar;
    if (cal === null) {
      return '日历初始化失败';
    }

    const store = CalendarMapStore.getInstance();
    const existing = await store.get(task.id);
    try {
      if (existing !== undefined) {
        await this.doUpdate(cal, task.id, existing.event_id, task.title, task.desc, task.due_at);
        return '已更新系统日历';
      } else {
        await this.doCreate(cal, task.id, task.title, task.desc, task.due_at);
        return '已加入系统日历';
      }
    } catch (e) {
      const err = e as Error;
      return '写入日历失败：' + err.message;
    }
  }

  // 日历权限被拒时的降级：导出 .ics 让用户手动导入（用系统文档选择器选位置，写文件无需额外权限）。
  private async exportTaskIcs(task: TaskDetail, context: common.Context): Promise<string> {
    if (task.due_at === null) {
      return '该任务无截止时间，无法导出日历文件';
    }
    const content = buildTaskIcs(task.id, task.title, task.desc, task.due_at);
    try {
      const documentPicker = new picker.DocumentViewPicker(context);
      const saveOptions = new picker.DocumentSaveOptions();
      saveOptions.newFileNames = ['task_' + String(task.id) + '.ics'];
      const uris = await documentPicker.save(saveOptions);
      if (uris.length === 0) {
        return '已取消导出';
      }
      const file = await fs.open(uris[0], fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      await fs.write(file.fd, content);
      await fs.close(file);
      return '已导出 .ics 文件，请在文件管理器中打开并导入到日历';
    } catch (e) {
      const err = e as Error;
      return '导出 .ics 失败：' + err.message;
    }
  }

  // 任务 done / 删除时调用：移除对应日历事件 + 映射。
  async removeTask(taskId: number, context: common.Context): Promise<void> {
    await this.ensureStore(context);
    const store = CalendarMapStore.getInstance();
    const existing = await store.get(taskId);
    if (existing === undefined) {
      return;
    }
    if (this.calendar === null) {
      try {
        await this.ensureCalendar(context);
      } catch (e) {
        // 拿不到日历（权限被收回等）：至少把映射清掉
      }
    }
    if (this.calendar !== null) {
      try {
        await this.calendar.deleteEvent(existing.event_id);
      } catch (e) {
        // 事件可能已被用户手动删除，忽略
      }
    }
    await store.remove(taskId);
  }

  // 全量对账：调 lookup 找已被后端删除的任务（missing），并对 done / due_at 变了的任务做删/改。
  // 建议在「我的任务」页加载时后台调用（导航壳定了再接）。
  async reconcile(context: common.Context): Promise<CalendarSyncResult> {
    await this.ensureStore(context);
    const store = CalendarMapStore.getInstance();
    const result: CalendarSyncResult = { created: 0, updated: 0, deleted: 0 };
    const ids = await store.taskIds();
    if (ids.length === 0) {
      return result;
    }
    const api = new TaskApi();
    const resp = await api.lookup({ task_ids: ids });
    if (!resp.ok || resp.data === undefined) {
      return result;
    }

    for (const id of resp.data.missing) {
      await this.removeTask(id, context);
      result.deleted++;
    }

    for (const t of resp.data.items) {
      const existing = await store.get(t.id);
      if (existing === undefined) {
        continue;
      }
      if (t.status === 'done') {
        await this.removeTask(t.id, context);
        result.deleted++;
      } else if (t.due_at !== existing.cached_due_at) {
        if (t.due_at === null) {
          await this.removeTask(t.id, context);
          result.deleted++;
        } else if (this.calendar !== null) {
          await this.doUpdate(this.calendar, t.id, existing.event_id, t.title, '', t.due_at);
          result.updated++;
        }
      }
    }
    return result;
  }
}

// .ics 降级（已实现）：
//   日历权限被拒时，改用 DocumentViewPicker 让用户选保存位置，把当前任务导出成
//   .ics（VCALENDAR/VEVENT）让用户手动导入；写文件不需要额外权限（由 picker 授权）。
//   注意：picker / fileIo 的 API 签名若与 DevEco 实际不符（如 DocumentViewPicker 构造
//   是否传 context、save 的返回类型），只改本文件即可。
