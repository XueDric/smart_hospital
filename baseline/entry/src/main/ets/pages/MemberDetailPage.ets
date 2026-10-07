/**
 * 成员详情页 MemberDetailPage—— 设计规格 P07
 * 郭俊杰 负责
 * 读：
 *   GET /api/v1/members/{id}                → member + stats
 *                                             （owned_tasks / open_tasks / done_tasks / overdue_tasks / owned_plans）
 *   GET /api/v1/tasks?owner_id={id}         → 该成员负责的任务（P07 注释「用 owner_id 反查」）
 *   GET /api/v1/members?role=president&status=active → 仅供「是否唯一会长」判断用
 *
 * 写（全部权限驱动显隐，服务端仍会做最终校验）：
 *   PATCH /api/v1/members/{id}               → 编辑姓名（需 manage_members + 同权保护）
 *   POST  /api/v1/members/{id}/reset-password → 一次性临时密码（P07 含此按钮，接口与 B 的管理页共用）
 *   POST  /api/v1/members/{id}/disable       → 移出社团（名下有未完成任务 → 409 MEMBER_HAS_OPEN_TASKS）
 *
 * 权限铁律（P07：「不能对同权限或更高权限的人执行上述操作，会长也不能重置自己」）：
 *   判定只走 store/PermissionStore 的 can() / isLastPresident()，本页不自己比角色档位。
 *
 * 隐私：**详情页不显示手机号** —— MemberBrief 不下发 phone（api-design §3.2「名录不含手机号」）。
 */
import { promptAction } from '@kit.ArkUI'
import { MemberApi, MemberStats } from '../api/MemberApi'
import type { MemberBrief, MemberSelf } from '../api/AuthApi'
import { TaskApi, TaskBrief } from '../api/TaskApi'
import { can, isLastPresident, PermissionStore } from '../store/PermissionStore'
import { StatusChip } from '../components/StatusChip'
import {
  AvatarBorderWidth, Color, FontSize, Radius, Shadow, Space, StatusColor,
  memberStatusFg, memberStatusLabel,
  roleAvatarBorder, roleAvatarColor, roleAvatarFg, roleAvatarGradient, roleAvatarShadow,
  roleBadgeBg, roleBadgeFg, roleLabel
} from '../core/Theme'

/**
 * 头像直径（vp）—— 详情页大号头像。
 * 名录行是 40，这里是 64，比例（字号/直径 ≈ 0.44）与名录保持一致。
 */
const AVATAR_SIZE: number = 64

/** 一次拉全「本部门/全社团」的会长，只为唯一会长判定；50 足够 */
const PRESIDENT_QUERY_SIZE: number = 50
/** 该成员名下任务的拉取上限（服务端单页上限 200） */
const TASK_QUERY_SIZE: number = 200
/** 移出确认弹窗里最多列几条未完成任务 */
const BLOCKER_PREVIEW_LIMIT: number = 3

@Component
export default struct MemberDetailPage {
  @Prop @Watch('onMemberIdChange') memberId: number = 0
  /** 改名 / 移出成功后通知 Index 刷新名录 */
  onChanged?: () => void

  @State member: MemberBrief | null = null
  @State stats: MemberStats | null = null
  @State tasks: TaskBrief[] = []
  @State taskTotal: number = 0
  @State loading: boolean = true
  @State errorMsg: string = ''

  // 弹窗态
  @State showEditNameDialog: boolean = false
  @State showResetPasswordDialog: boolean = false
  @State showDisableDialog: boolean = false
  @State editingName: string = ''
  @State tempPassword: string = ''
  /** 弹窗内的内联错误（比 toast 更容易看懂失败原因） */
  @State actionError: string = ''
  /** 提交中，防手抖重复点 */
  @State submitting: boolean = false
  /** 移出弹窗里预展示的未完成任务 */
  @State blockerTasks: TaskBrief[] = []

  private memberApi: MemberApi = new MemberApi()
  private taskApi: TaskApi = new TaskApi()
  private permissionStore: PermissionStore = PermissionStore.getInstance()
  /** active 会长列表（唯一会长判定） */
  private presidents: MemberBrief[] = []

