/**
 * 作者：刘运泽
 * 功能：课题树页（递归进度展示）
 * 修改记录：
 *   2026-09-16  首次编写
 *   2026-09-16  改造成底部 tab 组件
 *   2026-09-16  新建任务/课题后列表不刷新（fix）
 *   2026-09-17  恢复设计稿外观
 *   2026-09-18  按 Figma 还原：白色头部块、收起全部改描边按钮、部门筛选胶囊行
 */
// 课题树。进度 progress.done / progress.total 是服务端递归聚合好的（含整棵子树），
// 客户端直接用，别再自己递归算。顶层用进度条 + 元信息行，嵌套层收成数字。
// 接接口后：GET /plans、GET /depts。

import router from '@ohos.router'
import { PlanApi, PlanNode } from '../api/PlanApi'
import { DeptApi, DeptView } from '../api/DeptApi'
import { ProgressBar } from '../components/ProgressBar'
import { Color, FontSize, Radius, Space, StatusColor } from '../core/Theme'

@Component
struct PlanTreeNode {
  @Prop node: PlanNode
  @Prop depth: number = 0
  @Prop @Watch('onExpandAll') expandAll: boolean = true
  @State expanded: boolean = true

  aboutToAppear(): void {
    // 默认只展开到第 2 层（深度 0/1 展开，2+ 折叠）
    if (this.depth >= 2) {
      this.expanded = false
    }
  }

  onExpandAll(): void {
    this.expanded = this.expandAll
  }

  build() {
    Column() {
      Column() {
        Row() {
          if (this.node.child_count > 0) {
            Text(this.expanded ? '▾' : '▸')
              .fontSize(FontSize.caption)
              .fontColor(Color.textTertiary)
              .width(20)
              .onClick(() => {
                this.expanded = !this.expanded
              })
          } else {
            Text('·')
              .fontSize(FontSize.caption)
              .fontColor(Color.textTertiary)
              .width(20)
          }
          Text(this.node.title)
            .fontSize(this.depth === 0 ? FontSize.subtitle : FontSize.body)
            .fontWeight(this.depth === 0 ? FontWeight.Medium : FontWeight.Regular)
            .fontColor(Color.textPrimary)
            .layoutWeight(1)
            .onClick(() => {
              router.pushUrl({ url: 'pages/PlanDetailPage', params: { plan_id: this.node.id } })
            })
          Text(`已完成 ${this.node.progress.done}/共 ${this.node.progress.total}`)
            .fontSize(FontSize.caption)
            .fontColor(Color.primary)
        }
        .width('100%')

        if (this.depth === 0) {
          Text(`${this.node.dept?.name ?? '未分配部门'} · 负责人 ${this.node.owner?.name ?? '未分配'} · ${this.node.child_count} 个子课题`)
            .fontSize(FontSize.micro)
            .fontColor(Color.textTertiary)
            .width('100%')
            .margin({ top: Space.xs })
          Row() {
            ProgressBar({ done: this.node.progress.done, total: this.node.progress.total, trackHeight: 4 })
              .layoutWeight(1)
          }
          .width('100%')
          .margin({ top: Space.sm })
        }
      }
      .width('100%')
      .padding({ top: Space.md, bottom: Space.md })

      if (this.expanded && this.node.children.length > 0) {
        Column() {
          ForEach(this.node.children, (child: PlanNode) => {
            PlanTreeNode({ node: child, depth: this.depth + 1, expandAll: this.expandAll })
          }, (child: PlanNode) => `${child.id}`)
        }
        .width('100%')
        .margin({ left: Space.lg })
      }
    }
    .width('100%')
  }
}

@Component
export default struct PlanTreePage {
  @State tree: PlanNode[] = []
  @State depts: DeptView[] = []
  @State deptFilter: number = 0
  @State loading: boolean = true
  @State errorMsg: string = ''
  // 杨睿修（C-5）：初值改为 false，使「展开/收起全部」按钮文案与实际默认折叠状态一致（深层节点默认折叠）
  @State expandAll: boolean = false

  // 由外层 TabBar 注入：切换 Tab / 从子页返回时 +1，触发重新拉取
  @Prop @Watch('onRefreshSignal') refreshSignal: number = 0

  private planApi: PlanApi = new PlanApi()
  private deptApi: DeptApi = new DeptApi()

  aboutToAppear(): void {
    this.load()
  }

