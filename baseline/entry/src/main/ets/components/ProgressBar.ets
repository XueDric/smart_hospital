/**
 * 作者：刘运泽
 * 功能：进度条组件（done/total，服务端递归聚合）
 * 修改记录：
 *   2026-09-16  首次编写
 *   2026-09-17  恢复设计稿高度（@Prop height → trackHeight 修复同名冲突）
 *
 * 进度条 ProgressBar（课题树顶层 h4 / 课题详情 h6，见 §3.12）
 * done/total 是服务端递归聚合值，客户端只负责画。
 */
import { Color, StatusColor } from '../core/Theme'

@Component
export struct ProgressBar {
  @Prop done: number
  @Prop total: number
  @Prop trackHeight: number = 6

  build() {
    Progress({
      value: this.total > 0 ? this.done : 0,
      total: this.total > 0 ? this.total : 1,
      type: ProgressType.Linear
    })
      .color(Color.primary)
      .backgroundColor(StatusColor.todo.bg)
      .height(this.trackHeight)
      .width('100%')
  }
}
