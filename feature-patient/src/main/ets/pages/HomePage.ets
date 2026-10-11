import { ApiError, AppRouter, RouteName, SessionStore } from 'common-core';
import { PatientRepository } from '../data/PatientRepository';
import { Appointment, PatientNotice } from '../model/PatientModels';
import {
  EmptyState,
  InfoBanner,
  LoadingBlock,
  SectionTitle,
  StatusChip
} from '../ui/CommonComponents';
import {
  AppColor,
  AppSize,
  AppText,
  appointmentStatusColor,
  appointmentStatusText,
  periodText
} from '../ui/Theme';

class QuickAction {
  title: string = '';
  subtitle: string = '';
  glyph: string = '';
  route: string = '';

  constructor(title: string, subtitle: string, glyph: string, route: string) {
    this.title = title;
    this.subtitle = subtitle;
    this.glyph = glyph;
    this.route = route;
  }
}

@ComponentV2
export struct HomePage {
  private readonly repository: PatientRepository = PatientRepository.getInstance();
  private readonly actions: QuickAction[] = [
    new QuickAction('智能分诊', '描述症状找科室', '诊', RouteName.TRIAGE),
    new QuickAction('预问诊', '提前整理病情', '问', RouteName.PREVISIT),
    new QuickAction('预约挂号', '按日期查号源', '约', RouteName.BOOKING),
    new QuickAction('医疗档案', '查看就诊记录', '档', RouteName.RECORDS)
  ];
  @Local loading: boolean = true;
  @Local errorMessage: string = '';
  @Local hasNextAppointment: boolean = false;
  @Local nextAppointment: Appointment = new Appointment();
  @Local notices: PatientNotice[] = [];

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    this.notices = this.repository.notices();
    try {
      const appointments = await this.repository.appointments(false);
      for (const appointment of appointments) {
        if (appointment.status === 'booked' || appointment.status === 'visiting') {
          this.nextAppointment = appointment;
          this.hasNextAppointment = true;
          break;
        }
      }
    } catch (error) {
      this.errorMessage = ApiError.from(error as Error).userMessage();
    } finally {
      this.loading = false;
    }
  }

  private navigate(route: string): void {
    AppRouter.getInstance().push(route);
  }

  build() {
    Scroll() {
      Column() {
        Column() {
          Text(`您好，${SessionStore.getDisplayName().length > 0 ? SessionStore.getDisplayName() : '患者'}`)
            .fontSize(AppText.TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.TEXT)
            .width('100%')
          Text('今天需要什么帮助？')
            .fontSize(AppText.BODY)
            .fontColor(AppColor.TEXT_SECONDARY)
            .width('100%')
            .margin({ top: 6 })
        }
        .width('100%')
        .padding({ top: 24, bottom: 18, left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })

        if (this.errorMessage.length > 0) {
          InfoBanner({
            message: this.errorMessage,
            tone: 'error',
            actionText: '重试',
            onAction: () => this.load()
          })
            .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })
        }

        if (this.loading) {
          LoadingBlock({ text: '正在同步就诊信息' })
        } else if (this.hasNextAppointment) {
          Column() {
            Row() {
              Column() {
                Text('下一次就诊')
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.TEXT_SECONDARY)
                Text(`${this.nextAppointment.visitDate} ${periodText(this.nextAppointment.period)}`)
                  .fontSize(AppText.HEADING)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColor.TEXT)
                  .margin({ top: 6 })
                Text(`科室 #${this.nextAppointment.departmentId} · 医生 #${this.nextAppointment.doctorId}`)
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.TEXT_SECONDARY)
                  .margin({ top: 6 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              StatusChip({
                text: appointmentStatusText(this.nextAppointment.status),
                color: appointmentStatusColor(this.nextAppointment.status),
                chipBackground: AppColor.INFO_SOFT
              })
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }
          .width('100%')
          .padding(16)
          .backgroundColor(AppColor.SURFACE)
          .borderRadius(AppSize.CARD_RADIUS)
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })
          .onClick(() => AppRouter.getInstance().reset(RouteName.APPOINTMENTS))
        } else {
          InfoBanner({
            message: '目前没有待就诊预约，可以先完成智能分诊再选择号源。',
            tone: 'info',
            actionText: '去分诊',
            onAction: () => AppRouter.getInstance().push(RouteName.TRIAGE)
          })
            .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })
        }

        Column() {
          SectionTitle({ title: '常用服务' })
          Row() {
            ForEach(this.actions, (action: QuickAction) => {
              Column() {
                Text(action.glyph)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColor.PRIMARY_DARK)
                  .width(40)
                  .height(40)
                  .textAlign(TextAlign.Center)
                  .backgroundColor(AppColor.PRIMARY_SOFT)
                  .borderRadius(20)
                Text(action.title)
                  .fontSize(AppText.SUBHEADING)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(AppColor.TEXT)
                  .margin({ top: 8 })
                Text(action.subtitle)
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.TEXT_SECONDARY)
                  .margin({ top: 4 })
                  .maxLines(1)
              }
              .layoutWeight(1)
              .height(128)
              .justifyContent(FlexAlign.Center)
              .padding({ left: 4, right: 4 })
              .onClick(() => this.navigate(action.route))
            }, (action: QuickAction) => action.route)
          }
          .width('100%')
          .padding({ top: 8, bottom: 8 })
        }
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })

        Column() {
          SectionTitle({
            title: '医疗公告',
            action: '全部',
            onAction: () => AppRouter.getInstance().push(RouteName.NOTICE)
          })
          if (this.notices.length === 0) {
            EmptyState({ title: '暂无公告' })
          } else {
            ForEach(this.notices.slice(0, 2), (notice: PatientNotice) => {
              Column() {
                Row() {
                  Text(notice.category)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.PRIMARY_DARK)
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
                  .margin({ top: 8 })
                Text(notice.body)
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.TEXT_SECONDARY)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 6 })
              }
              .width('100%')
              .padding(14)
              .backgroundColor(AppColor.SURFACE)
              .borderRadius(AppSize.CARD_RADIUS)
              .margin({ bottom: 10 })
              .onClick(() => AppRouter.getInstance().push(RouteName.NOTICE))
            })
          }
        }
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: 24 })
      }
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.BACKGROUND)
  }
}
