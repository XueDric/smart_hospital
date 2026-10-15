import { ApiError, AppRouter, ErrorCode, RouteName } from 'common-core';
import { PatientRepository } from '../data/PatientRepository';
import { Appointment, Schedule } from '../model/PatientModels';
import { AppButton, EmptyState, InfoBanner, LoadingBlock, PageHeader, StatusChip } from 'common-core';
import {
  AppColor,
  AppSize,
  AppText,
  nowToken,
  periodText,
  todayString
} from 'common-core';

@ComponentV2
export struct BookingPage {
  private readonly repository: PatientRepository = PatientRepository.getInstance();
  @Local departmentIdText: string = '';
  @Local doctorIdText: string = '';
  @Local workDate: string = '';
  @Local period: string = '';
  @Local departmentName: string = '';
  @Local doctorName: string = '';
  @Local loading: boolean = false;
  @Local bookingScheduleId: number = 0;
  @Local errorMessage: string = '';
  @Local successMessage: string = '';
  @Local schedules: Schedule[] = [];
  @Local bookedScheduleIds: number[] = [];
  @Local bookingToken: string = '';
  @Local tokenScheduleId: number = 0;

  aboutToAppear(): void {
    const departmentId = Number(AppRouter.getInstance().getParam('department_id') ?? 0);
    const doctorId = Number(AppRouter.getInstance().getParam('doctor_id') ?? 0);
    const scheduleId = Number(AppRouter.getInstance().getParam('schedule_id') ?? 0);
    const routeDate = String(AppRouter.getInstance().getParam('work_date') ?? '');
    const routePeriod = String(AppRouter.getInstance().getParam('period') ?? '');
    this.departmentIdText = departmentId > 0 ? `${departmentId}` : '';
    this.doctorIdText = doctorId > 0 ? `${doctorId}` : '';
    this.workDate = routeDate.length > 0 ? routeDate : todayString();
    this.period = routePeriod;
    this.departmentName = String(AppRouter.getInstance().getParam('department_name') ?? '');
    this.doctorName = String(AppRouter.getInstance().getParam('doctor_name') ?? '');
    this.prepareToken(scheduleId);
    this.loadSchedules();
    this.loadBookedSchedules();
  }

  async loadSchedules(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    this.successMessage = '';
    try {
      const departmentId = this.parsePositiveInt(this.departmentIdText);
      const all = await this.repository.schedules(departmentId, this.workDate.trim());
      const filtered: Schedule[] = [];
      const today = todayString();
      const doctorId = this.parsePositiveInt(this.doctorIdText);
      for (const schedule of all) {
        if (schedule.workDate < today) {
          continue;
        }
        if (doctorId > 0 && schedule.doctorId !== doctorId) {
          continue;
        }
        if (this.period.length > 0 && schedule.period !== this.period) {
          continue;
        }
        filtered.push(schedule);
      }
      this.schedules = filtered;
    } catch (error) {
      this.errorMessage = ApiError.from(error as Error).userMessage();
    } finally {
      this.loading = false;
    }
  }

  async loadBookedSchedules(): Promise<void> {
    try {
      const appointments = await this.repository.appointments(false);
      const ids: number[] = [];
      for (const appointment of appointments) {
        if (appointment.status === 'booked' || appointment.status === 'visiting') {
          ids.push(appointment.scheduleId);
        }
      }
      this.bookedScheduleIds = ids;
    } catch (error) {
      // The schedule list remains usable even if the appointment badge cannot be loaded.
    }
  }

