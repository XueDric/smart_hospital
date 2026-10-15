import { ApiError, AppRouter, ErrorCode } from 'common-core';
import { PatientRepository } from '../data/PatientRepository';
import { MedicalRecordDetail, MedicalRecordSection } from '../model/PatientModels';
import {
  EmptyState,
  InfoBanner,
  LoadingBlock,
  PageHeader,
  StatusChip
} from 'common-core';
import { AppColor, AppSize, AppText, formatEpoch } from 'common-core';

@ComponentV2
export struct RecordDetailPage {
  private readonly repository: PatientRepository = PatientRepository.getInstance();
  @Local appointmentId: number = 0;
  @Local loading: boolean = true;
  @Local errorMessage: string = '';
  @Local notSubmitted: boolean = false;
  @Local record: MedicalRecordDetail = new MedicalRecordDetail();

  aboutToAppear(): void {
    this.appointmentId = Number(AppRouter.getInstance().getParam('appointment_id') ?? 0);
    this.load();
  }

  async load(): Promise<void> {
    if (this.appointmentId <= 0) {
      this.loading = false;
      this.errorMessage = '缺少就诊单编号';
      return;
    }
    this.loading = true;
    this.errorMessage = '';
    this.notSubmitted = false;
    try {
      this.record = await this.repository.medicalRecordDetail(this.appointmentId);
    } catch (error) {
      const apiError = ApiError.from(error as Error);
      if (apiError.code === ErrorCode.EMR_NOT_FOUND) {
        // 服务端刻意让「不存在」与「仍是草稿」不可区分，统一按「尚未提交」处理。
        this.notSubmitted = true;
      } else {
        this.errorMessage = apiError.userMessage();
      }
    } finally {
      this.loading = false;
    }
  }

  build() {
    Column() {
      PageHeader({
        title: '病历详情',
        subtitle: this.appointmentId > 0 ? `就诊单 #${this.appointmentId}` : '七段式电子病历',
        showBack: true
      })

      Scroll() {
        Column() {
          if (this.loading) {
            LoadingBlock({ text: '正在加载病历正文' })
          } else if (this.notSubmitted) {
            EmptyState({
              title: '病历尚未提交',
              description: '医生提交锁定后即可在此查看，请稍后再试'
            })
          } else if (this.errorMessage.length > 0) {
            InfoBanner({
              message: this.errorMessage,
              tone: 'error',
              actionText: '重试',
              onAction: () => this.load()
            })
          } else {
            this.metaCard()
            ForEach(this.record.sections, (section: MedicalRecordSection) => {
              this.sectionCard(section)
            }, (section: MedicalRecordSection) => section.key)
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

  @Builder
  metaCard() {
    Column() {
      Row() {
        Text('病历状态')
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.TEXT_SECONDARY)
          .layoutWeight(1)
        StatusChip({
          text: this.record.locked ? '已提交锁定' : '草稿中',
          color: this.record.locked ? AppColor.SUCCESS : AppColor.WARNING,
          chipBackground: AppColor.SURFACE_ALT
        })
      }
      .width('100%')
      Text(`已填 ${this.record.filled}/${this.record.totalSections} 段 · 更新于 ${formatEpoch(this.record.updatedAt)}`)
        .fontSize(AppText.CAPTION)
        .fontColor(AppColor.TEXT_SECONDARY)
        .width('100%')
        .margin({ top: 10 })
      if (this.record.missingRequired.length > 0) {
        Text(`仍缺必填段：${this.record.missingRequired.join('、')}`)
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.WARNING)
          .width('100%')
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(AppColor.SURFACE)
    .borderRadius(AppSize.CARD_RADIUS)
    .margin({ bottom: AppSize.GAP })
  }

  @Builder
  sectionCard(section: MedicalRecordSection) {
    Column() {
      Row() {
        Text(section.label.length > 0 ? section.label : section.key)
          .fontSize(AppText.SUBHEADING)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.TEXT)
          .layoutWeight(1)
        if (section.requiredToLock) {
          Text('必填')
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.WARNING)
        }
      }
      .width('100%')
      Text(section.value.length > 0 ? section.value : '未填写')
        .fontSize(AppText.BODY)
        .fontColor(section.value.length > 0 ? AppColor.TEXT : AppColor.TEXT_SECONDARY)
        .lineHeight(23)
        .width('100%')
        .margin({ top: 10 })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(AppColor.SURFACE)
    .borderRadius(AppSize.CARD_RADIUS)
    .margin({ bottom: 10 })
  }
}
