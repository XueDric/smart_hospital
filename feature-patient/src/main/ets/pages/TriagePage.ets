import { ApiError, AppRouter, RouteName } from 'common-core';
import { PatientRepository } from '../data/PatientRepository';
import { TriageOption, TriageResult } from '../model/PatientModels';
import { AppButton, InfoBanner, LoadingBlock, PageHeader, SectionTitle, StatusChip } from '../ui/CommonComponents';
import {
  AppColor,
  AppSize,
  AppText,
  periodText,
  reasonText,
  sourceText
} from '../ui/Theme';

@ComponentV2
export struct TriagePage {
  private readonly repository: PatientRepository = PatientRepository.getInstance();
  @Local chiefComplaint: string = '';
  @Local loading: boolean = false;
  @Local errorMessage: string = '';
  @Local hasResult: boolean = false;
  @Local result: TriageResult = new TriageResult();

  async submit(): Promise<void> {
    if (this.loading) {
      return;
    }
    if (this.chiefComplaint.trim().length === 0) {
      this.errorMessage = '请先描述您的主要不适';
      return;
    }
    this.loading = true;
    this.errorMessage = '';
    this.hasResult = false;
    try {
      this.result = await this.repository.triage(this.chiefComplaint.trim());
      this.hasResult = true;
    } catch (error) {
      this.errorMessage = ApiError.from(error as Error).userMessage();
    } finally {
      this.loading = false;
    }
  }

  private goBooking(option: TriageOption): void {
    const params: Record<string, Object> = {
      'department_id': option.departmentId,
      'department_name': option.departmentName,
      'doctor_id': option.doctorId,
      'doctor_name': option.doctorName,
      'doctor_title': option.doctorTitle,
      'schedule_id': option.scheduleId,
      'work_date': option.workDate,
      'period': option.period
    };
    AppRouter.getInstance().push(RouteName.BOOKING, params);
  }