  async book(schedule: Schedule): Promise<void> {
    if (this.bookingScheduleId > 0 || schedule.remainNum <= 0) {
      return;
    }
    if (this.tokenScheduleId !== schedule.id || this.bookingToken.length === 0) {
      this.bookingToken = nowToken('booking');
      this.tokenScheduleId = schedule.id;
    }
    this.bookingScheduleId = schedule.id;
    this.errorMessage = '';
    this.successMessage = '';
    try {
      const appointment: Appointment = await this.repository.book(schedule.id, this.bookingToken);
      this.successMessage =
        `挂号成功：${appointment.visitDate} ${periodText(appointment.period)}，序号 ${appointment.seqNo}`;
      const ids = this.bookedScheduleIds.slice();
      if (ids.indexOf(schedule.id) < 0) {
        ids.push(schedule.id);
      }
      this.bookedScheduleIds = ids;
      this.bookingToken = '';
      this.tokenScheduleId = 0;
    } catch (error) {
      const apiError = ApiError.from(error as Error);
      if (apiError.code === ErrorCode.SLOT_GONE) {
        this.bookingToken = '';
        this.tokenScheduleId = 0;
        this.errorMessage = '号源刚被约满，列表已刷新，请重新选择。';
        await this.loadSchedules();
      } else {
        this.errorMessage = apiError.userMessage();
      }
    } finally {
      this.bookingScheduleId = 0;
    }
  }

  private prepareToken(scheduleId: number): void {
    if (scheduleId > 0) {
      this.bookingToken = nowToken('booking');
      this.tokenScheduleId = scheduleId;
    }
  }

  private parsePositiveInt(value: string): number {
    const parsed = Number.parseInt(value.trim(), 10);
    return Number.isNaN(parsed) || parsed <= 0 ? 0 : parsed;
  }

  private isBooked(scheduleId: number): boolean {
    return this.bookedScheduleIds.indexOf(scheduleId) >= 0;
  }

  private setPeriod(value: string): void {
    this.period = value;
    this.loadSchedules();
  }

