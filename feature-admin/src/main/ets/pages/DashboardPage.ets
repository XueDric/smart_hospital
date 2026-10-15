import {
  ApiError,
  AppColor,
  AppSize,
  AppText,
  EmptyState,
  InfoBanner,
  LoadingBlock,
  SectionTitle
} from 'common-core';
import { AdminRepository } from '../data/AdminRepository';
import { Dashboard, TrendPoint } from '../model/AdminModels';

@ComponentV2
export struct DashboardPage {
  private readonly repository: AdminRepository = AdminRepository.getInstance();
  @Local dashboard: Dashboard = new Dashboard();
  @Local loaded: boolean = false;
  @Local loading: boolean = true;
  @Local notice: string = '';
  @Local noticeTone: string = 'info';

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.notice = '';
    try {
      this.dashboard = await this.repository.dashboard();
      this.loaded = true;
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.loading = false;
    }
  }

  private maxCount(): number {
    let max = 1;
    for (const point of this.dashboard.trend) {
      if (point.count > max) {
        max = point.count;
      }
    }
    return max;
  }

  build() {
    Column() {
      Column() {
        Text('运营看板')
          .fontSize(AppText.HEADING)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.TEXT)
          .width('100%')
      }
      .width('100%')
      .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, top: 20, bottom: 12 })

      if (this.notice.length > 0) {
        InfoBanner({ message: this.notice, tone: this.noticeTone })
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.GAP })
      }

      Scroll() {
        Column() {
          if (this.loading) {
            LoadingBlock()
          } else if (!this.loaded) {
            EmptyState({ title: '暂无看板数据' })
          } else {
            this.statGrid()
            this.trendPanel()
            this.aggregatePanel()

            InfoBanner({
              message: '响应不含任何 patient_id / doctor_id / phone / name，只出聚合计数',
              tone: 'info'
            })
              .margin({ top: AppSize.GAP })
          }
        }
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: 24 })
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  statGrid() {
    Column() {
      Row() {
        this.statCard(`${this.dashboard.appointmentTotal}`, '累计挂号')
        this.statCard(`${this.dashboard.slotUsagePct}%`, '号源使用率')
      }
      .width('100%')

      Row() {
        this.statCard(`${this.dashboard.triageHitPct}%`, '分诊命中率')
        this.statCard(`${this.dashboard.previsitCompletionPct}%`, '预问诊完成率')
      }
      .width('100%')
      .margin({ top: AppSize.GAP })
    }
    .width('100%')
  }

  @Builder
  statCard(value: string, label: string) {
    Column() {
      Text(value)
        .fontSize(AppText.DISPLAY)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.PRIMARY_DARK)
      Text(label)
        .fontSize(AppText.CAPTION)
        .fontColor(AppColor.TEXT_SECONDARY)
        .margin({ top: 8 })
    }
    .layoutWeight(1)
    .height(96)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(AppColor.SURFACE)
    .borderRadius(AppSize.CARD_RADIUS)
    .margin({ right: AppSize.GAP })
  }

  @Builder
  trendPanel() {
    Column() {
      SectionTitle({ title: '近 7 日挂号趋势' })

      Row() {
        ForEach(this.dashboard.trend, (point: TrendPoint) => {
          Column() {
            Column()
              .width(24)
              .height(Math.max(8, Math.round(point.count / this.maxCount() * 120)))
              .backgroundColor(AppColor.PRIMARY)
              .borderRadius(4)
            Text(point.label)
              .fontSize(AppText.MICRO)
              .fontColor(AppColor.TEXT_SECONDARY)
              .margin({ top: 6 })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Center)
          .justifyContent(FlexAlign.End)
          .height(160)
        }, (point: TrendPoint) => point.label)
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(AppColor.SURFACE)
    .borderRadius(AppSize.CARD_RADIUS)
    .margin({ top: AppSize.GAP })
  }

  @Builder
  aggregatePanel() {
    Column() {
      SectionTitle({ title: '聚合指标' })

      this.metricRow('号源', `剩余 ${this.dashboard.remainSlots} / 共 ${this.dashboard.totalSlots}（排班 ${this.dashboard.scheduleCount} 条）`)
      this.metricRow('病历', `共 ${this.dashboard.recordTotal} 份 · 锁定 ${this.dashboard.recordLocked} · 草稿 ${this.dashboard.recordDraft} · 空 ${this.dashboard.recordEmpty}`)
      this.metricRow('AI', `模型 ${this.dashboard.aiModel} · 工具 ${this.dashboard.aiToolsEnabled}/${this.dashboard.aiToolsTotal} · 提示词 ${this.dashboard.aiPromptsCustomized}/${this.dashboard.aiPromptsTotal}`)
      this.metricRow('知识库', `文档 ${this.dashboard.kbDocsEnabled}/${this.dashboard.kbDocs} · 切块 ${this.dashboard.kbChunksEmbedded}/${this.dashboard.kbChunks} · 覆盖率 ${this.dashboard.kbEmbeddingCoveragePct}%`)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(AppColor.SURFACE)
    .borderRadius(AppSize.CARD_RADIUS)
    .margin({ top: AppSize.GAP })
  }

  @Builder
  metricRow(label: string, value: string) {
    Column() {
      Row() {
        Text(label)
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.TEXT_SECONDARY)
          .width(64)
        Text(value)
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.TEXT)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .border({ width: { bottom: 1 }, color: AppColor.BORDER })
    }
    .width('100%')
  }
}
