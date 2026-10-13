export class AppColor {
  static readonly PRIMARY: string = '#00A9A7';
  static readonly PRIMARY_DARK: string = '#007F7D';
  static readonly PRIMARY_SOFT: string = '#DFF5F3';
  static readonly BACKGROUND: string = '#F3F8F7';
  static readonly SURFACE: string = '#FFFFFF';
  static readonly SURFACE_ALT: string = '#EAF3F2';
  static readonly TEXT: string = '#193331';
  static readonly TEXT_SECONDARY: string = '#5F7371';
  static readonly BORDER: string = '#D6E4E2';
  static readonly DANGER: string = '#C83B3B';
  static readonly DANGER_SOFT: string = '#FCE8E8';
  static readonly WARNING: string = '#A35A00';
  static readonly WARNING_SOFT: string = '#FFF1D9';
  static readonly SUCCESS: string = '#147A55';
  static readonly SUCCESS_SOFT: string = '#DFF3E9';
  static readonly INFO: string = '#315B96';
  static readonly INFO_SOFT: string = '#E7EFFB';
  static readonly DISABLED: string = '#AAB8B6';
}

export class AppSize {
  static readonly PAGE_PADDING: number = 16;
  static readonly CARD_RADIUS: number = 8;
  static readonly CONTROL_RADIUS: number = 8;
  static readonly GAP: number = 12;
  static readonly SECTION_GAP: number = 20;
  static readonly CONTROL_HEIGHT: number = 44;
}

export class AppText {
  static readonly TITLE: number = 24;
  static readonly HEADING: number = 18;
  static readonly SUBHEADING: number = 16;
  static readonly BODY: number = 15;
  static readonly CAPTION: number = 13;
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

export function appointmentStatusText(status: string): string {
  if (status === 'booked') {
    return '待就诊';
  }
  if (status === 'visiting') {
    return '就诊中';
  }
  if (status === 'done') {
    return '已完成';
  }
  if (status === 'cancelled') {
    return '已取消';
  }
  if (status === 'no_show') {
    return '爽约';
  }
  return status.length > 0 ? status : '未知状态';
}

export function appointmentStatusColor(status: string): string {
  if (status === 'booked') {
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
