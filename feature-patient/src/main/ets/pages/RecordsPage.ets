import { ApiError, AppRouter, RouteName } from 'common-core';
import { PatientRepository } from '../data/PatientRepository';
import { MedicalRecordSummary } from '../model/PatientModels';
import {
  EmptyState,
  InfoBanner,
  LoadingBlock,
  PageHeader,
  StatusChip
} from 'common-core';
import { AppColor, AppSize, AppText, formatEpoch } from 'common-core';

@ComponentV2
export struct RecordsPage {
  private readonly repository: PatientRepository = PatientRepository.getInstance();
  @Local loading: boolean = true;
  @Local errorMessage: string = '';
  @Local records: MedicalRecordSummary[] = [];

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    try {
      this.records = await this.repository.medicalRecords();
    } catch (error) {
      this.errorMessage = ApiError.from(error as Error).userMessage();
    } finally {
      this.loading = false;
    }
  }

  private statusText(record: MedicalRecordSummary): string {
    if (record.locked) {
      return '已提交';
    }
    if (record.status === 'draft') {
      return '草稿中';
    }
    return record.status.length > 0 ? record.status : '未知状态';
  }

  private statusColor(record: MedicalRecordSummary): string {
    return record.locked ? AppColor.SUCCESS : AppColor.WARNING;
  }

  private openDetail(appointmentId: number): void {
    const params: Record<string, Object> = { 'appointment_id': appointmentId };
    AppRouter.getInstance().push(RouteName.RECORD_DETAIL, params);
  }

  build() {
    Column() {
      PageHeader({
        title: '医疗档案',
        subtitle: '医生提交锁定后即可查看七段式病历',
        showBack: true
      })

      if (this.errorMessage.length > 0) {
        InfoBanner({
          message: this.errorMessage,
          tone: 'error',
          actionText: '重试',
          onAction: () => this.load()
        })
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.GAP })
      }

      Scroll() {
        Column() {
          if (this.loading) {
            LoadingBlock({ text: '正在加载医疗档案' })
          } else if (this.records.length === 0) {
            EmptyState({
              title: '暂无医疗档案',
              description: '就诊完成后，医生提交的病历会显示在这里'
            })
          } else {
            ForEach(this.records, (record: MedicalRecordSummary) => {
              Column() {
                Row() {
                  Text(`就诊单 #${record.appointmentId}`)
                    .fontSize(AppText.SUBHEADING)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(AppColor.TEXT)
                    .layoutWeight(1)
                  StatusChip({
                    text: this.statusText(record),
                    color: this.statusColor(record),
                    chipBackground: AppColor.SURFACE_ALT
                  })
                }
                .width('100%')

                Row() {
                  Text(`已填 ${record.filled}/${record.totalSections} 段`)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT_SECONDARY)
                    .layoutWeight(1)
                  Text(`更新于 ${formatEpoch(record.updatedAt)}`)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT_SECONDARY)
                }
                .width('100%')
                .margin({ top: 10 })

                Text(record.locked ? '点击查看病历正文' : '病历尚未提交，暂不可查看正文')
                  .fontSize(AppText.CAPTION)
                  .fontColor(record.locked ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
                  .width('100%')
                  .margin({ top: 10 })
              }
              .width('100%')
              .padding(14)
              .backgroundColor(AppColor.SURFACE)
              .borderRadius(AppSize.CARD_RADIUS)
              .margin({ bottom: 10 })
              .onClick(() => this.openDetail(record.appointmentId))
            }, (record: MedicalRecordSummary) => `${record.appointmentId}`)
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
