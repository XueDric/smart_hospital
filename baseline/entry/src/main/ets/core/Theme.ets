/**
 * 设计与视觉规范 —— Design Tokens 唯一同源
 * 对应《鸿蒙俱乐部-全场景UI设计规格》Design Tokens · Light Theme
 */

export interface ColorTokens {
  canvas: string;
  surface: string;
  primary: string;
  primarySoft: string;
  primaryBorder: string;
  onPrimary: string;
  onSurface: string;
  overlay: string;
  divider: string;
  border: string;         // 次按钮 / 输入框默认描边
  control: string;        // 分段控件轨道 / 中性浅底
  textPrimary: string;
  textSecondary: string;
  textTertiary: string;
  textDisabled: string;
  danger: string;
  dangerBg: string;
  dangerBorder: string;
  inputBorder: string;
  sheetBg: string;
  blockedText: string;
  blockerFg: string;      // 阻塞原因正文
}

export const Color: ColorTokens = {
  canvas: '#F9FAFB',
  surface: '#FFFFFF',
  primary: '#2563EB',
  primarySoft: '#DBEAFE',
  primaryBorder: '#BFDBFE',
  onPrimary: '#FFFFFF',
  onSurface: '#111827',
  overlay: 'rgba(0,0,0,0.45)',
  divider: '#F3F4F6',
  border: '#E5E7EB',        // 次按钮 / 输入框默认描边
  control: '#F3F4F6',       // 分段控件轨道 / 中性浅底
  textPrimary: '#111827',
  textSecondary: '#374151',
  textTertiary: '#9CA3AF',
  textDisabled: '#D1D5DB',
  danger: '#DC2626',
  dangerBg: '#FEE2E2',
  dangerBorder: '#FECACA',
  inputBorder: '#E5E7EB',
  sheetBg: '#FFFFFF',
  blockedText: '#B45309',
  blockerFg: '#D97706',     // 阻塞原因正文
}

export class AppColor {
  static readonly PAGE_BG: string = Color.canvas;
  static readonly CARD_BG: string = Color.surface;
  static readonly TEXT_PRIMARY: string = Color.textPrimary;
  static readonly TEXT_SECONDARY: string = Color.textSecondary;
  static readonly TEXT_TERTIARY: string = Color.textTertiary;
  static readonly TEXT_DISABLED: string = Color.textDisabled;
  static readonly DIVIDER: string = Color.divider;
  static readonly PRIMARY: string = Color.primary;
  static readonly PRIMARY_SOFT: string = Color.primarySoft;
  static readonly PRIMARY_BORDER: string = Color.primaryBorder;
  static readonly ON_PRIMARY: string = Color.onPrimary;
  static readonly DANGER: string = Color.danger;
  static readonly DANGER_BORDER: string = Color.dangerBorder;
  static readonly INPUT_BORDER: string = Color.inputBorder;
  static readonly OVERLAY: string = Color.overlay;
  static readonly SHEET_BG: string = Color.sheetBg;
  static readonly BLOCKED_TEXT: string = Color.blockedText;
}

export interface StatusColorPair {
  fg: string;
  bg: string;
}

export interface StatusColorTokens {
  todo: StatusColorPair;
  overdue: StatusColorPair;
  blocked: StatusColorPair;
  doing: StatusColorPair;
  done: StatusColorPair;
  pending: StatusColorPair;
}

export const StatusColor: StatusColorTokens = {
  todo: { fg: '#6B7280', bg: '#F3F4F6' },
  overdue: { fg: '#DC2626', bg: '#FEE2E2' },
  blocked: { fg: '#D97706', bg: '#FEF3C7' },
  doing: { fg: '#2563EB', bg: '#DBEAFE' },
  done: { fg: '#16A34A', bg: '#DCFCE7' },
  pending: { fg: '#9333EA', bg: '#F3E8FF' },
}

export class Tone {
  static readonly OVERDUE: string = StatusColor.overdue.fg;
  static readonly OVERDUE_BG: string = StatusColor.overdue.bg;
  static readonly BLOCKED: string = StatusColor.blocked.fg;
  static readonly BLOCKED_BG: string = StatusColor.blocked.bg;
  static readonly DOING: string = StatusColor.doing.fg;
  static readonly DOING_BG: string = StatusColor.doing.bg;
  static readonly TODO: string = StatusColor.todo.fg;
  static readonly TODO_BG: string = StatusColor.todo.bg;
  static readonly DONE: string = StatusColor.done.fg;
  static readonly DONE_BG: string = StatusColor.done.bg;
  static readonly PENDING: string = StatusColor.pending.fg;
  static readonly PENDING_BG: string = StatusColor.pending.bg;

