/**
 * 作者：刘运泽
 * 功能：日期时间格式化（YYYY-MM-DD / 带时分秒）
 * 修改记录：
 *   2026-09-16  新增（截止时间改为日期+时间选择器）
 */
/** 日期工具：把 Date 格式化成 YYYY-MM-DD（本地时区），用于截止时间的日期选择。 */

function pad2(n: number): string {
  return n < 10 ? '0' + n : String(n);
}

export function formatYmd(d: Date): string {
  return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
}

export function formatYmdHm(date: Date, hour: number, minute: number): string {
  return `${formatYmd(date)}T${pad2(hour)}:${pad2(minute)}:00`;
}
