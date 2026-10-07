/**
 * 作者：刘运泽
 * 功能：分段控件（单选选择器，受控组件）
 * 修改记录：
 *   2026-09-17  首次提取为独立组件并恢复设计稿外观
 *
 * 分段控件 SegmentedControl（§3.8）
 * 外框 h36 / r10 / bg #F0F2F5 / padding 3；每段 r8，选中段主色底白字 + L1 阴影。
 */
import { Color, FontSize, Radius, Shadow } from '../core/Theme'

@Component
export struct SegmentedControl {
  options: string[] = []
  @Prop selectedIndex: number = 0
  onChange?: (i: number) => void

  @Builder
  segment(opt: string, i: number) {
    if (i === this.selectedIndex) {
      Text(opt)
        .fontSize(FontSize.caption)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.onPrimary)
        .backgroundColor(Color.primary)
        .borderRadius(8)
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .height(30)
        .shadow(Shadow.card)
        .onClick(() => {
          if (this.onChange) this.onChange(i)
        })
    } else {
      Text(opt)
        .fontSize(FontSize.caption)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.textSecondary)
        .borderRadius(8)
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .height(30)
        .onClick(() => {
          if (this.onChange) this.onChange(i)
        })
    }
  }

  build() {
    Row({ space: 3 }) {
      ForEach(this.options, (opt: string, i: number) => {
        this.segment(opt, i)
      }, (opt: string, i: number) => `${i}-${opt}`)
    }
    .width('100%')
    .height(36)
    .padding(3)
    .backgroundColor(Color.control)
    .borderRadius(Radius.input)
  }
}
