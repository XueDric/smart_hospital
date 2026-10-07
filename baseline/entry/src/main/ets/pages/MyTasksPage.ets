/**
 * 作者：刘运泽
 * 功能：我的任务页（服务端分组 + 统计条 + 日历对账）
 * 修改记录：
 *   2026-09-16  首次编写
 *   2026-09-16  改造成底部 tab 组件
 *   2026-09-16  新建任务/课题后列表不刷新（fix）
 *   2026-09-17  编辑与移动 + 日历对账接线
 *   2026-09-17  恢复设计稿外观（分段控件/卡片底色/进度条/布局）
 *   2026-09-18  按 Figma 还原：白色头部块（副标题+头像+统计卡）、组内单卡片分隔、行样式
 */
// 首页「我的任务」。服务端已分组，直接渲染，别自己算逾期。

import { TaskApi, MineGroups, TaskBrief } from '../api/TaskApi'
import { TaskCard } from '../components/TaskCard'
import { CalendarSyncService } from '../util/CalendarSync'
import { AvatarBorderWidth, Color, FontSize, Radius, Shadow, Space, StatusColor, roleAvatarBorder, roleAvatarColor, roleAvatarFg, roleAvatarGradient, roleLabel } from '../core/Theme'
import { PermissionStore } from '../store/PermissionStore'

const EMPTY_MINE_GROUPS: MineGroups = {
  overdue: [], blocked: [], due_today: [], due_week: [], later: [], no_due: [],
  counts: { overdue: 0, blocked: 0, open_total: 0 }
}

@Component
export default struct MyTasksPage {
  @State myTasks: MineGroups = EMPTY_MINE_GROUPS
  @State loading: boolean = true
  @State errorMsg: string = ''
  @State lastSync: string = ''

  onOpenPlans?: () => void
  // 由外层 TabBar 注入：切换 Tab / 从子页返回时 +1，触发重新拉取
  @Prop @Watch('onRefreshSignal') refreshSignal: number = 0

  private taskApi: TaskApi = new TaskApi()
  private permissionStore: PermissionStore = PermissionStore.getInstance()

  aboutToAppear(): void {
    this.load()
  }

  onRefreshSignal(): void {
    this.load()
  }

  private hhmm(): string {
    const d = new Date()
    const h = d.getHours()
    const m = d.getMinutes()
    return `${h < 10 ? '0' + h : h}:${m < 10 ? '0' + m : m}`
  }

  private userName(): string {
    return this.permissionStore.userInfo?.name ?? ''
  }

  private userDeptRole(): string {
    const u = this.permissionStore.userInfo
    const dept: string = u?.dept?.name ?? ''
    const role: string = roleLabel(u?.role)
    return `${dept} · ${role}`
  }

  private userInitial(): string {
    const name: string = this.userName()
    return name.length > 0 ? name.substring(0, 1) : ''
  }

  private async load(): Promise<void> {
    this.loading = true
    this.errorMsg = ''
    const resp = await this.taskApi.mine()
    if (resp.ok && resp.data) {
      this.myTasks = resp.data
      this.lastSync = this.hhmm()
    } else {
      this.errorMsg = resp.error?.message ?? '加载失败'
    }
    this.loading = false
    // 后台对账日历：清理已删除 / 已完成任务的日历事件，避免过期提醒堆积。不阻塞首页渲染。
    CalendarSyncService.getInstance().reconcile(getContext(this))
  }

