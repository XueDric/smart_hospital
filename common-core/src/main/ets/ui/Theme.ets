import { ThemeManager } from './ThemeManager';

export class AppColor {
  static get PRIMARY(): string {
    return ThemeManager.getInstance().palette().primary;
  }

  static get PRIMARY_DARK(): string {
    return ThemeManager.getInstance().palette().primaryDark;
  }

  static get PRIMARY_SOFT(): string {
    return ThemeManager.getInstance().palette().primarySoft;
  }

  static get BACKGROUND(): string {
    return ThemeManager.getInstance().palette().background;
  }

  static get SURFACE(): string {
    return ThemeManager.getInstance().palette().surface;
  }

  static get SURFACE_ALT(): string {
    return ThemeManager.getInstance().palette().surfaceAlt;
  }

  static get TEXT(): string {
    return ThemeManager.getInstance().palette().text;
  }

  static get TEXT_SECONDARY(): string {
    return ThemeManager.getInstance().palette().textSecondary;
  }

  static get BORDER(): string {
    return ThemeManager.getInstance().palette().border;
  }

  static get DANGER(): string {
    return ThemeManager.getInstance().palette().danger;
  }

  static get DANGER_SOFT(): string {
    return ThemeManager.getInstance().palette().dangerSoft;
  }

  static get WARNING(): string {
    return ThemeManager.getInstance().palette().warning;
  }

  static get WARNING_SOFT(): string {
    return ThemeManager.getInstance().palette().warningSoft;
  }

  static get SUCCESS(): string {
    return ThemeManager.getInstance().palette().success;
  }

  static get SUCCESS_SOFT(): string {
    return ThemeManager.getInstance().palette().successSoft;
  }

  static get INFO(): string {
    return ThemeManager.getInstance().palette().info;
  }

  static get INFO_SOFT(): string {
    return ThemeManager.getInstance().palette().infoSoft;
  }

  static get DISABLED(): string {
    return ThemeManager.getInstance().palette().disabled;
  }

  static get NAV_BACKGROUND(): string {
    return ThemeManager.getInstance().palette().navBackground;
  }

  static get NAV_TEXT(): string {
    return ThemeManager.getInstance().palette().navText;
  }
}

export class AppSize {
  static readonly BASE_GRID: number = 4;
  static readonly STEP_GRID: number = 8;
  static readonly TOUCH_MIN: number = 40;
  static readonly ICON_SM: number = 20;
  static readonly ICON_MD: number = 24;
  static readonly PAGE_PADDING: number = 16;
  static readonly CARD_RADIUS: number = 8;
  static readonly CONTROL_RADIUS: number = 8;
  static readonly GAP: number = 12;
  static readonly SECTION_GAP: number = 20;
  static readonly CONTROL_HEIGHT: number = 44;
}

export class AppText {
  static readonly DISPLAY: number = 30;
  static readonly GLYPH: number = 28;
  static readonly TITLE: number = 24;
  static readonly LEAD: number = 20;
  static readonly HEADING: number = 18;
  static readonly SUBHEADING: number = 16;
  static readonly BODY: number = 16;
  static readonly CAPTION: number = 13;
  static readonly MICRO: number = 12;
}

export function periodText(period: string): string {
  if (period === 'AM') {
    return '上午';
  }
  if (period === 'PM') {
    return '下午';
  }
  return period.length > 0 ? period : '时段未知';
}

/*
 * 就诊状态 → 中文。⚠ 2026-10-16（复核 D3）：服务端在改进 6 里把状态机扩到 7 个值
 * （新增 arrived/waiting），这里必须同步 —— 否则已到院/候诊中的单在界面上会显示成
 * 英文机器码（`arrived` / `waiting`），比不显示更让人困惑。
 * ⚠ 2026-10-16 晚（DevEco 模拟器实测发现）：此前 7 个值里有 4 个与服务端对不上 ——
 * booked「待就诊」/「已挂号」、visiting「就诊中」/「接诊中」、cancelled「已取消」/「已退号」、
 * no_show「爽约」/「已爽约」。现已按 `server/src/domain_emr.cj` 的 `visitStatusLabel` **逐字对齐**。
 * 状态码是机器判据，中文名只应该有一份权威实现；服务端下发了 `status_label` 时一律以它为准。
 */
export function appointmentStatusText(status: string): string {
  if (status === 'booked') {
    return '已挂号';
  }
  if (status === 'arrived') {
    return '已到院';
  }
  if (status === 'waiting') {
    return '候诊中';
  }
  if (status === 'visiting') {
    return '接诊中';
  }
  if (status === 'done') {
    return '已完成';
  }
  if (status === 'cancelled') {
    return '已退号';
  }
  if (status === 'no_show') {
    return '已爽约';
  }
  return status.length > 0 ? status : '未知状态';
}

export function appointmentStatusColor(status: string): string {
  if (status === 'booked') {
    return AppColor.INFO;
  }
  if (status === 'arrived' || status === 'waiting') {
    return AppColor.INFO;
  }
  if (status === 'visiting') {
    return AppColor.PRIMARY_DARK;
  }
  if (status === 'done') {
    return AppColor.SUCCESS;
  }
  if (status === 'cancelled' || status === 'no_show') {
    return AppColor.DANGER;
  }
  return AppColor.TEXT_SECONDARY;
}

export function recordStatusText(status: string): string {
  if (status === 'none') {
    return '无病历';
  }
  if (status === 'draft') {
    return '草稿';
  }
  if (status === 'locked') {
    return '已锁定';
  }
  return status.length > 0 ? status : '无病历';
}

export function recordStatusColor(status: string): string {
  if (status === 'locked') {
    return AppColor.SUCCESS;
  }
  if (status === 'draft') {
    return AppColor.WARNING;
  }
  return AppColor.TEXT_SECONDARY;
}

export function sourceText(source: string): string {
  if (source === 'rules') {
    return '规则引擎';
  }
  if (source === 'model') {
    return '模型增强';
  }
  if (source === 'model:invalid') {
    return '模型输出待复核';
  }
  return source.length > 0 ? source : '服务端结果';
}

export function reasonText(code: string): string {
  if (code === 'RED_FLAG') {
    return '危急征象';
  }
  if (code === 'NO_COMPLAINT') {
    return '需要补充主诉';
  }
  if (code === 'NEED_CLARIFY') {
    return '需要进一步说明';
  }
  if (code === 'NO_SUCH_DEPT') {
    return '暂无可匹配科室';
  }
  if (code === 'NO_BOOKABLE') {
    return '当前无可用号源';
  }
  if (code === 'ALTERNATIVES') {
    return '推荐备选号源';
  }
  if (code === 'OK') {
    return '匹配到可用号源';
  }
  return code.length > 0 ? code : '待确认';
}

export function formatEpoch(seconds: number): string {
  if (seconds <= 0) {
    return '时间未知';
  }
  const date = new Date(seconds * 1000);
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())} ` +
    `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

export function todayString(): string {
  const date = new Date();
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`;
}

export function nowToken(prefix: string): string {
  const random = Math.floor(Math.random() * 0xFFFFFFFF).toString(16).padStart(8, '0');
  return `${prefix}-${Date.now().toString(16)}-${random}`;
}

function pad2(value: number): string {
  return value < 10 ? `0${value}` : `${value}`;
}