  aboutToAppear(): void {
    this.load()
  }

  /** memberId 变化时重新拉取（正常情况下 Index 会重建本组件，这里是兜底） */
  onMemberIdChange(): void {
    this.load()
  }

  // ─── 数据 ───

  private async load(): Promise<void> {
    if (this.memberId <= 0) {
      this.loading = false
      this.errorMsg = '缺少成员 id'
      return
    }
    this.loading = true
    this.errorMsg = ''
    await this.loadDetail()
    if (this.member !== null) {
      await this.loadTasks()
      await this.loadPresidents()
    }
    this.loading = false
  }

  private async loadDetail(): Promise<void> {
    const resp = await this.memberApi.detail(this.memberId)
    if (resp.ok && resp.data !== undefined) {
      this.member = resp.data.member
      this.stats = resp.data.stats
    } else {
      this.errorMsg = resp.error?.message ?? '加载成员详情失败'
    }
  }

  /** 名下任务：未完成在前、已完成在后（P07「查看某人负责的任务」） */
  private async loadTasks(): Promise<void> {
    const resp = await this.taskApi.list({ owner_id: this.memberId, size: TASK_QUERY_SIZE })
    if (resp.ok && resp.data !== undefined) {
      const items: TaskBrief[] = resp.data.items
      const open: TaskBrief[] = items.filter((t: TaskBrief): boolean => t.status !== 'done')
      const done: TaskBrief[] = items.filter((t: TaskBrief): boolean => t.status === 'done')
      this.tasks = open.concat(done)
      this.taskTotal = resp.data.total
    }
  }

  /** 只要会长，用于 isLastPresident —— 别为了判断一个人拉全社团名单 */
  private async loadPresidents(): Promise<void> {
    const resp = await this.memberApi.list({ role: 'president', status: 'active', size: PRESIDENT_QUERY_SIZE })
    if (resp.ok && resp.data !== undefined) {
      this.presidents = resp.data.items
    }
  }

  private openTasks(): TaskBrief[] {
    return this.tasks.filter((t: TaskBrief): boolean => t.status !== 'done')
  }

  // ─── 权限判定（唯一入口）───

  private currentUser(): MemberSelf | null {
    return this.permissionStore.userInfo
  }

  /** 编辑姓名：manage_members + 同权保护（部长/副部长还限本部门） */
  canEditName(): boolean {
    const user: MemberSelf | null = this.currentUser()
    const target: MemberBrief | null = this.member
    if (user === null || target === null) {
      return false
    }
    return can(user, 'EditName', target)
  }

  /** 重置密码：manage_members + 同权保护；can() 已保证「自己不能重置自己」 */
  canResetPassword(): boolean {
    const user: MemberSelf | null = this.currentUser()
    const target: MemberBrief | null = this.member
    if (user === null || target === null) {
      return false
    }
    return can(user, 'ResetPassword', target)
  }

  /** 移出社团：manage_members + 同权保护 + 不是「最后一位会长」 */
  canDisable(): boolean {
    const user: MemberSelf | null = this.currentUser()
    const target: MemberBrief | null = this.member
    if (user === null || target === null) {
      return false
    }
    if (!can(user, 'DisableMember', target)) {
      return false
    }
    return !isLastPresident(this.presidents, target)
  }

  /** 已是退出状态的人不再提供任何写操作 */
  private isActionable(): boolean {
    return this.member !== null && this.member.status !== 'disabled'
  }

  private hasAnyAction(): boolean {
    return this.isActionable() && (this.canEditName() || this.canResetPassword() || this.canDisable())
  }

  private lastPresidentBlocked(): boolean {
    const target: MemberBrief | null = this.member
    if (target === null) {
      return false
    }
    return this.member !== null && isLastPresident(this.presidents, target)
  }

  // ─── 展示辅助 ───