  @Builder
  sectionHeader(title: string, hint: string, count: number, color: string) {
    Row() {
      Text(`${title} · ${count}`)
        .fontSize(FontSize.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(color)
      Blank()
      if (hint.length > 0) {
        Text(hint)
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
      }
    }
    .width('100%')
  }

  @Builder
  statCell(label: string, value: number, color: string) {
    Column() {
      Text(`${value}`)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(color)
      Text(label)
        .fontSize(FontSize.caption)
        .fontColor(Color.textTertiary)
        .margin({ top: 2 })
    }
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  statsBar() {
    Row() {
      Row({ space: 24 }) {
        this.statCell('逾期', this.myTasks.counts.overdue, '#EF4444')
        this.statCell('阻塞', this.myTasks.counts.blocked, '#F59E0B')
        this.statCell('未完成', this.myTasks.counts.open_total, Color.primary)
      }
      Blank()
      Column() {
        Text('点击刷新')
          .fontSize(FontSize.caption)
          .fontWeight(FontWeight.Medium)
          .fontColor('#3B82F6')
        Text(`${this.lastSync.length > 0 ? this.lastSync : '9:41'} 已同步`)
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    // 杨睿修（C-4）：统计卡整块可点击刷新，替代原来无法触发的假「下拉刷新」文案
    .onClick(() => { if (!this.loading) this.load() })
    .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.md })
    .backgroundColor(Color.surface)
    .borderRadius(Radius.card)
    .border({ width: 1, color: Color.divider })
    .shadow(Shadow.card)
    .margin({ top: Space.md })
  }

  @Builder
  group(title: string, hint: string, tasks: TaskBrief[], color: string) {
    Column() {
      this.sectionHeader(title, hint, tasks.length, color)
      Column() {
        ForEach(tasks, (t: TaskBrief, index: number) => {
          TaskCard({ task: t })
          if (index < tasks.length - 1) {
            Divider().color(Color.divider)
          }
        }, (t: TaskBrief) => `${t.id}`)
      }
      .width('100%')
      .margin({ top: Space.sm })
      .backgroundColor(Color.surface)
      .borderRadius(Radius.card)
      .border({ width: 1, color: Color.divider })
      .shadow(Shadow.card)
    }
    .width('100%')
  }

  @Builder
  statusHint() {
    if (this.loading) {
      Row() {
        LoadingProgress().width(28).height(28).color(Color.primary)
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .padding({ top: Space.xxl, bottom: Space.xxl })
    } else if (this.errorMsg.length > 0) {
      Column() {
        Text(this.errorMsg)
          .fontSize(FontSize.caption)
          .fontColor(StatusColor.overdue.fg)
          .width('100%')
          .textAlign(TextAlign.Center)
        Button('重试')
          .height(36)
          .backgroundColor(Color.primary)
          .fontColor(Color.surface)
          .margin({ top: Space.sm })
          .onClick(() => {
            this.load()
          })
      }
      .width('100%')
      .padding({ top: Space.xxl })
    }
  }

  build() {
    Column() {
      // ── 白色头部块：标题 + 副标题 + 头像 + 统计卡（Figma：bg-white border-b）──
      Column() {
        Row() {
          Column() {
            Text('我的任务')
              .fontSize(FontSize.headline)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.textPrimary)
            Text(`${this.userName()} · ${this.userDeptRole()}`)
              .fontSize(FontSize.caption)
              .fontColor(Color.textTertiary)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
          Text(this.userInitial())
            .width(36)
            .height(36)
            .fontSize(FontSize.subtitle)
            .fontWeight(FontWeight.Medium)
            .fontColor(roleAvatarFg(this.permissionStore.userInfo?.role))
            .textAlign(TextAlign.Center)
            .borderRadius(18)
            .linearGradient({
              angle: 180,
              colors: [[roleAvatarColor(this.permissionStore.userInfo?.role), 0.0], [roleAvatarGradient(this.permissionStore.userInfo?.role), 1.0]],
            })
            .border({
              width: AvatarBorderWidth.normal,
              color: roleAvatarBorder(this.permissionStore.userInfo?.role),
            })
        }
        .width('100%')

        this.statsBar()
      }
      .width('100%')
      .padding({ left: Space.page, right: Space.page, top: Space.lg, bottom: Space.md })
      .backgroundColor(Color.surface)
      .border({ width: 1, color: Color.divider })

      Scroll() {
        Column({ space: Space.section }) {
          this.statusHint()
          if (this.myTasks.overdue.length > 0) {
            this.group('已逾期', '距截止已过，请尽快处理', this.myTasks.overdue, '#EF4444')
          }
          if (this.myTasks.blocked.length > 0) {
            this.group('阻塞中', '阻塞项同时也会出现在下面的时间里', this.myTasks.blocked, '#F59E0B')
          }
          if (this.myTasks.due_today.length > 0) {
            this.group('今天到期', '', this.myTasks.due_today, Color.textSecondary)
          }
          if (this.myTasks.due_week.length > 0) {
            this.group('本周内', `本周内还有 ${this.myTasks.due_week.length} 项`, this.myTasks.due_week, Color.textSecondary)
          }
          if (this.myTasks.later.length > 0) {
            this.group('以后', '', this.myTasks.later, Color.textSecondary)
          }
          if (this.myTasks.no_due.length > 0) {
            this.group('未设截止', '', this.myTasks.no_due, Color.textSecondary)
          }
        }
        .width('100%')
        .padding({ left: Space.page, right: Space.page, top: Space.lg, bottom: Space.xl })
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.canvas)
  }
}
