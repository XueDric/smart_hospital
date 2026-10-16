import { ApiError, AppRouter, RouteName } from 'common-core';
import { PatientRepository } from '../data/PatientRepository';
import { Appointment } from '../model/PatientModels';
import {
  AppButton,
  EmptyState,
  InfoBanner,
  LoadingBlock,
  PageHeader,
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

@ComponentV2
export struct AppointmentsPage {
  private readonly repository: PatientRepository = PatientRepository.getInstance();
  @Local loading: boolean = true;
  @Local errorMessage: string = '';
  @Local bannerMessage: string = '';
  @Local bannerTone: string = 'info';
  @Local appointments: Appointment[] = [];
  @Local confirmCancelId: number = 0;
  @Local cancellingId: number = 0;

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    try {
      this.appointments = await this.repository.appointments(true);
    } catch (error) {
      this.errorMessage = ApiError.from(error as Error).userMessage();
    } finally {
      this.loading = false;
    }
  }

  // 判据全部收敛到 common-core 的 VisitStatus 谓词，页面不再写状态集合（缺陷 C1/C2/C3）。
  private activeAppointments(): Appointment[] {
    const result: Appointment[] = [];
    for (const appointment of this.appointments) {
      if (VisitStatus.isActive(appointment.status)) {
        result.push(appointment);
      }
    }
    return result;
  }

  private historyAppointments(): Appointment[] {
    const result: Appointment[] = [];
    for (const appointment of this.appointments) {
      if (!VisitStatus.isActive(appointment.status)) {
        result.push(appointment);
      }
    }
    return result;
  }

  /** 状态文案：优先服务端 status_label，本地兜底表只在字段缺失时生效。 */
  private statusText(appointment: Appointment): string {
    return appointmentDisplayText(appointment.status, appointment.statusLabel);
  }

  /** 科室与医生：优先用服务端下发的名字，缺字段时才回落到 id。 */
  private placeText(appointment: Appointment): string {
    const department = appointment.departmentName.length > 0
      ? appointment.departmentName : `科室 #${appointment.departmentId}`;
    let doctor = `医生 #${appointment.doctorId}`;
    if (appointment.doctorName.length > 0) {
      doctor = appointment.doctorTitle.length > 0
        ? `${appointment.doctorName} ${appointment.doctorTitle}` : appointment.doctorName;
    }
    return `序号 ${appointment.seqNo} · ${department} · ${doctor}`;
  }

  /** 到院 / 接诊 / 完成时间线（服务端 times 口径，0 = 该步未发生）。 */
  private timelineText(appointment: Appointment): string {
    const parts: string[] = [];
    if (appointment.arrivedAt > 0) {
      parts.push(`到院 ${this.clockText(appointment.arrivedAt)}`);
    }
    if (appointment.startedAt > 0) {
      parts.push(`开始接诊 ${this.clockText(appointment.startedAt)}`);
    }
    if (appointment.finishedAt > 0) {
      parts.push(`完成 ${this.clockText(appointment.finishedAt)}`);
    }
    return parts.join(' · ');
  }

  private clockText(epoch: number): string {
    const at = new Date(epoch * 1000);
    const hh = at.getHours() < 10 ? `0${at.getHours()}` : `${at.getHours()}`;
    const mm = at.getMinutes() < 10 ? `0${at.getMinutes()}` : `${at.getMinutes()}`;
    return `${hh}:${mm}`;
  }

  private canCancel(appointment: Appointment): boolean {
    // 权威在服务端 canCancel（server/src/http_app.cj:575）；本地谓词只是它的镜像，不放宽。
    return VisitStatus.isCancellable(appointment.status);
  }

  private requestCancel(appointment: Appointment): void {
    this.confirmCancelId = appointment.appointmentId;
  }

  private dismissCancel(): void {
    this.confirmCancelId = 0;
  }

  async confirmCancel(appointment: Appointment): Promise<void> {
    if (this.cancellingId > 0) {
      return;
    }
    this.cancellingId = appointment.appointmentId;
    this.errorMessage = '';
    try {
      const result = await this.repository.cancelAppointment(appointment.appointmentId);
      if (result.status !== 'cancelled') {
        this.bannerTone = 'error';
        this.bannerMessage = '退号未完成，请稍后重试或联系前台。';
      } else if (!result.slotRestored) {
        this.bannerTone = 'warning';
        this.bannerMessage = result.warning.length > 0 ? result.warning : '号源归还异常，请联系人工处理。';
      } else {
        this.bannerTone = 'success';
        this.bannerMessage = '退号成功，号源已归还。';
      }
      this.confirmCancelId = 0;
      await this.load();
    } catch (error) {
      this.errorMessage = ApiError.from(error as Error).userMessage();
    } finally {
      this.cancellingId = 0;
    }
  }

  private openRecord(appointmentId: number): void {
    const params: Record<string, Object> = { 'appointment_id': appointmentId };
    AppRouter.getInstance().push(RouteName.RECORD_DETAIL, params);
  }

  build() {
    Column() {
      PageHeader({
        title: '我的就诊',
        subtitle: '查看预约状态、退号并进入病历'
      })

      if (this.bannerMessage.length > 0) {
        InfoBanner({ message: this.bannerMessage, tone: this.bannerTone })
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.GAP })
      }
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
            LoadingBlock({ text: '正在同步挂号单' })
          } else if (this.appointments.length === 0) {
            EmptyState({
              title: '还没有挂号记录',
              description: '完成智能分诊后即可选择号源预约'
            })
          } else {
            if (this.activeAppointments().length > 0) {
              SectionTitle({ title: '当前预约' })
              ForEach(this.activeAppointments(), (appointment: Appointment) => {
                this.appointmentCard(appointment)
              }, (appointment: Appointment) => `active-${appointment.appointmentId}`)
            }
            if (this.historyAppointments().length > 0) {
              SectionTitle({ title: '历史记录' })
                .margin({ top: AppSize.SECTION_GAP })
              ForEach(this.historyAppointments(), (appointment: Appointment) => {
                this.appointmentCard(appointment)
              }, (appointment: Appointment) => `history-${appointment.appointmentId}`)
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

  @Builder
  appointmentCard(appointment: Appointment) {
    Column() {
      Row() {
        Column() {
          Text(`${appointment.visitDate} ${periodText(appointment.period)}`)
            .fontSize(AppText.SUBHEADING)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.TEXT)
          Text(this.placeText(appointment))
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.TEXT_SECONDARY)
            .margin({ top: 5 })
          if (this.timelineText(appointment).length > 0) {
            Text(this.timelineText(appointment))
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT_SECONDARY)
              .margin({ top: 3 })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        StatusChip({
          text: this.statusText(appointment),
          color: appointmentStatusColor(appointment.status),
          chipBackground: AppColor.SURFACE_ALT
        })
      }
      .width('100%')

      if (this.canCancel(appointment)) {
        if (this.confirmCancelId === appointment.appointmentId) {
          Column() {
            Text('确认退号？退号后号源将归还，可能无法再约到同一号源。')
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT)
              .width('100%')
            Row() {
              AppButton({
                text: this.cancellingId === appointment.appointmentId ? '正在退号…' : '确认退号',
                isEnabled: this.cancellingId === 0,
                onTap: () => this.confirmCancel(appointment)
              })
                .layoutWeight(1)
              AppButton({
                text: '再想想',
                secondary: true,
                isEnabled: this.cancellingId === 0,
                onTap: () => this.dismissCancel()
              })
                .layoutWeight(1)
                .margin({ left: 10 })
            }
            .width('100%')
            .margin({ top: 10 })
          }
          .width('100%')
          .padding(12)
          .backgroundColor(AppColor.WARNING_SOFT)
          .borderRadius(AppSize.CARD_RADIUS)
          .margin({ top: 12 })
        } else {
          AppButton({
            text: '退号',
            secondary: true,
            onTap: () => this.requestCancel(appointment)
          })
            .margin({ top: 12 })
        }
      } else if (appointment.status === VisitStatus.DONE) {
        AppButton({
          text: '查看病历',
          secondary: true,
          onTap: () => this.openRecord(appointment.appointmentId)
        })
          .margin({ top: 12 })
      } else if (VisitStatus.isActive(appointment.status)) {
        // 到院 / 候诊 / 接诊中的单不可退号，但不该用一个空判断把入口藏掉 ——
        // 患者看不到「为什么不能退」（缺陷 C3）。这里把原因写出来。
        Text(VisitStatus.cancelBlockedReason(appointment.status, this.statusText(appointment)))
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.TEXT_SECONDARY)
          .width('100%')
          .margin({ top: 10 })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(AppColor.SURFACE)
    .borderRadius(AppSize.CARD_RADIUS)
    .margin({ bottom: 10 })
  }
}
