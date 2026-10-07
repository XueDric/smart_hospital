// 负责人：杨睿（前端组长）
// 智能结果三态卡片 —— 统一渲染「来源角标 + 内容 + 依据」三种呈现：
//   source=model     正常卡片，角标「AI 建议」；
//   source=fallback  照常展示但弱化为灰底、角标「依据历史数据」，不得让用户误以为是大模型给的；
//   source=none      只留一句「智能建议暂不可用」，不放骨架、不留空白。
// 另处理加载态（内联 loading）与网络错误态（手动重试）；三态都不阻塞主流程。

import { Color, FontSize, Radius, Space, StatusColor } from '../core/Theme'

@Component
export struct AiCard {
  @Prop source: string = 'none'
  @Prop loading: boolean = false
  @Prop errorMsg: string = ''
  @Prop title: string = ''
  @Prop body: string = ''
  @Prop items: string[] = []
  @Prop note: string = ''
  onRetry: () => void = () => {}

  private isModel(): boolean {
    return this.source === 'model'
  }

  private isFallback(): boolean {
    return this.source === 'fallback'
  }

  private isNone(): boolean {
    return this.source === 'none'
  }

  @Builder
  sourceBadge() {
    Text(this.isModel() ? 'AI 建议' : '依据历史数据')
      .fontSize(FontSize.micro)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.isModel() ? Color.primary : Color.textTertiary)
      .backgroundColor(this.isModel() ? Color.primarySoft : Color.control)
      .borderRadius(Radius.pill)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
  }

  @Builder
  basisLine(text: string) {
    Row({ space: 6 }) {
      Circle()
        .width(4)
        .height(4)
        .fill(this.isFallback() ? Color.textTertiary : Color.primary)
        .margin({ top: 7 })
      Text(text)
        .fontSize(FontSize.caption)
        .fontColor(this.isFallback() ? Color.textTertiary : Color.textSecondary)
        .lineHeight(18)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
  }

  build() {
    Column() {
      if (this.loading) {
        Row({ space: Space.sm }) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color(Color.primary)
          Text('正在生成…')
            .fontSize(FontSize.caption)
            .fontColor(Color.textTertiary)
        }
        .width('100%')
        .padding({ top: Space.xs, bottom: Space.xs })
      } else if (this.errorMsg.length > 0) {
        Row() {
          Text(this.errorMsg)
            .fontSize(FontSize.caption)
            .fontColor(StatusColor.overdue.fg)
            .layoutWeight(1)
          Text('重试')
            .fontSize(FontSize.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.primary)
            .onClick(() => this.onRetry())
        }
        .width('100%')
        .padding({ top: Space.xs, bottom: Space.xs })
      } else if (this.isNone()) {
        Text('智能建议暂不可用')
          .fontSize(FontSize.caption)
          .fontColor(Color.textTertiary)
          .width('100%')
          .padding({ top: Space.xs, bottom: Space.xs })
      } else {
        Row() {
          this.sourceBadge()
          if (this.note.length > 0) {
            Text(this.note)
              .fontSize(FontSize.micro)
              .fontColor(Color.textTertiary)
              .margin({ left: Space.sm })
              .layoutWeight(1)
          }
        }
        .width('100%')

        Column({ space: Space.sm }) {
          if (this.title.length > 0) {
            Text(this.title)
              .fontSize(FontSize.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isFallback() ? Color.textSecondary : Color.textPrimary)
              .width('100%')
          }
          if (this.body.length > 0) {
            Text(this.body)
              .fontSize(FontSize.body)
              .fontColor(this.isFallback() ? Color.textSecondary : Color.textPrimary)
              .lineHeight(20)
              .width('100%')
          }
          if (this.items.length > 0) {
            Column({ space: Space.xs }) {
              ForEach(this.items, (item: string, index: number) => {
                this.basisLine(item)
              }, (item: string, index: number): string => `${index}-${item}`)
            }
            .width('100%')
          }
        }
        .width('100%')
        .padding({ top: Space.md })
      }
    }
    .width('100%')
    .padding(Space.lg)
    .backgroundColor(this.isFallback() ? Color.canvas : Color.surface)
    .border({ width: 1, color: this.isFallback() ? Color.divider : Color.border })
    .borderRadius(Radius.card)
  }
}
