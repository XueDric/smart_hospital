/**
 * 作者：刘运泽
 * 功能：课题详情页（面包屑/子课题/任务/进度 + 移动/删除）
 * 修改记录：
 *   2026-09-16  首次编写
 *   2026-09-17  编辑与移动 + 日历对账接线
 *   2026-09-17  恢复设计稿外观
 *   2026-09-18  按 Figma 还原：白色头部（返回+面包屑）、部门 indigo 胶囊、新建子课题/移动课题按钮对
 */
// 课题详情。面包屑 path + 子课题 + 本级任务；progress 仍是递归聚合值，进度条是这一页的主角。
// 接接口后：GET /plans/{id}、DELETE /plans/{id}。

import router from '@ohos.router'
import { PlanApi, PlanDetailResponse, PlanNode, MovePlanRequest } from '../api/PlanApi'
import { TaskBrief, PlanRef } from '../api/TaskApi'
import { StatusChip } from '../components/StatusChip'
import { ProgressBar } from '../components/ProgressBar'
import { flattenPlans } from '../util/PlanTree'
import { Color, FontSize, Radius, Space, StatusColor, statusLabel } from '../core/Theme'

const EMPTY_PLAN_DETAIL: PlanDetailResponse = {
  plan: {
    id: 0,
    title: '',
    owner: null,
    dept: null,
    due_at: null,
    progress: { done: 0, total: 0 },
    task_count: 0,
    child_count: 0,
    created_at: '',
    updated_at: '',
    desc: '',
    parent_id: 0
  },
  path: [],
  children: [],
  tasks: { items: [], total: 0 }
}

interface PlanDetailParams {
  plan_id?: number
}

@Entry
@Component
struct PlanDetailPage {
  @State detail: PlanDetailResponse = EMPTY_PLAN_DETAIL
  @State loading: boolean = true
  @State errorMsg: string = ''
  @State showMovePicker: boolean = false
  @State moveOptions: PlanRef[] = []

  private planApi: PlanApi = new PlanApi()

  aboutToAppear(): void {
    const p = router.getParams() as PlanDetailParams
    if (p !== undefined && p !== null && p.plan_id !== undefined) {
      this.load(p.plan_id)
    } else {
      this.loading = false
      this.errorMsg = '缺少课题 id'
    }
  }

  private async load(planId: number): Promise<void> {
    this.loading = true
    this.errorMsg = ''
    const resp = await this.planApi.detail(planId)
    if (resp.ok && resp.data) {
      this.detail = resp.data
    } else {
      this.errorMsg = resp.error?.message ?? '加载失败'
    }
    this.loading = false
  }

  private async doDelete(): Promise<void> {
    const resp = await this.planApi.delete_(this.detail.plan.id)
    if (resp.ok) {
      router.back()
    } else {
      AlertDialog.show({ message: resp.error?.message ?? '删除失败' })
    }
  }

  private async openMovePicker(): Promise<void> {
    const resp = await this.planApi.list()
    if (resp.ok && resp.data) {
      const flat = flattenPlans(resp.data.items)
      const opts: PlanRef[] = []
      for (const p of flat) {
        if (p.id !== this.detail.plan.id) {
          opts.push(p)
        }
      }
      this.moveOptions = opts
      this.showMovePicker = true
    } else {
      AlertDialog.show({ message: resp.error?.message ?? '加载课题列表失败' })
    }
  }

  private async moveTo(parentId: number): Promise<void> {
    this.showMovePicker = false
    const data: MovePlanRequest = { new_parent_id: parentId }
    const resp = await this.planApi.move(this.detail.plan.id, data)
    if (resp.ok) {
      AlertDialog.show({ message: '已移动课题' })
      this.load(this.detail.plan.id)
    } else {
      AlertDialog.show({ message: resp.error?.message ?? '移动失败' })
    }
  }