  static fg(name: string): string {
    if (name === 'overdue') return StatusColor.overdue.fg;
    if (name === 'blocked') return StatusColor.blocked.fg;
    if (name === 'doing') return StatusColor.doing.fg;
    if (name === 'done') return StatusColor.done.fg;
    if (name === 'pending') return StatusColor.pending.fg;
    return StatusColor.todo.fg;
  }

  static bg(name: string): string {
    if (name === 'overdue') return StatusColor.overdue.bg;
    if (name === 'blocked') return StatusColor.blocked.bg;
    if (name === 'doing') return StatusColor.doing.bg;
    if (name === 'done') return StatusColor.done.bg;
    if (name === 'pending') return StatusColor.pending.bg;
    return StatusColor.todo.bg;
  }
}

export interface FontSizeTokens {
  headline: number;
  title: number;
  subtitle: number;
  body: number;
  caption: number;
  micro: number;
  navLabel: number;
  numL: number;
  numM: number;
}

export const FontSize: FontSizeTokens = {
  headline: 22,
  title: 18,
  subtitle: 16,
  body: 14,
  caption: 12,
  micro: 11,
  navLabel: 10,
  numL: 22,
  numM: 12,
}

export interface FontFamilyTokens {
  sans: string;
  numeric: string;
}

export const FontFamily: FontFamilyTokens = {
  sans: 'Noto Sans SC',
  numeric: 'Inter',
}

export interface SpaceTokens {
  xs: number;
  sm: number;
  md: number;
  lg: number;
  xl: number;
  xxl: number;
  page: number;
  card: number;
  cardGap: number;
  section: number;
  XS: number;
  S: number;
  M: number;
  L: number;
  XL: number;
  XXL: number;
}

export const Space: SpaceTokens = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
  page: 16,
  card: 14,
  cardGap: 12,
  section: 24,
  XS: 4,
  S: 8,
  M: 12,
  L: 16,
  XL: 24,
  XXL: 32,
}

export interface RadiusTokens {
  card: number;
  button: number;
  input: number;
  pill: number;
  bottomNav: number;
  navItem: number;
  sheet: number;
}

export const Radius: RadiusTokens = {
  card: 14,
  button: 12,
  input: 10,
  pill: 999,
  bottomNav: 36,
  navItem: 26,
  sheet: 20,
}

export interface ShadowValue {
  radius: number;
  color: string;
  offsetX: number;
  offsetY: number;
}

export interface ShadowTokens {
  card: ShadowValue;
  L1: ShadowValue;
  L2: ShadowValue;
  L3: ShadowValue;
  primary: ShadowValue;
  pending: ShadowValue;
}

export const Shadow: ShadowTokens = {
  card: { radius: 12, color: '#14000000', offsetX: 0, offsetY: 2 },
  L1: { radius: 2, color: '#0D101828', offsetX: 0, offsetY: 1 },
  L2: { radius: 16, color: '#1A101828', offsetX: 0, offsetY: 4 },
  L3: { radius: 40, color: '#2E101828', offsetX: 0, offsetY: 18 },
  primary: { radius: 20, color: '#3D1F6FEB', offsetX: 0, offsetY: 8 },
  pending: { radius: 24, color: '#3D7A5AF8', offsetX: 0, offsetY: 10 },
}

export function statusLabel(status: string): string {
  if (status === 'todo') return '未开始'
  if (status === 'doing') return '进行中'
  if (status === 'blocked') return '阻塞中'
  if (status === 'done') return '已完成'
  if (status === 'pending') return '待分配'
  return status
}

export function statusFg(status: string): string {
  if (status === 'todo') return StatusColor.todo.fg
  if (status === 'doing') return StatusColor.doing.fg
  if (status === 'blocked') return StatusColor.blocked.fg
  if (status === 'done') return StatusColor.done.fg
  if (status === 'pending') return StatusColor.pending.fg
  return Color.textTertiary
}

export function statusBg(status: string): string {
  if (status === 'todo') return StatusColor.todo.bg
  if (status === 'doing') return StatusColor.doing.bg
  if (status === 'blocked') return StatusColor.blocked.bg
  if (status === 'done') return StatusColor.done.bg
  if (status === 'pending') return StatusColor.pending.bg
  return StatusColor.todo.bg
}

