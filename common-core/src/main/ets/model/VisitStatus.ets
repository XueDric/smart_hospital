/*
 * 就诊状态语义 —— 单一来源。
 *
 * 为什么有这个文件：
 *   服务端 `visitStatusLabel()`（server/src/domain_emr.cj:1455）是 7 态的唯一权威，
 *   但「哪些状态算进行中 / 可退 / 可重约」的**判定**此前散落在各端页面里硬编码。
 *   服务端把状态机从 5 态扩到 7 态（改进 6 新增 arrived/waiting）时只同步了展示层，
 *   判定层漏改 ⇒ 到院/候诊的单被错排进「历史记录」（缺陷 C1/C2/C3）。
 *   这里把判定收敛成谓词，页面只调用、不再自己写状态集合。
 *
 * 两条设计纪律：
 *   1. 谓词只返回布尔，**不返回中文** —— 中文一律消费服务端下发的 `status_label`
 *      （契约见 server/src/http_app.cj:631-636）。本地中文表只做字段缺失时的兜底。
 *   2. 未知状态按「安全的那一侧」处理：宁可当成进行中（单子不会从界面上消失），
 *      也不要当成历史（会让患者找不到自己的单）。同 P3-HANDOFF 的失败方向纪律。
 */

export class VisitStatus {
  /** 已挂号 —— 唯一可退号的状态 */
  static readonly BOOKED: string = 'booked';
  /** 已到院（改进 6 新增） */
  static readonly ARRIVED: string = 'arrived';
  /** 候诊中（改进 6 新增） */
  static readonly WAITING: string = 'waiting';
  /** 接诊中 */
  static readonly VISITING: string = 'visiting';
  /** 已完成 */
  static readonly DONE: string = 'done';
  /** 已退号 */
  static readonly CANCELLED: string = 'cancelled';
  /** 已爽约 */
  static readonly NO_SHOW: string = 'no_show';

  /**
   * 终态：单子已经走完，不再变化。**只有这三个值是终态。**
   * 将来加新状态时默认落入「进行中」，这是刻意选的失败方向。
   */
  static isTerminal(status: string): boolean {
    return status === VisitStatus.DONE || status === VisitStatus.CANCELLED ||
      status === VisitStatus.NO_SHOW;
  }

  /**
   * 进行中（属于「当前预约」）。
   * 判据是「**非终态即当前**」，取代原先各页面的白名单写法 `booked || visiting` ——
   * 白名单必然漏项，这正是 C1 的成因。
   */
  static isActive(status: string): boolean {
    return !VisitStatus.isTerminal(status);
  }

  /**
   * 该排班是否已被本人占用（用于防重复挂号）。
   * 与 `isActive` 当前同值，但语义不同，故意分开写：将来若出现「已是终态但仍占号」
   * 的形态，只需改这里，调用点不受影响。
   */
  static occupiesSchedule(status: string): boolean {
    return VisitStatus.isActive(status);
  }

  /**
   * 是否可退号。
   * ⚠ 这是**服务端语义的镜像**，权威在 `server/src/http_app.cj:575` 的 `canCancel()`
   *   —— 到院/候诊之后退号，服务端会回 409 `APPOINTMENT_NOT_CANCELLABLE`。
   *   服务端一旦放宽或收紧，此处必须同步（属「契约变更知会清单」覆盖项，见 docs/UI-DESIGN.md）。
   *   客户端**不得**为了让某个状态出现在退号入口里而放宽本谓词。
   */
  static isCancellable(status: string): boolean {
    return status === VisitStatus.BOOKED;
  }

  /**
   * 不可退号时给用户一句人话（可退时返回空串）。
   * 与服务端 409 文案同构：「退号单当前状态为【已到院】,不能退号」。
   * `label` 传服务端下发的 `status_label`，缺失时由调用方回落到本地兜底表。
   */
  static cancelBlockedReason(status: string, label: string): string {
    if (VisitStatus.isCancellable(status)) {
      return '';
    }
    const name = label.length > 0 ? label : status;
    return `当前状态为【${name}】，不能退号。`;
  }
}
