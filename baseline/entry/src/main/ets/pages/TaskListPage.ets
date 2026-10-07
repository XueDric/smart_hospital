/**
 * 作者：刘运泽
 * 功能：任务列表页（服务端筛选 + 分页）
 * 修改记录：
 *   2026-09-16  首次编写
 *   2026-09-16  改造成底部 tab 组件
 *   2026-09-16  新建任务/课题后列表不刷新（fix）
 *   2026-09-17  恢复设计稿外观
 *   2026-09-18  按 Figma 还原：单行筛选（全部/我负责/未完成/逾期/本部门）、组内单卡片分隔、行样式
 */
// 任务列表。筛选走服务端过滤参数（GET /tasks?dept_id=&owner_id=&overdue=）。
// Figma 单行筛选里的「未完成」= 状态非 done，服务端无单一参数表达，故加载后客户端过滤。

import router from '@ohos.router'
import { TaskApi, TaskBrief, TaskListParams } from '../api/TaskApi'
import { TaskCard } from '../components/TaskCard'
import { Color, FontSize, Radius, Shadow, Space, StatusColor } from '../core/Theme'
import { PermissionStore } from '../store/PermissionStore'

interface FilterOption {
  label: string;
  value: string;
}

@Component
export default struct TaskListPage {
  @State tasks: TaskBrief[] = []
  @State total: number = 0
  @State loading: boolean = true
  @State errorMsg: string = ''
  @State filter: string = 'all'

  // 由外层 TabBar 注入：切换 Tab / 从子页返回时 +1，触发重新拉取
  @Prop @Watch('onRefreshSignal') refreshSignal: number = 0

  private taskApi: TaskApi = new TaskApi()
  private permissionStore: PermissionStore = PermissionStore.getInstance()

  private filters: FilterOption[] = [
    { label: '全部', value: 'all' },
    { label: '我负责', value: 'mine' },
    { label: '未完成', value: 'notdone' },
    { label: '逾期', value: 'overdue' },
    { label: '本部门', value: 'dept' }
  ]

  aboutToAppear(): void {
    this.loadTasks()
  }

  onRefreshSignal(): void {
    this.loadTasks()
  }

  private buildParams(): TaskListParams {
    const p: TaskListParams = { page: 1, size: 50 }
    const me = this.permissionStore.userInfo
    if (this.filter === 'mine' && me !== null) {
      p.owner_id = me.id
    } else if (this.filter === 'overdue') {
      p.overdue = true
    } else if (this.filter === 'dept' && me !== null && me.dept !== null) {
      p.dept_id = me.dept.id
    }
    return p
  }

  private async loadTasks(): Promise<void> {
    this.loading = true
    this.errorMsg = ''
    const resp = await this.taskApi.list(this.buildParams())
    if (resp.ok && resp.data) {
      this.tasks = resp.data.items
      this.total = resp.data.total
    } else {
      this.errorMsg = resp.error?.message ?? '加载失败'
    }
    this.loading = false
  }

  private displayTasks(): TaskBrief[] {
    if (this.filter === 'notdone') {
      return this.tasks.filter((t: TaskBrief) => t.status !== 'done')
    }
    return this.tasks
  }

  private setFilter(value: string): void {
    if (this.filter === value) {
      return
    }
    this.filter = value
    this.loadTasks()
  }

  @Builder
  filterChip(f: FilterOption) {
    Text(f.label)
      .fontSize(FontSize.body)
      .fontColor(this.filter === f.value ? Color.surface : Color.textSecondary)
      .backgroundColor(this.filter === f.value ? Color.primary : Color.surface)
      .borderRadius(Radius.pill)
      .border({ width: 1, color: this.filter === f.value ? Color.primary : Color.border })
      .padding({ left: Space.md, right: Space.md, top: 5, bottom: 5 })
      .onClick(() => {
        this.setFilter(f.value)
      })
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
            this.loadTasks()
          })
      }
      .width('100%')
      .padding({ top: Space.xxl })
    } else if (this.displayTasks().length === 0) {
      Text('没有符合条件的任务')
        .fontSize(FontSize.caption)
        .fontColor(Color.textTertiary)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: Space.xxl })
    }
  }

  build() {
    Column() {
      // ── 白色头部块：标题 + 副标题 + 新建 + 单行筛选 ──
      Column() {
        Row() {
          Column() {
            Text('任务')
              .fontSize(FontSize.headline)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.textPrimary)
            Text(`共 ${this.total} 项 · 全社团范围可见`)
              .fontSize(FontSize.caption)
              .fontColor(Color.textTertiary)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
          Text('+ 新建')
            .fontSize(FontSize.body)
            .fontColor(Color.surface)
            .backgroundColor(Color.primary)
            .borderRadius(Radius.button)
            .padding({ left: Space.md, right: Space.md, top: 6, bottom: 6 })
            .onClick(() => {
              router.pushUrl({ url: 'pages/CreateTaskPage' })
            })
        }
        .width('100%')

        Scroll() {
          Row({ space: Space.sm }) {
            ForEach(this.filters, (f: FilterOption) => {
              this.filterChip(f)
            }, (f: FilterOption) => f.value)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .margin({ top: Space.md })
      }
      .width('100%')
      .padding({ left: Space.page, right: Space.page, top: Space.lg, bottom: Space.md })
      .backgroundColor(Color.surface)
      .border({ width: 1, color: Color.divider })

      Row() {
        Text(`共 ${this.displayTasks().length} 项 · 第 1 / 1 页`)
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
        Blank()
        Text('按截止时间排序')
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
      }
      .width('100%')
      .padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.sm })

      if (this.loading || this.errorMsg.length > 0 || this.displayTasks().length === 0) {
        this.statusHint()
      }

      Scroll() {
        Column() {
          ForEach(this.displayTasks(), (t: TaskBrief, index: number) => {
            TaskCard({ task: t })
            if (index < this.displayTasks().length - 1) {
              Divider().color(Color.divider)
            }
          }, (t: TaskBrief) => `${t.id}`)
        }
        .width('100%')
        .backgroundColor(Color.surface)
        .borderRadius(Radius.card)
        .border({ width: 1, color: Color.divider })
        .shadow(Shadow.card)
      }
      .layoutWeight(1)
      .padding({ left: Space.page, right: Space.page, bottom: Space.lg })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.canvas)
  }
}
