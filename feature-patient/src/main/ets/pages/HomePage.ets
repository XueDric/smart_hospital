import { ApiError, AppRouter, RouteName, SessionStore } from 'common-core';
import { PatientRepository } from '../data/PatientRepository';
import { Appointment, PatientNotice } from '../model/PatientModels';
import {
  EmptyState,
  InfoBanner,
  LoadingBlock,
  SectionTitle,
  StatusChip
} from 'common-core';
import {
  AppColor,
  AppSize,
  AppText,
  VisitStatus,
  appointmentDisplayText,
  appointmentStatusColor,
  periodText
} from 'common-core';

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
    // 先清掉上一次加载的结果，避免退号后刷新接口返回空列表时仍展示旧卡片（缺陷 C-D）。
    this.hasNextAppointment = false;
    this.nextAppointment = new Appointment();
    /*
     * ★ 2026-10-17（评审 P2-9）：公告改为读服务端，且**单独 try**。
     *   理由：公告是首页的附加卡片，「下一次就诊」才是主信息 ——
     *   公告接口失败（或该角色无 ViewNotice 权限）不该把整页变成错误页。
     */
    try {
      this.notices = await this.repository.notices();
    } catch (error) {
      this.notices = [];
    }
    try {
      const appointments = await this.repository.appointments(false);
      let next = new Appointment();
      let found = false;
      for (const appointment of appointments) {
        if (!VisitStatus.isActive(appointment.status)) {
          continue;
        }
        /*
         * 服务端列表按 created_at DESC 返回，不能直接取第一条（缺陷 C-C）。
         * 当前正在就诊的优先，其次按 visit_date / period / seq_no 取最早的一张。
         */
        if (!found || this.isEarlierVisit(appointment, next)) {
          next = appointment;
          found = true;
        }
      }
      this.nextAppointment = next;
      this.hasNextAppointment = found;
    } catch (error) {
      this.errorMessage = ApiError.from(error as Error).userMessage();
    } finally {
      this.loading = false;
    }
  }

  private isEarlierVisit(candidate: Appointment, current: Appointment): boolean {
    const candidatePriority = this.statusPriority(candidate.status);
    const currentPriority = this.statusPriority(current.status);
    if (candidatePriority !== currentPriority) {
      return candidatePriority < currentPriority;
    }
    if (candidate.visitDate.length === 0 || current.visitDate.length === 0) {
      if (candidate.visitDate.length !== current.visitDate.length) {
        return candidate.visitDate.length > 0;
      }
    } else if (candidate.visitDate !== current.visitDate) {
      return candidate.visitDate < current.visitDate;
    }
    const candidatePeriod = this.periodPriority(candidate.period);
    const currentPeriod = this.periodPriority(current.period);
    if (candidatePeriod !== currentPeriod) {
      return candidatePeriod < currentPeriod;
    }
    return candidate.seqNo < current.seqNo;
  }

  private statusPriority(status: string): number {
    if (status === VisitStatus.VISITING) {
      return 0;
    }
    if (status === VisitStatus.WAITING) {
      return 1;
    }
    if (status === VisitStatus.ARRIVED) {
      return 2;
    }
    if (status === VisitStatus.BOOKED) {
      return 3;
    }
    // 服务端将来新增的活动状态按“需要优先关注”处理，避免被已知状态挤掉。
    return 0;
  }

  private periodPriority(period: string): number {
    if (period === 'AM') {
      return 0;
    }
    if (period === 'PM') {
      return 1;
    }
    return 2;
  }

  private navigate(route: string): void {
    AppRouter.getInstance().push(route);
  }

  /** 状态文案：优先服务端 status_label，本地兜底表只在字段缺失时生效。 */
  private nextStatusText(): string {
    return appointmentDisplayText(this.nextAppointment.status, this.nextAppointment.statusLabel);
  }

  /** 科室与医生：优先用服务端下发的名字，缺字段时才回落到 id。 */
  private nextPlaceText(): string {
    const appointment = this.nextAppointment;
    const department = appointment.departmentName.length > 0
      ? appointment.departmentName : `科室 #${appointment.departmentId}`;
    let doctor = `医生 #${appointment.doctorId}`;
    if (appointment.doctorName.length > 0) {
      doctor = appointment.doctorTitle.length > 0
        ? `${appointment.doctorName} ${appointment.doctorTitle}` : appointment.doctorName;
    }
    return `${department} · ${doctor}`;
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
                Text(this.nextPlaceText())
                  .fontSize(AppText.CAPTION)
                  .fontColor(AppColor.TEXT_SECONDARY)
                  .margin({ top: 6 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              StatusChip({
                text: this.nextStatusText(),
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
            message: '目前没有已挂号的预约，可以先完成智能分诊再选择号源。',
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
                  .fontSize(AppText.LEAD)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColor.PRIMARY_DARK)
                  .width(AppSize.TOUCH_MIN)
                  .height(AppSize.TOUCH_MIN)
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
