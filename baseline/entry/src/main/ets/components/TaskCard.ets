/**
 * 作者：刘运泽
 * 功能：任务行（标题 + 状态胶囊 + 部门·负责人 + 截止标签 + 阻塞原因块）
 * 修改记录：
 *   2026-09-16  首次编写
 *   2026-09-17  恢复设计稿外观（卡片底色 / 阻塞原因块）
 *   2026-09-18  按 Figma 还原：改成「行」样式（组内单卡片 + divide 分隔，行不再自带卡片底色）
 *
 * TaskCard 行（无卡片底色，由父级 Card 容器包裹并画分隔线）：
 *   第 1 行：标题 + 状态胶囊；第 2 行：{部门} · 负责人 {负责人} + 右侧截止标签；
 *   blocked 时额外渲染阻塞原因高亮块（原因取 task.blocker，服务端派生）。
 */
import router from '@ohos.router'
import { TaskBrief } from '../api/TaskApi'
import { StatusChip } from './StatusChip'
import { Color, FontSize, Radius, Space, StatusColor } from '../core/Theme'

/** 截止标签：逾期 →「逾期 N 天」；完成 →「M-D 已完成」；今天 →「今天 HH:MM」；否则「M-D 截止」。 */
interface DueLabel {
  label: string
  color: string
}

function shortDue(task: TaskBrief): DueLabel {
  if (task.is_overdue) {
    const days: number = task.overdue_days ?? 0
    return { label: days > 0 ? `逾期 ${days} 天` : '已逾期', color: StatusColor.overdue.fg }
  }
  if (task.due_at === null || task.due_at.length === 0) {
    return { label: '无截止', color: Color.textTertiary }
  }
  const s: string = task.due_at
  const year: number = s.length >= 4 ? parseInt(s.substring(0, 4), 10) : 0
  const month: number = s.length >= 7 ? parseInt(s.substring(5, 7), 10) : 0
  const day: number = s.length >= 10 ? parseInt(s.substring(8, 10), 10) : 0
  const tIdx: number = s.indexOf('T') >= 0 ? s.indexOf('T') : s.indexOf(' ')
  let hhmm: string = ''
  if (tIdx >= 0 && s.length >= tIdx + 6) {
    hhmm = s.substring(tIdx + 1, tIdx + 6)
  }
  const md: string = `${month}-${day}`
  if (task.status === 'done') {
    return { label: `${md} 已完成`, color: StatusColor.done.fg }
  }
  const now: Date = new Date()
  const isToday: boolean = (now.getFullYear() === year) && (now.getMonth() + 1 === month) && (now.getDate() === day)
  if (isToday && hhmm.length > 0) {
    return { label: `今天 ${hhmm}`, color: Color.textSecondary }
  }
  return { label: `${md} 截止`, color: Color.textSecondary }
}

@Component
export struct TaskCard {
  @Prop task: TaskBrief

  private subtitle(): string {
    const deptName: string = this.task.dept?.name ?? ''
    const ownerName: string = this.task.owner?.name ?? '未分配'
    return deptName.length > 0 ? `${deptName} · 负责人 ${ownerName}` : `负责人 ${ownerName}`
  }

  private due(): DueLabel {
    return shortDue(this.task)
  }

  private showBlocker(): boolean {
    return this.task.status === 'blocked' && this.task.blocker !== null && this.task.blocker !== undefined && this.task.blocker.length > 0
  }

  build() {
    Column() {
      Row() {
        Text(this.task.title)
          .fontSize(FontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.task.is_overdue ? StatusColor.overdue.fg : Color.textPrimary)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        StatusChip({ status: this.task.status, isOverdue: this.task.is_overdue })
          .margin({ left: Space.sm })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row() {
        Text(this.subtitle())
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.due().label)
          .fontSize(FontSize.caption)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.due().color)
          .margin({ left: Space.sm })
      }
      .width('100%')
      .margin({ top: Space.xs })

      if (this.showBlocker()) {
        Column() {
          Text('阻塞原因（进入 blocked 必填）')
            .fontSize(FontSize.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.blockedText)
            .width('100%')
          Text(this.task.blocker as string)
            .fontSize(FontSize.caption)
            .fontColor(StatusColor.blocked.fg)
            .lineHeight(18)
            .width('100%')
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: Space.md, right: Space.md, top: Space.sm, bottom: Space.sm })
        .backgroundColor(StatusColor.blocked.bg)
        .borderRadius(Radius.input)
        .margin({ top: Space.sm })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: Space.lg, right: Space.lg, top: Space.md, bottom: Space.md })
    .onClick(() => {
      router.pushUrl({ url: 'pages/TaskDetailPage', params: { task_id: this.task.id } })
    })
  }
}