  /** P07 身份卡：「2025-09 加入 · 未完成 5 · 逾期 1 · 已完成 12」 */
  private identityLine(): string {
    const parts: string[] = []
    const joined: string = this.joinedMonth()
    if (joined.length > 0) {
      parts.push(`${joined} 加入`)
    }
    const s: MemberStats | null = this.stats
    if (s !== null) {
      parts.push(`未完成 ${s.open_tasks}`)
      if (s.overdue_tasks > 0) {
        parts.push(`逾期 ${s.overdue_tasks}`)
      }
      parts.push(`已完成 ${s.done_tasks}`)
    }
    return parts.join(' · ')
  }

  /** ISO 8601 → 「YYYY-MM」；拿不到就返回空串（整段不显示） */
  private joinedMonth(): string {
    const raw: string | null | undefined = this.member?.joined_at
    if (raw === null || raw === undefined || raw.length < 7) {
      return ''
    }
    return raw.substring(0, 7)
  }

  private joinedDate(): string {
    const raw: string | null | undefined = this.member?.joined_at
    if (raw === null || raw === undefined || raw.length < 10) {
      return '—'
    }
    return raw.substring(0, 10)
  }

  private initial(): string {
    const name: string = this.member?.name ?? ''
    if (name.length === 0) {
      return '?'
    }
    return name.substring(0, 1)
  }

  private dueText(task: TaskBrief): string {
    if (task.is_overdue) {
      const days: number = task.overdue_days ?? 0
      return days > 0 ? `逾期 ${days} 天` : '已逾期'
    }
    const due: string | null = task.due_at
    if (due === null || due.length < 10) {
      return '无截止时间'
    }
    const month: number = Number(due.substring(5, 7))
    const day: number = Number(due.substring(8, 10))
    return `${month}-${day} 截止`
  }

  private openTasksHint(): string {
    const s: MemberStats | null = this.stats
    if (s === null) {
      return ''
    }
    return `名下还有 ${s.open_tasks} 项未完成任务，移出社团前需先转交。`
  }

  // ─── 写操作 ───

  private openEditNameDialog(): void {
    this.editingName = this.member?.name ?? ''
    this.actionError = ''
    this.showEditNameDialog = true
  }

  private async saveName(): Promise<void> {
    const name: string = this.editingName.trim()
    const target: MemberBrief | null = this.member
    if (target === null || this.submitting) {
      return
    }
    if (name.length === 0) {
      this.actionError = '姓名不能为空'
      return
    }
    if (name === target.name) {
      this.showEditNameDialog = false
      return
    }
    this.submitting = true
    this.actionError = ''
    const resp = await this.memberApi.update(this.memberId, { name: name })
    this.submitting = false
    if (resp.ok && resp.data !== undefined) {
      this.member = resp.data
      this.showEditNameDialog = false
      this.editingName = ''
      promptAction.showToast({ message: '姓名已更新', duration: 2000 })
      this.notifyChanged()
    } else {
      this.actionError = resp.error?.message ?? '保存失败，请重试'
    }
  }

  private openResetPasswordDialog(): void {
    this.tempPassword = ''
    this.actionError = ''
    this.showResetPasswordDialog = true
  }

  private async doResetPassword(): Promise<void> {
    if (this.submitting) {
      return
    }
    this.submitting = true
    this.actionError = ''
    const resp = await this.memberApi.resetPassword(this.memberId)
    this.submitting = false
    if (resp.ok && resp.data !== undefined) {
      this.tempPassword = resp.data.temporary_password
    } else {
      this.actionError = resp.error?.message ?? '重置失败，请重试'
    }
  }

  private openDisableDialog(): void {
    this.actionError = ''
    const open: TaskBrief[] = this.openTasks()
    this.blockerTasks = open.length > BLOCKER_PREVIEW_LIMIT
      ? open.slice(0, BLOCKER_PREVIEW_LIMIT)
      : open
    this.showDisableDialog = true
  }