  @Builder
  header() {
    Column() {
      Row() {
        Image($r('app.media.icon_chevron_left_primary'))
          .width(20)
          .height(20)
          .onClick(() => {
            router.back()
          })
        Text('课题详情')
          .fontSize(FontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.textPrimary)
          .margin({ left: Space.sm })
      }
      .width('100%')

      if (this.detail.path.length > 0) {
        Scroll() {
          Row({ space: 6 }) {
            ForEach(this.detail.path, (p: PlanRef, index: number) => {
              Row() {
                Text(p.title)
                  .fontSize(FontSize.caption)
                  .fontColor(Color.primary)
                  .onClick(() => {
                    router.pushUrl({ url: 'pages/PlanDetailPage', params: { plan_id: p.id } })
                  })
                Text('›').fontSize(FontSize.caption).fontColor(Color.textTertiary).margin({ left: 6 })
              }
            }, (p: PlanRef) => `${p.id}`)
            Text(this.detail.plan.title)
              .fontSize(FontSize.caption)
              .fontColor(Color.textPrimary)
          }
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .margin({ top: Space.sm })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: Space.page, right: Space.page, top: Space.md, bottom: Space.md })
    .backgroundColor(Color.surface)
    .border({ width: 1, color: Color.divider })
  }

  @Builder
  chip(text: string, fg: string, bg: string) {
    Text(text)
      .fontSize(FontSize.micro)
      .fontWeight(FontWeight.Medium)
      .fontColor(fg)
      .backgroundColor(bg)
      .borderRadius(Radius.pill)
      .padding({ left: Space.sm, right: Space.sm, top: 3, bottom: 3 })
  }

  @Builder
  infoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(FontSize.caption).fontColor(Color.textTertiary).width(56)
      Text(value).fontSize(FontSize.caption).fontColor(Color.textPrimary).layoutWeight(1)
    }
    .width('100%')
    .padding({ top: Space.xs, bottom: Space.xs })
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
            const p = router.getParams() as PlanDetailParams
            if (p !== undefined && p !== null && p.plan_id !== undefined) {
              this.load(p.plan_id)
            }
          })
      }
      .width('100%')
      .padding({ top: Space.xxl })
    }
  }

  build() {
    Column() {
      this.header()

      if (this.loading || this.errorMsg.length > 0) {
        this.statusHint()
      } else {
        Scroll() {
          Column({ space: Space.md }) {
            Column() {
              Row({ space: Space.sm }) {
                this.chip(
                  this.detail.plan.dept !== null ? this.detail.plan.dept.name : '继承根部门',
                  '#6366F1',
                  '#EEF2FF'
                )
                this.chip(
                  this.detail.plan.parent_id === 0 ? '顶层课题' : `子课题 · 第 ${this.detail.path.length} 层`,
                  '#6B7280',
                  '#F3F4F6'
                )
              }
              .width('100%')
              Text(this.detail.plan.title)
                .fontSize(FontSize.title).fontWeight(FontWeight.Bold).fontColor(Color.textPrimary).width('100%')
                .margin({ top: Space.sm })
              this.infoRow('负责人', this.detail.plan.owner?.name ?? '未分配')
              this.infoRow('截止', this.detail.plan.due_at !== null ? this.detail.plan.due_at : '无')
              if (this.detail.plan.parent_id !== 0) {
                this.infoRow('部门', '子课题继承根部门，不可单独指定')
              }
              Column() {
                Text('递归进度 · 含整棵子树')
                  .fontSize(FontSize.micro).fontWeight(FontWeight.Medium).fontColor(Color.textSecondary).width('100%')
                ProgressBar({ done: this.detail.plan.progress.done, total: this.detail.plan.progress.total, trackHeight: 6 })
                  .margin({ top: Space.sm })
                Text(`已完成 ${this.detail.plan.progress.done}/共 ${this.detail.plan.progress.total} · ${this.detail.plan.child_count} 个子课题 · 本级任务 ${this.detail.plan.task_count}`)
                  .fontSize(FontSize.caption).fontColor(Color.textTertiary).width('100%').margin({ top: Space.sm })
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .padding(Space.md)
              .backgroundColor(Color.canvas)
              .borderRadius(Radius.input)
              .margin({ top: Space.sm })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)
            .border({ width: 1, color: Color.divider })

            Column() {
              Text(`子课题 · ${this.detail.children.length}`).fontSize(FontSize.caption).fontColor(Color.textTertiary).width('100%')
              ForEach(this.detail.children, (c: PlanNode) => {
                Row() {
                  Text(c.title).fontSize(FontSize.body).fontColor(Color.textPrimary).layoutWeight(1)
                  Text(`${c.progress.done}/${c.progress.total}`).fontSize(FontSize.caption).fontColor(Color.primary)
                }
                .width('100%')
                .padding({ top: Space.sm, bottom: Space.sm })
                .onClick(() => {
                  router.pushUrl({ url: 'pages/PlanDetailPage', params: { plan_id: c.id } })
                })
              }, (c: PlanNode) => `${c.id}`)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)
            .border({ width: 1, color: Color.divider })

            Column() {
              Text(`本级任务 ${this.detail.tasks.total}`).fontSize(FontSize.caption).fontColor(Color.textTertiary).width('100%')
              ForEach(this.detail.tasks.items, (t: TaskBrief) => {
                Row() {
                  Column() {
                    Text(t.title)
                      .fontSize(FontSize.body)
                      .fontColor(t.is_overdue ? StatusColor.overdue.fg : Color.textPrimary)
                    Text(`${t.owner?.name ?? '未分配'} · ${statusLabel(t.status)}`)
                      .fontSize(FontSize.caption).fontColor(Color.textTertiary).margin({ top: Space.xs })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  StatusChip({ status: t.status, isOverdue: t.is_overdue })
                }
                .width('100%')
                .padding({ top: Space.sm, bottom: Space.sm })
                .onClick(() => {
                  router.pushUrl({ url: 'pages/TaskDetailPage', params: { task_id: t.id } })
                })
              }, (t: TaskBrief) => `${t.id}`)
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(Space.card)
            .backgroundColor(Color.surface)
            .borderRadius(Radius.card)
            .border({ width: 1, color: Color.divider })

            // ── Figma 按钮对：新建子课题（实心蓝）+ 移动课题（描边） ──
            Row({ space: Space.md }) {
              Button('新建子课题')
                .layoutWeight(1)
                .height(46)
                .backgroundColor(Color.primary)
                .fontColor(Color.surface)
                .onClick(() => {
                  router.pushUrl({ url: 'pages/CreatePlanPage', params: { parent_id: this.detail.plan.id } })
                })
              Button('移动课题')
                .layoutWeight(1)
                .height(46)
                .backgroundColor(Color.surface)
                .border({ width: 1, color: Color.border })
                .fontColor(Color.primary)
                .onClick(() => {
                  this.openMovePicker()
                })
            }
            .width('100%')

            Button('编辑课题')
              .width('100%')
              .height(44)
              .backgroundColor(Color.surface)
              .border({ width: 1, color: Color.border })
              .fontColor(Color.primary)
              .onClick(() => {
                router.pushUrl({ url: 'pages/CreatePlanPage', params: { plan_id: this.detail.plan.id } })
              })

            if (this.showMovePicker) {
              Column() {
                Row() {
                  Text('提升为顶层课题').fontSize(FontSize.body).fontColor(Color.primary)
                }
                .width('100%').padding({ top: Space.sm, bottom: Space.sm })
                .onClick(() => {
                  this.moveTo(0)
                })
                ForEach(this.moveOptions, (p: PlanRef) => {
                  Text(p.title).fontSize(FontSize.body).fontColor(Color.textPrimary)
                    .width('100%').padding({ top: Space.sm, bottom: Space.sm })
                    .onClick(() => {
                      this.moveTo(p.id)
                    })
                }, (p: PlanRef) => `${p.id}`)
              }
              .width('100%').padding({ left: Space.md, right: Space.md }).backgroundColor(Color.surface).borderRadius(Radius.card)
            }

            Row() {
              Text('删除课题')
                .fontSize(FontSize.body)
                .fontColor(StatusColor.overdue.fg)
            }
            .width('100%')
            .height(44)
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
                const hint = this.detail.children.length > 0
                  ? '删除后其子课题将提升到上一级，本级任务保留，确认删除？'
                  : '删除后不可恢复，确认删除？'
                AlertDialog.show({
                  title: '删除课题',
                  message: hint,
                  primaryButton: {
                    value: '取消',
                    action: () => {}
                  },
                  secondaryButton: {
                    value: '删除',
                    action: () => {
                      this.doDelete()
                    }
                  }
                })
              })
          }
          .width('100%')
          .padding({ left: Space.page, right: Space.page, bottom: Space.xl })
        }
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.canvas)
  }
}
