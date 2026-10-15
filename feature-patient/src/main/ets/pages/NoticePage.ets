import { PatientRepository } from '../data/PatientRepository';
import { PatientNotice } from '../model/PatientModels';
import { EmptyState, PageHeader, StatusChip } from 'common-core';
import { AppColor, AppSize, AppText } from 'common-core';

@ComponentV2
export struct NoticePage {
  private readonly repository: PatientRepository = PatientRepository.getInstance();
  @Local notices: PatientNotice[] = [];

  aboutToAppear(): void {
    this.notices = this.repository.notices();
  }

  build() {
    Column() {
      PageHeader({
        title: '医疗公告',
        subtitle: '本地公告与服务说明（服务端暂无消息接口）',
        showBack: true
      })

      Scroll() {
        Column() {
          if (this.notices.length === 0) {
            EmptyState({ title: '暂无公告' })
          } else {
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
        }
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: 24 })
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.BACKGROUND)
  }
}
