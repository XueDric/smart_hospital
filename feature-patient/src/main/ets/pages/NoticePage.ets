import { PatientRepository } from '../data/PatientRepository';
import { PatientNotice } from '../model/PatientModels';
import { EmptyState, PageHeader, StatusChip } from 'common-core';
import { AppButton } from 'common-core';
import { AppColor, AppSize, AppText } from 'common-core';
import { ApiError } from 'common-core';
import { LoadingBlock } from 'common-core';

@ComponentV2
export struct NoticePage {
  private readonly repository: PatientRepository = PatientRepository.getInstance();
  @Local notices: PatientNotice[] = [];
  @Local loading: boolean = true;
  @Local errorMessage: string = '';

  aboutToAppear(): void {
    this.load();
  }

  /*
   * ★ 2026-10-17（评审 P2-9）：公告来自服务端 `GET /api/v1/notices`。
   *   三态齐全（加载 / 失败 / 空）—— 改之前是同步返回本地 Mock，
   *   既没有加载态也没有失败态，所以"服务端挂了"和"真的没有公告"
   *   在界面上长得一模一样，患者只会以为医院没发通知。
   */
  async load(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    try {
      this.notices = await this.repository.notices();
    } catch (error) {
      this.errorMessage = ApiError.from(error as Error).userMessage();
      this.notices = [];
    } finally {
      this.loading = false;
    }
  }

  build() {
    Column() {
      PageHeader({
        title: '医疗公告',
        subtitle: '由医院后台发布，按发布时间倒序',
        showBack: true
      })

      if (this.loading) {
        LoadingBlock({ text: '正在加载公告' })
      } else if (this.errorMessage.length > 0) {
        Column() {
          EmptyState({ title: '公告加载失败', description: this.errorMessage })
          AppButton({ text: '重试', secondary: true, onTap: () => { this.load(); } })
            .margin({ top: 12 })
        }
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })
      } else if (this.notices.length === 0) {
        EmptyState({ title: '暂无公告', description: '医院尚未发布公告' })
      } else {
        this.noticeList()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.BACKGROUND)
  }

  @Builder
  noticeList() {
    Scroll() {
      Column() {
        ForEach(this.notices, (notice: PatientNotice) => {
          Column() {
            Row() {
              StatusChip({
                text: notice.category,
                color: AppColor.PRIMARY_DARK,
                chipBackground: AppColor.PRIMARY_SOFT
              })
              Text(notice.date)
                .fontSize(AppText.CAPTION)
                .fontColor(AppColor.TEXT_SECONDARY)
                .margin({ left: 10 })
            }
            .width('100%')
            Text(notice.title)
              .fontSize(AppText.SUBHEADING)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.TEXT)
              .width('100%')
              .margin({ top: 10 })
            Text(notice.body)
              .fontSize(AppText.BODY)
              .fontColor(AppColor.TEXT_SECONDARY)
              .lineHeight(23)
              .width('100%')
              .margin({ top: 8 })
          }
          .width('100%')
          .padding(14)
          .backgroundColor(AppColor.SURFACE)
          .borderRadius(AppSize.CARD_RADIUS)
          .margin({ bottom: 10 })
        }, (notice: PatientNotice) => `${notice.id}`)
      }
      .width('100%')
      .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: 24 })
    }
    .layoutWeight(1)
    .width('100%')
  }
}