  build() {
    Column() {
      PageHeader({
        title: '预约挂号',
        subtitle: this.departmentName.length > 0 ? this.departmentName : '按科室、医生和日期筛选号源'
      })

      Column() {
        Row() {
          Column() {
            Text('科室编号')
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT_SECONDARY)
              .width('100%')
            TextInput({ placeholder: '全部科室', text: this.departmentIdText })
              .height(AppSize.TOUCH_MIN)
              .fontSize(AppText.BODY)
              .backgroundColor(AppColor.SURFACE)
              .borderRadius(AppSize.CONTROL_RADIUS)
              .type(InputType.Number)
              .margin({ top: 5 })
              .onChange((value: string) => {
                this.departmentIdText = value;
              })
          }
          .layoutWeight(1)
          Column() {
            Text('医生编号')
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT_SECONDARY)
              .width('100%')
            TextInput({ placeholder: '全部医生', text: this.doctorIdText })
              .height(AppSize.TOUCH_MIN)
              .fontSize(AppText.BODY)
              .backgroundColor(AppColor.SURFACE)
              .borderRadius(AppSize.CONTROL_RADIUS)
              .type(InputType.Number)
              .margin({ top: 5 })
              .onChange((value: string) => {
                this.doctorIdText = value;
              })
          }
          .layoutWeight(1)
          .margin({ left: 10 })
        }
        .width('100%')

        Row() {
          Column() {
            Text('就诊日期')
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT_SECONDARY)
              .width('100%')
            TextInput({ placeholder: 'YYYY-MM-DD', text: this.workDate })
              .height(AppSize.TOUCH_MIN)
              .fontSize(AppText.BODY)
              .backgroundColor(AppColor.SURFACE)
              .borderRadius(AppSize.CONTROL_RADIUS)
              .margin({ top: 5 })
              .onChange((value: string) => {
                this.workDate = value;
              })
          }
          .layoutWeight(1)
          Button('查询号源')
            .height(AppSize.TOUCH_MIN)
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.SURFACE)
            .backgroundColor(AppColor.PRIMARY)
            .margin({ left: 10, top: 18 })
            .onClick(() => this.loadSchedules())
        }
        .width('100%')
        .margin({ top: 10 })

        Row() {
          Button('全部')
            .layoutWeight(1)
            .height(AppSize.TOUCH_MIN)
            .fontSize(AppText.CAPTION)
            .fontColor(this.period.length === 0 ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
            .backgroundColor(this.period.length === 0 ? AppColor.PRIMARY_SOFT : Color.Transparent)
            .onClick(() => this.setPeriod(''))
          Button('上午')
            .layoutWeight(1)
            .height(AppSize.TOUCH_MIN)
            .fontSize(AppText.CAPTION)
            .fontColor(this.period === 'AM' ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
            .backgroundColor(this.period === 'AM' ? AppColor.PRIMARY_SOFT : Color.Transparent)
            .onClick(() => this.setPeriod('AM'))
          Button('下午')
            .layoutWeight(1)
            .height(AppSize.TOUCH_MIN)
            .fontSize(AppText.CAPTION)
            .fontColor(this.period === 'PM' ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
            .backgroundColor(this.period === 'PM' ? AppColor.PRIMARY_SOFT : Color.Transparent)
            .onClick(() => this.setPeriod('PM'))
        }
        .width('100%')
        .padding(3)
        .backgroundColor(AppColor.SURFACE)
        .borderRadius(AppSize.CONTROL_RADIUS)
        .margin({ top: 10 })
      }
      .width('100%')
      .padding(AppSize.PAGE_PADDING)
      .backgroundColor(AppColor.SURFACE_ALT)

      if (this.errorMessage.length > 0) {
        InfoBanner({
          message: this.errorMessage,
          tone: 'error',
          actionText: '重试',
          onAction: () => this.loadSchedules()
        })
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, top: AppSize.GAP })
      }
      if (this.successMessage.length > 0) {
        InfoBanner({
          message: this.successMessage,
          tone: 'success',
          actionText: '查看就诊',
          onAction: () => AppRouter.getInstance().reset(RouteName.APPOINTMENTS)
        })
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, top: AppSize.GAP })
      }

      Scroll() {
        Column() {
          if (this.loading) {
            LoadingBlock({ text: '正在查询号源' })
          } else if (this.schedules.length === 0) {
            EmptyState({
              title: '没有匹配的号源',
              description: '请调整科室、医生、日期或时段后重新查询'
            })
          } else {
            ForEach(this.schedules, (schedule: Schedule) => {
              Column() {
                Row() {
                  Column() {
                    Text(this.departmentName.length > 0 ?
                      this.departmentName : `科室 #${schedule.departmentId}`)
                      .fontSize(AppText.SUBHEADING)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(AppColor.TEXT)
                    Text(this.doctorName.length > 0 && schedule.doctorId === this.parsePositiveInt(this.doctorIdText) ?
                      this.doctorName : `医生 #${schedule.doctorId}`)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.TEXT_SECONDARY)
                      .margin({ top: 5 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  StatusChip({
                    text: schedule.remainNum > 0 ? `余 ${schedule.remainNum}` : '已约满',
                    color: schedule.remainNum > 0 ? AppColor.SUCCESS : AppColor.DANGER,
                    chipBackground: schedule.remainNum > 0 ? AppColor.SUCCESS_SOFT : AppColor.DANGER_SOFT
                  })
                }
                .width('100%')

                Row() {
                  Text(`${schedule.workDate} ${periodText(schedule.period)}`)
                    .fontSize(AppText.BODY)
                    .fontColor(AppColor.TEXT)
                    .layoutWeight(1)
                  Text(`总号 ${schedule.totalNum}`)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.TEXT_SECONDARY)
                }
                .width('100%')
                .margin({ top: 12 })

                AppButton({
                  text: this.isBooked(schedule.id) ? '已预约该号源' :
                    (this.bookingScheduleId === schedule.id ? '正在锁定号源…' :
                      (schedule.remainNum > 0 ? '确认挂号' : '暂无可挂号源')),
                  isEnabled: schedule.remainNum > 0 && !this.isBooked(schedule.id) &&
                    this.bookingScheduleId === 0,
                  onTap: () => this.book(schedule)
                })
                  .margin({ top: 12 })
              }
              .width('100%')
              .padding(14)
              .backgroundColor(AppColor.SURFACE)
              .borderRadius(AppSize.CARD_RADIUS)
              .margin({ bottom: 10 })
            }, (schedule: Schedule) => `${schedule.id}`)
          }
        }
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, top: AppSize.GAP, bottom: 24 })
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.BACKGROUND)
  }
}
