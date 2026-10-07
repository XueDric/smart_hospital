/**
 * 作者：刘运泽
 * 功能：状态胶囊（statusLabel 文案 + 逾期覆盖）
 * 修改记录：
 *   2026-09-16  首次编写
 *
 * 状态胶囊 StatusChip（h22 · 圆角 999 · 11 Medium）
 * 一处定义、全页复用。isOverdue=true 时覆盖显示「逾期」（服务端派生量）。
 */
import { FontSize, Radius, StatusColor, statusLabel, statusFg, statusBg } from '../core/Theme'

@Component
export struct StatusChip {
  @Prop status: string
  @Prop isOverdue: boolean = false

  build() {
    Text(this.isOverdue ? '已逾期' : statusLabel(this.status))
      .fontSize(FontSize.micro)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.isOverdue ? StatusColor.overdue.fg : statusFg(this.status))
      .backgroundColor(this.isOverdue ? StatusColor.overdue.bg : statusBg(this.status))
      .borderRadius(Radius.pill)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
  }
}
