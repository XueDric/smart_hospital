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
} from '../ui/CommonComponents';
import {
  AppColor,
  AppSize,
  AppText,
  appointmentStatusColor,
  appointmentStatusText,
  periodText
} from '../ui/Theme';

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

  private activeAppointments(): Appointment[] {
    const result: Appointment[] = [];
    for (const appointment of this.appointments) {
      if (appointment.status === 'booked' || appointment.status === 'visiting') {
        result.push(appointment);
      }
    }
    return result;
  }

  private historyAppointments(): Appointment[] {
    const result: Appointment[] = [];
    for (const appointment of this.appointments) {
      if (appointment.status !== 'booked' && appointment.status !== 'visiting') {
        result.push(appointment);
      }
    }
    return result;
  }

  private canCancel(appointment: Appointment): boolean {
    // 服务端没有 can_cancel 字段，仅按状态粗略判断，403/404 由错误分支兜底。
    return appointment.status === 'booked';
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
          Text(`序号 ${appointment.seqNo} · 科室 #${appointment.departmentId} · 医生 #${appointment.doctorId}`)
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.TEXT_SECONDARY)
            .margin({ top: 5 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        StatusChip({
          text: appointmentStatusText(appointment.status),
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
      } else if (appointment.status === 'done') {
        AppButton({
          text: '查看病历',
          secondary: true,
          onTap: () => this.openRecord(appointment.appointmentId)
        })
          .margin({ top: 12 })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(AppColor.SURFACE)
    .borderRadius(AppSize.CARD_RADIUS)
    .margin({ bottom: 10 })
  }
}