  onRefreshSignal(): void {
    this.load()
  }

  private toggleExpandAll(): void {
    this.expandAll = !this.expandAll
  }

  private filteredTree(): PlanNode[] {
    if (this.deptFilter === 0) {
      return this.tree
    }
    return this.tree.filter((n: PlanNode) => (n.dept?.id ?? -1) === this.deptFilter)
  }

  private async load(): Promise<void> {
    this.loading = true
    this.errorMsg = ''
    const resp = await this.planApi.list()
    if (resp.ok && resp.data) {
      this.tree = resp.data.items
    } else {
      this.errorMsg = resp.error?.message ?? '加载失败'
    }
    this.loading = false
    // 部门筛选数据 —— best-effort，失败只影响胶囊行，不影响树
    const dresp = await this.deptApi.list()
    if (dresp.ok && dresp.data) {
      this.depts = dresp.data.items
    }
  }

  @Builder
  deptChipAll() {
    Text('全部')
      .fontSize(FontSize.body)
      .fontColor(this.deptFilter === 0 ? Color.surface : Color.textSecondary)
      .backgroundColor(this.deptFilter === 0 ? Color.primary : Color.surface)
      .borderRadius(Radius.pill)
      .border({ width: 1, color: this.deptFilter === 0 ? Color.primary : Color.border })
      .padding({ left: Space.md, right: Space.md, top: 5, bottom: 5 })
      .onClick(() => {
        this.deptFilter = 0
      })
  }

  @Builder
  deptChip(d: DeptView) {
    Text(d.name)
      .fontSize(FontSize.body)
      .fontColor(this.deptFilter === d.id ? Color.surface : Color.textSecondary)
      .backgroundColor(this.deptFilter === d.id ? Color.primary : Color.surface)
      .borderRadius(Radius.pill)
      .border({ width: 1, color: this.deptFilter === d.id ? Color.primary : Color.border })
      .padding({ left: Space.md, right: Space.md, top: 5, bottom: 5 })
      .onClick(() => {
        this.deptFilter = d.id
      })
  }

  @Builder
  chips() {
    Scroll() {
      Row({ space: Space.sm }) {
        this.deptChipAll()
        ForEach(this.depts, (d: DeptView) => {
          this.deptChip(d)
        }, (d: DeptView) => `${d.id}`)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .margin({ top: Space.md })
  }

  build() {
    Column() {
      // ── 白色头部块：标题 + 副标题 + 收起全部 + 新建 + 部门筛选 ──
      Column() {
        Row() {
          Column() {
            Text('课题')
              .fontSize(FontSize.headline)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.textPrimary)
            Text('整棵树一次拉取 · 进度为递归聚合值')
              .fontSize(FontSize.caption)
              .fontColor(Color.textTertiary)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          Blank()
          Text(this.expandAll ? '收起全部' : '展开全部')
            .fontSize(FontSize.caption)
            .fontColor(Color.textSecondary)
            .backgroundColor(Color.surface)
            .border({ width: 1, color: Color.border })
            .borderRadius(Radius.button)
            .padding({ left: Space.md, right: Space.md, top: 5, bottom: 5 })
            .onClick(() => {
              this.toggleExpandAll()
            })
          Text('新建课题')
            .fontSize(FontSize.body)
            .fontColor(Color.primary)
            .margin({ left: Space.md })
            .onClick(() => {
              router.pushUrl({ url: 'pages/CreatePlanPage' })
            })
        }
        .width('100%')

        if (this.depts.length > 0) {
          this.chips()
        }
      }
      .width('100%')
      .padding({ left: Space.page, right: Space.page, top: Space.lg, bottom: Space.md })
      .backgroundColor(Color.surface)
      .border({ width: 1, color: Color.divider })

      Scroll() {
        Column() {
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
            .padding({ top: Space.xxl, bottom: Space.xl })
          } else {
            Column() {
              ForEach(this.filteredTree(), (node: PlanNode) => {
                PlanTreeNode({ node: node, depth: 0, expandAll: this.expandAll })
              }, (node: PlanNode) => `${node.id}`)
            }
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)
            .border({ width: 1, color: Color.divider })
          }
        }
        .width('100%')
      }
      .layoutWeight(1)
      .padding({ left: Space.page, right: Space.page, top: Space.sm, bottom: Space.lg })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.canvas)
  }
}