  private async doDisable(): Promise<void> {
    if (this.submitting) {
      return
    }
    this.submitting = true
    this.actionError = ''
    const resp = await this.memberApi.disable(this.memberId)
    this.submitting = false
    if (resp.ok && resp.data !== undefined) {
      this.member = resp.data
      this.showDisableDialog = false
      promptAction.showToast({ message: '已移出社团（账号与历史记录保留）', duration: 2000 })
      this.notifyChanged()
    } else {
      /*
       * MEMBER_HAS_OPEN_TASKS：后端把清单放在 error.fields.tasks（数组），
       * 客户端不解析那段 JSON —— 任务明细本页已经列出来了，直接给可执行的提示。
       */
      if (resp.error?.code === 'MEMBER_HAS_OPEN_TASKS') {
        this.actionError = this.openTasksHint()
      } else {
        this.actionError = resp.error?.message ?? '移出失败，请重试'
      }
    }
  }

  private notifyChanged(): void {
    if (this.onChanged !== undefined) {
      this.onChanged()
    }
  }

  // ─── 弹窗 Builder ───
  // 说明：ArkUI 的 @Builder 不支持把「builder 函数」当参数传（本仓无先例），
  // 所以每个弹窗自包含外壳；外壳 12 行，换来的是与 ManagePage 一致的已验证写法。

  @Builder
  inlineError() {
    if (this.actionError.length > 0) {
      Text(this.actionError)
        .fontSize(FontSize.caption)
        .fontColor(StatusColor.overdue.fg)
        .backgroundColor(StatusColor.overdue.bg)
        .borderRadius(Radius.input)
        .padding({ left: Space.md, right: Space.md, top: Space.sm, bottom: Space.sm })
        .width('100%')
    }
  }