  build() {
    Column() {
      PageHeader({
        title: '智能分诊',
        subtitle: '描述症状，服务端会校验真实可用号源'
      })

      Scroll() {
        Column() {
          Column() {
            Text('主要哪里不舒服？')
              .fontSize(AppText.SUBHEADING)
              .fontWeight(FontWeight.Medium)
              .fontColor(AppColor.TEXT)
              .width('100%')
            TextArea({
              placeholder: '例如：咳嗽三天，伴咽痛，无发热',
              text: this.chiefComplaint
            })
              .width('100%')
              .height(128)
              .fontSize(AppText.BODY)
              .backgroundColor(AppColor.SURFACE_ALT)
              .borderRadius(AppSize.CONTROL_RADIUS)
              .maxLength(500)
              .margin({ top: 10 })
              .onChange((value: string) => {
                this.chiefComplaint = value;
              })
            Row() {
              Text('建议包含症状、持续时间和伴随表现')
                .fontSize(AppText.CAPTION)
                .fontColor(AppColor.TEXT_SECONDARY)
                .layoutWeight(1)
              Text(`${this.chiefComplaint.length}/500`)
                .fontSize(AppText.CAPTION)
                .fontColor(AppColor.TEXT_SECONDARY)
            }
            .width('100%')
            .margin({ top: 6 })

            AppButton({
              text: this.loading ? '正在分析…' : '开始分诊',
              isEnabled: !this.loading,
              onTap: () => this.submit()
            })
              .margin({ top: AppSize.GAP })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(AppColor.SURFACE)
          .borderRadius(AppSize.CARD_RADIUS)

          if (this.errorMessage.length > 0) {
            InfoBanner({ message: this.errorMessage, tone: 'error' })
              .margin({ top: AppSize.GAP })
          }

          if (this.loading) {
            LoadingBlock({ text: '正在匹配科室并核验号源' })
          }

          if (this.hasResult) {
            if (this.result.redFlag) {
              Column() {
                Text('危急征象提醒')
                  .fontSize(AppText.HEADING)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColor.DANGER)
                Text(this.result.patientNote)
                  .fontSize(AppText.SUBHEADING)
                  .fontColor(AppColor.DANGER)
                  .lineHeight(24)
                  .width('100%')
                  .margin({ top: 10 })
                Text('请立即前往急诊或拨打 120。本页不会推荐普通门诊号源。')
                  .fontSize(AppText.BODY)
                  .fontColor(AppColor.TEXT)
                  .width('100%')
                  .margin({ top: 10 })
              }
              .width('100%')
              .padding(16)
              .backgroundColor(AppColor.DANGER_SOFT)
              .borderRadius(AppSize.CARD_RADIUS)
              .margin({ top: AppSize.SECTION_GAP })
            } else {
              Column() {
                Row() {
                  Text('分诊结论')
                    .fontSize(AppText.HEADING)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(AppColor.TEXT)
                    .layoutWeight(1)
                  StatusChip({ text: reasonText(this.result.reasonCode) })
                }
                .width('100%')
                Text(this.result.patientNote)
                  .fontSize(AppText.BODY)
                  .fontColor(AppColor.TEXT)
                  .lineHeight(23)
                  .width('100%')
                  .margin({ top: 12 })

                if (this.result.truncated) {
                  InfoBanner({
                    message: '主诉较长，服务端已按规则截断后分析。',
                    tone: 'warning'
                  })
                    .margin({ top: 12 })
                }

                Column() {
                  Text('判断依据')
                    .fontSize(AppText.SUBHEADING)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(AppColor.TEXT)
                    .width('100%')
                  Text(`1. 推荐来源：${sourceText(this.result.source)}`)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT_SECONDARY)
                    .width('100%')
                    .margin({ top: 8 })
                  Text(`2. 校验结果：${reasonText(this.result.reasonCode)}`)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT_SECONDARY)
                    .width('100%')
                    .margin({ top: 6 })
                  Text(`3. 可用号源：${this.result.count} 个，均来自服务端实时校验`)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT_SECONDARY)
                    .width('100%')
                    .margin({ top: 6 })
                  if (this.result.aiReason.length > 0) {
                    Text(`4. 辅助说明：${this.result.aiReason}`)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.TEXT_SECONDARY)
                      .width('100%')
                      .margin({ top: 6 })
                  }
                }
                .width('100%')
                .padding(12)
                .backgroundColor(AppColor.SURFACE_ALT)
                .borderRadius(AppSize.CARD_RADIUS)
                .margin({ top: 12 })
              }
              .width('100%')
              .padding(16)
              .backgroundColor(AppColor.SURFACE)
              .borderRadius(AppSize.CARD_RADIUS)
              .margin({ top: AppSize.SECTION_GAP })

              if (this.result.options.length > 0) {
                Column() {
                  SectionTitle({ title: '推荐号源' })
                  ForEach(this.result.options, (option: TriageOption) => {
                    Column() {
                      Row() {
                        Column() {
                          Text(option.departmentName)
                            .fontSize(AppText.SUBHEADING)
                            .fontWeight(FontWeight.Bold)
                            .fontColor(AppColor.TEXT)
                          Text(`${option.doctorName} · ${option.doctorTitle}`)
                            .fontSize(AppText.CAPTION)
                            .fontColor(AppColor.TEXT_SECONDARY)
                            .margin({ top: 5 })
                        }
                        .layoutWeight(1)
                        .alignItems(HorizontalAlign.Start)
                        StatusChip({
                          text: option.remainNum > 0 ? `余 ${option.remainNum}` : '已约满',
                          color: option.remainNum > 0 ? AppColor.SUCCESS : AppColor.DANGER,
                          chipBackground: option.remainNum > 0 ? AppColor.SUCCESS_SOFT : AppColor.DANGER_SOFT
                        })
                      }
                      .width('100%')

                      Row() {
                        Text(`${option.workDate} ${periodText(option.period)}`)
                          .fontSize(AppText.BODY)
                          .fontColor(AppColor.TEXT)
                          .layoutWeight(1)
                        Text(`当日可约 ${option.totalRemain}`)
                          .fontSize(AppText.CAPTION)
                          .fontColor(AppColor.TEXT_SECONDARY)
                      }
                      .width('100%')
                      .margin({ top: 12 })

                      AppButton({
                        text: option.remainNum > 0 ? '选择该号源' : '暂无号源',
                        isEnabled: option.remainNum > 0,
                        onTap: () => this.goBooking(option)
                      })
                        .margin({ top: 12 })
                    }
                    .width('100%')
                    .padding(14)
                    .backgroundColor(AppColor.SURFACE)
                    .borderRadius(AppSize.CARD_RADIUS)
                    .margin({ bottom: 10 })
                  }, (option: TriageOption) => `${option.scheduleId}`)
                }
                .width('100%')
                .margin({ top: AppSize.SECTION_GAP })
              } else {
                InfoBanner({
                  message: '当前没有可直接预约的号源，请更换日期或稍后再试。',
                  tone: 'warning'
                })
                  .margin({ top: AppSize.SECTION_GAP })
              }
            }
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
