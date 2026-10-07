import { describe, it, expect } from '@ohos/hypium';
import { shouldSyncToCalendar } from '../main/ets/util/CalendarSync';
import type { TaskBrief, TaskStatus } from '../main/ets/api/TaskApi';

function task(status: TaskStatus, dueAt: string | null): TaskBrief {
  return {
    id: 1,
    title: 'test task',
    status: status,
    owner: null,
    dept: null,
    plan: null,
    due_at: dueAt,
    is_overdue: false,
    blocked: status === 'blocked',
    updated_at: ''
  };
}

export default function calendarSyncTest() {
  describe('CalendarSync', () => {
    it('shouldSyncToCalendar_requiresDueAt', 0, () => {
      expect(shouldSyncToCalendar(task('todo', null))).assertFalse();
      expect(shouldSyncToCalendar(task('doing', null))).assertFalse();
      expect(shouldSyncToCalendar(task('blocked', null))).assertFalse();
      expect(shouldSyncToCalendar(task('done', null))).assertFalse();
    });

    it('shouldSyncToCalendar_keepsOpenTasksWithDueAt', 0, () => {
      expect(shouldSyncToCalendar(task('todo', '2026-10-06T00:00:00'))).assertTrue();
      expect(shouldSyncToCalendar(task('doing', '2026-10-06T00:00:00'))).assertTrue();
      expect(shouldSyncToCalendar(task('blocked', '2026-10-06T00:00:00'))).assertTrue();
    });

    it('shouldSyncToCalendar_excludesDoneTasks', 0, () => {
      expect(shouldSyncToCalendar(task('done', '2026-10-06T00:00:00'))).assertFalse();
    });
  });
}