  @Builder
  editNameDialogBuilder() {
    Column() {
      Column({ space: Space.md }) {
        Text('编辑姓名')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.textPrimary)
          .width('100%')

        Text(`当前：${this.member?.name ?? ''} · ${roleLabel(this.member?.role)}`)
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
          .width('100%')

        TextInput({ text: this.editingName, placeholder: '输入新姓名' })
          .fontSize(FontSize.body)
          .fontColor(Color.textPrimary)
          .backgroundColor(Color.surface)
          .borderRadius(Radius.input)
          .border({ width: 1, color: Color.inputBorder })
          .padding({ left: Space.md, right: Space.md })
          .height(44)
          .width('100%')
          .onChange((value: string) => {
            this.editingName = value
          })

        Text('角色只有 5 档预设，没有「会长」（会长只能由会长移交产生）；改名只影响显示名。')
          .fontSize(FontSize.micro)
          .fontColor(Color.textTertiary)
          .width('100%')

        this.inlineError()

        Row() {
          Button('取消')
            .type(ButtonType.Normal)
            .backgroundColor(StatusColor.todo.bg)
            .fontColor(Color.textSecondary)
            .fontSize(FontSize.body)
            .layoutWeight(1)
            .height(44)
            .borderRadius(Radius.button)
            .onClick(() => {
              this.editingName = ''
              this.actionError = ''
              this.showEditNameDialog = false
            })

          Button(this.submitting ? '保存中…' : '保存')
            .type(ButtonType.Capsule)
            .backgroundColor(Color.primary)
            .fontColor(Color.onPrimary)
            .fontSize(FontSize.body)
            .layoutWeight(1)
            .height(44)
            .margin({ left: Space.md })
            .borderRadius(Radius.button)
            .enabled(!this.submitting)
            .onClick(() => {
              this.saveName()
            })
        }
        .width('100%')
      }
      .width('85%')
      .padding(Space.xl)
      .backgroundColor(Color.surface)
      .borderRadius(Radius.card)
      .shadow(Shadow.L3)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  resetPasswordConfirmBuilder() {
    Column() {
      Column({ space: Space.md }) {
        Text('重置密码')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.textPrimary)
          .width('100%')

        Text(`将为 ${this.member?.name ?? ''} 签发新的临时密码，其原密码立即失效。确认重置？`)
          .fontSize(FontSize.body)
          .fontColor(Color.textSecondary)
          .width('100%')

        Text('重置只影响登录口令，不改变部门与角色。')
          .fontSize(FontSize.micro)
          .fontColor(Color.textTertiary)
          .width('100%')

        this.inlineError()

        Row() {
          Button('取消')
            .type(ButtonType.Normal)
            .backgroundColor(StatusColor.todo.bg)
            .fontColor(Color.textSecondary)
            .fontSize(FontSize.body)
            .layoutWeight(1)
            .height(44)
            .borderRadius(Radius.button)
            .onClick(() => {
              this.actionError = ''
              this.showResetPasswordDialog = false
            })

          Button(this.submitting ? '签发中…' : '确认重置')
            .type(ButtonType.Capsule)
            .backgroundColor(StatusColor.blocked.bg)
            .fontColor(StatusColor.blocked.fg)
            .fontSize(FontSize.body)
            .layoutWeight(1)
            .height(44)
            .margin({ left: Space.md })
            .borderRadius(Radius.button)
            .enabled(!this.submitting)
            .onClick(() => {
              this.doResetPassword()
            })
        }
        .width('100%')
      }
      .width('85%')
      .padding(Space.xl)
      .backgroundColor(Color.surface)
      .borderRadius(Radius.card)
      .shadow(Shadow.L3)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  resetPasswordResultBuilder() {
    Column() {
      Column({ space: Space.md }) {
        Text('已签发临时密码')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(StatusColor.done.fg)
          .width('100%')

        Text(`${this.member?.name ?? ''} 的临时密码：`)
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
          .width('100%')

        Text(this.tempPassword)
          .fontSize(FontSize.headline)
          .fontWeight(FontWeight.Bold)
          .fontFamily('Inter')
          .fontColor(StatusColor.blocked.fg)
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ top: Space.md, bottom: Space.md })
          .backgroundColor(Color.primarySoft)
          .borderRadius(Radius.input)

        // 语义按服务端实况写：口令只在本次响应里可见，但**没有**「首次登录强制改密」
        Text('该口令只在本次响应里出现，之后看不到；原密码已失效。请立即告知本人，并提醒尽快在「我的」页自行修改密码。')
          .fontSize(FontSize.micro)
          .fontColor(Color.textSecondary)
          .width('100%')

        Button('知道了')
          .type(ButtonType.Capsule)
          .backgroundColor(StatusColor.done.bg)
          .fontColor(StatusColor.done.fg)
          .fontSize(FontSize.body)
          .width('100%')
          .height(44)
          .borderRadius(Radius.button)
          .onClick(() => {
            this.tempPassword = ''
            this.showResetPasswordDialog = false
          })
      }
      .width('85%')
      .padding(Space.xl)
      .backgroundColor(Color.surface)
      .borderRadius(Radius.card)
      .shadow(Shadow.L3)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  disableConfirmBuilder() {
    Column() {
      Column({ space: Space.md }) {
        Text('移出社团')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(StatusColor.overdue.fg)
          .width('100%')

        Text(`将 ${this.member?.name ?? ''} 移出社团。账号与历史记录全部保留，日后可由管理员恢复。`)
          .fontSize(FontSize.body)
          .fontColor(Color.textSecondary)
          .width('100%')

        if (this.blockerTasks.length > 0) {
          Column({ space: Space.xs }) {
            Text(this.openTasksHint())
              .fontSize(FontSize.caption)
              .fontWeight(FontWeight.Medium)
              .fontColor(StatusColor.overdue.fg)
              .width('100%')

            ForEach(this.blockerTasks, (task: TaskBrief) => {
              Text(`· [${task.status}] ${task.title}`)
                .fontSize(FontSize.micro)
                .fontColor(Color.textSecondary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }, (task: TaskBrief): string => `${task.id}`)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(Space.md)
          .backgroundColor(StatusColor.overdue.bg)
          .borderRadius(Radius.input)
        }

        this.inlineError()

        Row() {
          Button('取消')
            .type(ButtonType.Normal)
            .backgroundColor(StatusColor.todo.bg)
            .fontColor(Color.textSecondary)
            .fontSize(FontSize.body)
            .layoutWeight(1)
            .height(44)
            .borderRadius(Radius.button)
            .onClick(() => {
              this.actionError = ''
              this.showDisableDialog = false
            })

          Button(this.submitting ? '处理中…' : '确认移出')
            .type(ButtonType.Capsule)
            .backgroundColor(StatusColor.overdue.bg)
            .fontColor(StatusColor.overdue.fg)
            .fontSize(FontSize.body)
            .layoutWeight(1)
            .height(44)
            .margin({ left: Space.md })
            .borderRadius(Radius.button)
            .enabled(!this.submitting)
            .onClick(() => {
              this.doDisable()
            })
        }
        .width('100%')
      }
      .width('85%')
      .padding(Space.xl)
      .backgroundColor(Color.surface)
      .borderRadius(Radius.card)
      .shadow(Shadow.L3)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.overlay)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  // ─── 页面区块 ───

  @Builder
  identityCard() {
    Row({ space: Space.lg }) {
      // ── 头像：与名录同一套《配色说明.csv》token，只是尺寸放大到 64。
      //    详情页头像不可交互，所以把名录的「悬停态」提升成这里的「默认态」：常态带角色色投影。
      Text(this.initial())
        .fontSize(28)
        .fontWeight(FontWeight.Bold)
        .fontColor(roleAvatarFg(this.member?.role))
        .width(AVATAR_SIZE)
        .height(AVATAR_SIZE)
        .borderRadius(AVATAR_SIZE / 2)
        .linearGradient({
          angle: 180,
          colors: [[roleAvatarColor(this.member?.role), 0.0], [roleAvatarGradient(this.member?.role), 1.0]]
        })
        .border({ width: AvatarBorderWidth.normal, color: roleAvatarBorder(this.member?.role) })
        .shadow({
          radius: 10,
          color: roleAvatarShadow(this.member?.role),
          offsetX: 0,
          offsetY: 3
        })
        .textAlign(TextAlign.Center)

      Column({ space: Space.xs }) {
        Row() {
          Text(this.member?.name ?? '')
            .fontSize(FontSize.title)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.textPrimary)

          if (this.member !== null && this.member.status !== 'active') {
            Text(memberStatusLabel(this.member.status))
              .fontSize(FontSize.micro)
              .fontColor(memberStatusFg(this.member.status))
              .backgroundColor(Color.canvas)
              .borderRadius(Radius.pill)
              .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              .margin({ left: Space.sm })
          }
        }

        Row({ space: Space.sm }) {
          Text(roleLabel(this.member?.role))
            .fontSize(FontSize.micro)
            .fontWeight(FontWeight.Medium)
            .fontColor(roleBadgeFg(this.member?.role))
            .backgroundColor(roleBadgeBg(this.member?.role))
            .borderRadius(Radius.pill)
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })

          Text(this.member?.dept?.name ?? '未分配部门')
            .fontSize(FontSize.micro)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.textSecondary)
            .backgroundColor(Color.control)
            .borderRadius(Radius.pill)
            .padding({ left: 10, right: 10, top: 3, bottom: 3 })
        }

        if (this.identityLine().length > 0) {
          Text(this.identityLine())
            .fontSize(FontSize.caption)
            .fontColor(Color.textTertiary)
            .margin({ top: Space.xs })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding(Space.card)
    .backgroundColor(Color.surface)
    .borderRadius(Radius.card)
    .border({ width: 1, color: Color.divider })
  }

  @Builder
  infoRow(label: string, value: string, valueColor: string) {
    Row() {
      Text(label)
        .fontSize(FontSize.body)
        .fontColor(Color.textSecondary)
        .width(72)
      Text(value)
        .fontSize(FontSize.body)
        .fontColor(valueColor)
        .layoutWeight(1)
        .textAlign(TextAlign.End)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.md })
  }

  @Builder
  infoCard() {
    Column() {
      Text('基本信息')
        .fontSize(FontSize.caption)
        .fontColor(Color.textTertiary)
        .width('100%')
        .padding({ left: Space.lg, top: Space.md, bottom: Space.sm })

      this.infoRow('部门', this.member?.dept?.name ?? '未分配部门', Color.textPrimary)
      Divider().color(Color.divider).margin({ left: Space.lg })

      this.infoRow('角色', roleLabel(this.member?.role), Color.textPrimary)
      Divider().color(Color.divider).margin({ left: Space.lg })

      this.infoRow('加入时间', this.joinedDate(), Color.textPrimary)
      Divider().color(Color.divider).margin({ left: Space.lg })

      this.infoRow('状态', memberStatusLabel(this.member?.status ?? ''), memberStatusFg(this.member?.status ?? ''))
      Divider().color(Color.divider).margin({ left: Space.lg })

      this.infoRow('负责课题', `${this.stats?.owned_plans ?? 0} 项`, Color.textPrimary)

      // 名录与详情都不含手机号：把这条隐私约束写在界面上，免得被当成漏字段

    }
    .width('100%')
    .backgroundColor(Color.surface)
    .borderRadius(Radius.card)
    .shadow(Shadow.card)
  }

  @Builder
  taskRow(task: TaskBrief) {
    Row() {
      Column({ space: 2 }) {
        Text(task.title)
          .fontSize(FontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(task.is_overdue ? StatusColor.overdue.fg : Color.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(`${task.dept?.name ?? '未分配部门'} · ${this.dueText(task)}`)
          .fontSize(FontSize.micro)
          .fontColor(task.is_overdue ? StatusColor.overdue.fg : Color.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      StatusChip({ status: task.status, isOverdue: task.is_overdue })
        .margin({ left: Space.sm })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.md })
  }

  @Builder
  tasksCard() {
    Column() {
      Row() {
        Text(`TA 负责的任务 · ${this.taskTotal}`)
          .fontSize(FontSize.caption)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.textPrimary)

        Blank()

        Text(`未完成 ${this.stats?.open_tasks ?? 0}`)
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
      }
      .width('100%')
      .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.sm })

      if (this.tasks.length === 0) {
        Text('暂无任务')
          .fontSize(FontSize.body)
          .fontColor(Color.textTertiary)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding(Space.xl)
      } else {
        Column() {
          ForEach(this.tasks, (task: TaskBrief, index: number) => {
            if (index > 0) {
              Divider().strokeWidth(1).color(Color.divider).margin({ left: Space.lg })
            }
            this.taskRow(task)
          }, (task: TaskBrief): string => `${task.id}`)
        }
        .width('100%')

        if (this.taskTotal > this.tasks.length) {
          Text(`仅显示前 ${this.tasks.length} 项，去「任务」页按人筛选可看全部。`)
            .fontSize(FontSize.micro)
            .fontColor(Color.textTertiary)
            .width('100%')
            .padding({ left: Space.lg, right: Space.lg, bottom: Space.md })
        }
      }
    }
    .width('100%')
    .backgroundColor(Color.surface)
    .borderRadius(Radius.card)
    .border({ width: 1, color: Color.divider })
  }

  @Builder
  actionRow(label: string, color: string, onTap: () => void) {
    Row() {
      Text(label)
        .layoutWeight(1)
        .fontSize(FontSize.body)
        .fontColor(color)
      Image($r('app.media.chevron_right'))
        .width(16)
        .height(16)
    }
    .width('100%')
    .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.md })
    .onClick(() => {
      onTap()
    })
  }

  @Builder
  actionCard() {
    Column({ space: Space.sm }) {
      Text('成员处置 · 受「同权保护」约束')
        .fontSize(FontSize.caption)
        .fontColor(Color.textTertiary)
        .width('100%')
        .padding({ left: Space.xs, right: Space.xs })

      Column() {
        if (this.canEditName()) {
          this.actionRow('编辑姓名', Color.textPrimary, () => {
            this.openEditNameDialog()
          })
        }
        if (this.canEditName() && (this.canResetPassword() || this.canDisable())) {
          Divider().strokeWidth(1).color(Color.divider)
        }
        if (this.canResetPassword()) {
          this.actionRow('重置密码 · 签发一次性临时密码', StatusColor.blocked.fg, () => {
            this.openResetPasswordDialog()
          })
        }
        if (this.canResetPassword() && this.canDisable()) {
          Divider().strokeWidth(1).color(Color.divider)
        }
        if (this.canDisable()) {
          this.actionRow('移出社团', StatusColor.overdue.fg, () => {
            this.openDisableDialog()
          })
        }
      }
      .width('100%')
      .backgroundColor(Color.surface)
      .borderRadius(Radius.card)
      .border({ width: 1, color: Color.divider })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 为什么一个按钮都没有：把原因说出来，别让页面看起来像坏了 */
  @Builder
  noActionHint() {
    Column({ space: Space.xs }) {
      if (this.member !== null && this.member.status === 'disabled') {
        Text('该成员已退出社团（账号与历史记录仍保留）。')
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
          .width('100%')
        Text('如需恢复，请先在管理页重新分配部门与角色。')
          .fontSize(FontSize.micro)
          .fontColor(Color.textTertiary)
          .width('100%')
      } else {
        Text('你对这位成员没有可执行的操作。')
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
          .width('100%')
        if (this.lastPresidentBlocked()) {
          Text('TA 是社团唯一在任的会长 —— 社团必须始终保留至少一位会长，不能移出。')
            .fontSize(FontSize.micro)
            .fontColor(Color.textTertiary)
            .width('100%')
        } else {
          Text('不能对同权限或更高权限的人执行操作；会长也不能重置自己。')
            .fontSize(FontSize.micro)
            .fontColor(Color.textTertiary)
            .width('100%')
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Space.lg)
    .backgroundColor(Color.surface)
    .borderRadius(Radius.card)
    .shadow(Shadow.card)
  }

  @Builder
  statusHint() {
    if (this.loading && this.member === null) {
      Column({ space: Space.md }) {
        LoadingProgress().width(32).height(32).color(Color.primary)
        Text('正在加载成员详情…')
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
      }
      .width('100%')
      .padding({ top: Space.xxl * 2, bottom: Space.xxl })
    } else if (this.errorMsg.length > 0) {
      Column({ space: Space.md }) {
        Text(this.errorMsg)
          .fontSize(FontSize.caption)
          .fontColor(StatusColor.overdue.fg)
          .textAlign(TextAlign.Center)
          .width('100%')

        Button('重试')
          .height(36)
          .fontSize(FontSize.body)
          .fontColor(Color.onPrimary)
          .backgroundColor(Color.primary)
          .borderRadius(Radius.button)
          .onClick(() => {
            this.load()
          })
      }
      .width('100%')
      .padding({ top: Space.xxl, bottom: Space.xxl, left: Space.page, right: Space.page })
    }
  }

  // 杨睿修：把 4 个串链的 bindContentCover 合并成单个 + 分发 builder。
  // 同一组件上链多个 bindContentCover 会导致除最后一个外的弹窗「闪现即关」。
  @Builder
  dialogCoverBuilder() {
    if (this.showEditNameDialog) {
      this.editNameDialogBuilder()
    } else if (this.showDisableDialog) {
      this.disableConfirmBuilder()
    } else if (this.showResetPasswordDialog) {
      if (this.tempPassword.length > 0) {
        this.resetPasswordResultBuilder()
      } else {
        this.resetPasswordConfirmBuilder()
      }
    }
  }

  build() {
    Scroll() {
      Column({ space: Space.md }) {
        this.statusHint()

        if (this.member !== null) {
          this.identityCard()
          this.infoCard()
          this.tasksCard()

          if (this.hasAnyAction()) {
            this.actionCard()
          } else if (!this.loading) {
            this.noActionHint()
          }
        }
      }
      .width('100%')
      .padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.xxl })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.canvas)
    .scrollBar(BarState.Off)
    .bindContentCover(
      this.showEditNameDialog || this.showDisableDialog || this.showResetPasswordDialog,
      this.dialogCoverBuilder
    )
  }
}