/**
 * 成员角色标签 —— 与服务端 5 档角色枚举一一对应。
 * 注意：角色枚举里**没有「会长」**（会长只能由会长移交产生，不能在分配/编辑里指定），
 * 所以这里只映射可被指派的 4 档 + 「未分配」（pending 账号 role 为 null）。
 */
export function roleLabel(role: string | null | undefined): string {
  if (role === 'president') return '会长'
  if (role === 'vice_president') return '副会长'
  if (role === 'lead') return '部长'
  if (role === 'vice_lead') return '副部长'
  if (role === 'member') return '成员'
  return '未分配'
}

/** 成员状态标签：active / pending / disabled 三种语义（P06 默认只列 active）。 */
export function memberStatusLabel(status: string): string {
  if (status === 'active') return '正常'
  if (status === 'pending') return '待分配'
  if (status === 'disabled') return '已退出'
  return status
}

/** 成员状态色：只有 active 用「正常」绿，pending 用待分配紫，disabled 用灰。 */
export function memberStatusFg(status: string): string {
  if (status === 'active') return StatusColor.done.fg
  if (status === 'pending') return StatusColor.pending.fg
  return Color.textTertiary
}

/**
 * 成员头像配色 —— 唯一同源：docs/role-avatar-colors.csv（原《新配色说明.csv》）
 * ---------------------------------------------------------------------------
 * 该 CSV 是设计侧交付物，规范说明见 docs/role-color-scheme.md。
 * CSV 定义 5 级青绿单色阶（级别 / 职位 / 主色 / 渐变（上→下） / 头像内文字色 / 描边色），
 * 级别越高颜色越深：L1 会长（最深）→ L5 成员（最浅）。
 *
 * 头像的规范画法（名录 P06 / 详情 P07 共用）—— 除投影外全部直接取自 CSV：
 *   · 填充 = 主色 → 渐变终点 的线性渐变（angle 180，即上→下，对应 CSV 的「渐变（上→下）」）；
 *   · 文字 = CSV「头像内文字色」（深底配白、浅底配青，CSV 已逐级给定）；
 *   · 描边 = CSV「描边色」实色 1px（每档都比渐变两端更亮，是设计给的高光圈）。
 *
 * CSV 只没给「投影 / 悬停」两条，按**不引入新色相**的原则派生：
 *   · shadow = 主色 + 33% 透明：角色色投影，名录悬停态与详情默认态共用；
 *   · 悬停描边沿用同一描边色，只把线宽由 1px 加到 2px（见 AvatarBorderWidth）。
 *     不能再"提亮描边"—— CSV 的描边色已经是每档最亮的颜色，比它更亮就得造新色相。
 * 行级悬停底色也不在这里派生 —— 沿用既有的中性规范 Color.canvas（见 ProfilePage），
 * 保证各角色行的悬停反馈强度一致，不会因为级别低就几乎看不见。
 *
 * ⚠ 改配色请先改 docs/role-avatar-colors.csv —— 那是设计侧交付物，本文件只是它的代码投影，
 *   不要在这里直接调色值，否则两处会漂移。
 */
export interface RoleAvatarToken {
  /** 对应 CSV「级别」列：CSV 写作 L1–L5，这里存其序号（1 最高；0 = CSV 未定义的兜底档）。 */
  level: number;
  /** 对应 CSV「职位」列。 */
  label: string;
  /** 对应 CSV「主色」——即「渐变（上→下）」的起点色。 */
  main: string;
  /** 对应 CSV「渐变（上→下）」的终点色。 */
  gradient: string;
  /** 对应 CSV「头像内文字色」。 */
  fg: string;
  /** 对应 CSV「描边色」。 */
  border: string;
  /** 派生：角色色投影（主色 33% 透明）。 */
  shadow: string;
}

/**
 * 头像描边线宽（vp）。
 * CSV 的描边色已是每档最亮的颜色，悬停无法再提亮描边，因此用"加粗一档"表达悬停；
 * 描边绘制在组件外框以内，1 → 2 不改变头像尺寸、不触发重排。
 */
export interface AvatarBorderWidthTokens {
  normal: number;
  hover: number;
}

export const AvatarBorderWidth: AvatarBorderWidthTokens = {
  normal: 1,
  hover: 2,
}

/** 由 CSV 五列 + 派生规则装配出一条完整 token，避免手抄派生值出错。 */
function roleAvatarFromCsv(level: number, label: string, main: string, gradient: string, fg: string,
  border: string): RoleAvatarToken {
  return {
    level: level,
    label: label,
    main: main,
    gradient: gradient,
    fg: fg,
    border: border,
    shadow: `${main}55`,
  };
}

/**
 * 角色 → 头像配色表。键名是服务端的 role 枚举值，可按需遍历/查找。
 * 取值请用下面的 roleAvatarToken()，不要直接索引，以免踩到未定义的 role。
 * 参数顺序与 CSV 列序一致：主色 / 渐变终点 / 头像内文字色 / 描边色。
 */
export const ROLE_AVATAR: Record<string, RoleAvatarToken> = {
  'president': roleAvatarFromCsv(1, '会长', '#063B52', '#0B6E8F', '#FFFFFF', '#2DD4BF'),
  'vice_president': roleAvatarFromCsv(2, '副会长', '#0B84B4', '#14B8A6', '#FFFFFF', '#5EEAD4'),
  'lead': roleAvatarFromCsv(3, '部长', '#14B8A6', '#5EEAD4', '#063B52', '#99F6E4'),
  'vice_lead': roleAvatarFromCsv(4, '副部长', '#34D399', '#A7F3D0', '#063B52', '#D9FBF0'),
  'member': roleAvatarFromCsv(5, '成员', '#D7FBF0', '#F5FEFC', '#0B6E8F', '#FFFFFF'),
}

/**
 * 兜底档：role 为 null（待分配账号）时使用。
 * CSV 未定义该档 —— 特意用**中性灰**而不是青绿阶，读作「还没有级别」。
 */
export const ROLE_AVATAR_UNASSIGNED: RoleAvatarToken =
  roleAvatarFromCsv(0, '未分配', '#94A3B8', '#CBD5E1', '#FFFFFF', '#94A3B8');

/** 角色 → 头像 token。未知/空 role 一律落到兜底档。 */
export function roleAvatarToken(role: string | null | undefined): RoleAvatarToken {
  if (role === undefined || role === null || role.length === 0) return ROLE_AVATAR_UNASSIGNED;
  if (role === 'president') return ROLE_AVATAR.president;
  if (role === 'vice_president') return ROLE_AVATAR.vice_president;
  if (role === 'lead') return ROLE_AVATAR.lead;
  if (role === 'vice_lead') return ROLE_AVATAR.vice_lead;
  if (role === 'member') return ROLE_AVATAR.member;
  return ROLE_AVATAR_UNASSIGNED;
}

/** 头像主色（= 渐变起点色）。保留旧函数名，既有调用无需改动。 */
export function roleAvatarColor(role: string | null | undefined): string {
  return roleAvatarToken(role).main;
}

/** 头像渐变终点色（CSV「渐变（上→下）」的终点）。 */
export function roleAvatarGradient(role: string | null | undefined): string {
  return roleAvatarToken(role).gradient;
}

/** 头像内文字色（CSV「头像内文字色」）。 */
export function roleAvatarFg(role: string | null | undefined): string {
  return roleAvatarToken(role).fg;
}

/** 头像默认描边色（CSV「描边色」）。 */
export function roleAvatarBorder(role: string | null | undefined): string {
  return roleAvatarToken(role).border;
}

/** 头像角色色投影（名录悬停态 / 详情默认态共用）。 */
export function roleAvatarShadow(role: string | null | undefined): string {
  return roleAvatarToken(role).shadow;
}


/** 角色胶囊前景色（名录右侧徽标 / 详情身份徽标，对应 Figma 的 Tailwind 角色色）。 */
export function roleBadgeFg(role: string | null | undefined): string {
  if (role === 'president') return '#4338CA'      // indigo-700
  if (role === 'vice_president') return '#9333EA' // purple-600
  if (role === 'lead') return '#15803D'           // green-700
  if (role === 'vice_lead') return '#B45309'      // amber-700
  if (role === 'member') return '#1D4ED8'         // blue-700
  return '#C084FC'                                // purple-400（未分配）
}

/** 角色胶囊底色（与 roleBadgeFg 成对使用）。 */
export function roleBadgeBg(role: string | null | undefined): string {
  if (role === 'president') return '#EEF2FF'      // indigo-100
  if (role === 'vice_president') return '#F3E8FF' // purple-100
  if (role === 'lead') return '#DCFCE7'           // green-100
  if (role === 'vice_lead') return '#FEF3C7'      // amber-100
  if (role === 'member') return '#DBEAFE'         // blue-100
  return '#FAF5FF'                                // purple-50（未分配）
}
