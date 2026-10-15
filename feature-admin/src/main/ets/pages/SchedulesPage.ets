import {
  ApiError,
  AppColor,
  AppSize,
  AppText,
  EmptyState,
  InfoBanner,
  LoadingBlock,
  SectionTitle,
  StatusChip,
  periodText
} from 'common-core';
import { AdminRepository } from '../data/AdminRepository';
import { Department, Doctor, Schedule } from '../model/AdminModels';

@ComponentV2
export struct SchedulesPage {
  private readonly repository: AdminRepository = AdminRepository.getInstance();
  @Local schedules: Schedule[] = [];
  @Local doctors: Doctor[] = [];
  @Local departments: Department[] = [];
  @Local loading: boolean = true;
  @Local notice: string = '';
  @Local noticeTone: string = 'info';
  @Local doctorId: number = 0;
  @Local departmentId: number = 0;
  @Local workDate: string = '';
  @Local period: string = 'AM';
  @Local totalNum: string = '';

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.notice = '';
    try {
      this.schedules = await this.repository.schedules();
      this.doctors = await this.repository.doctors();
      this.departments = await this.repository.departments();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.loading = false;
    }
  }

  async save(): Promise<void> {
    const total = Number(this.totalNum);
    if (this.doctorId === 0 || this.departmentId === 0 || this.workDate.trim().length === 0 ||
      Number.isNaN(total) || total <= 0) {
      this.notice = '医生、科室、日期与号数均必填';
      this.noticeTone = 'error';
      return;
    }
    const body: Record<string, Object> = {
      'doctor_id': this.doctorId,
      'department_id': this.departmentId,
      'work_date': this.workDate.trim(),
      'period': this.period,
      'total_num': total
    };
    this.notice = '';
    try {
      const created = await this.repository.createSchedule(body);
      this.notice = `号源已创建（剩余 ${created.remainNum}/${created.totalNum}）`;
      this.noticeTone = 'success';
      this.doctorId = 0;
      this.departmentId = 0;
      this.workDate = '';
      this.totalNum = '';
      await this.load();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  build() {
    Column() {
      Text('排班 / 号源')
        .fontSize(AppText.HEADING)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.TEXT)
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, top: 20, bottom: 12 })

      if (this.notice.length > 0) {
        InfoBanner({ message: this.notice, tone: this.noticeTone })
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, bottom: AppSize.GAP })
      }

      Column() {
        SectionTitle({ title: '新增号源' })

        Text('医生')
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.TEXT_SECONDARY)
          .width('100%')
          .margin({ bottom: 6 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.doctors, (doctor: Doctor) => {
            Button(`${doctor.name} · ${doctor.title}`)
              .height(AppSize.TOUCH_MIN)
              .fontSize(AppText.CAPTION)
              .fontColor(this.doctorId === doctor.id ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
              .backgroundColor(this.doctorId === doctor.id ? AppColor.PRIMARY_SOFT : AppColor.SURFACE_ALT)
              .borderRadius(AppSize.CONTROL_RADIUS)
              .margin({ right: AppSize.GAP, bottom: AppSize.GAP })
              .onClick(() => {
                this.doctorId = doctor.id;
              })
          }, (doctor: Doctor) => `${doctor.id}`)
        }
        .width('100%')

        Text('科室')
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.TEXT_SECONDARY)
          .width('100%')
          .margin({ top: AppSize.GAP, bottom: 6 })
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.departments, (department: Department) => {
            Button(department.name)
              .height(AppSize.TOUCH_MIN)
              .fontSize(AppText.CAPTION)
              .fontColor(this.departmentId === department.id ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
              .backgroundColor(this.departmentId === department.id ? AppColor.PRIMARY_SOFT : AppColor.SURFACE_ALT)
              .borderRadius(AppSize.CONTROL_RADIUS)
              .margin({ right: AppSize.GAP, bottom: AppSize.GAP })
              .onClick(() => {
                this.departmentId = department.id;
              })
          }, (department: Department) => `${department.id}`)
        }
        .width('100%')

        Row() {
          TextInput({ placeholder: '日期（YYYY-MM-DD）', text: this.workDate })
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .onChange((value: string) => {
              this.workDate = value;
            })
          TextInput({ placeholder: '号数', text: this.totalNum })
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .type(InputType.Number)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ left: AppSize.GAP })
            .onChange((value: string) => {
              this.totalNum = value;
            })
        }
        .width('100%')
        .margin({ top: AppSize.GAP })

        Row() {
          Button('上午')
            .layoutWeight(1)
            .height(AppSize.TOUCH_MIN)
            .fontSize(AppText.CAPTION)
            .fontColor(this.period === 'AM' ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
            .backgroundColor(this.period === 'AM' ? AppColor.PRIMARY_SOFT : AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .onClick(() => {
              this.period = 'AM';
            })
          Button('下午')
            .layoutWeight(1)
            .height(AppSize.TOUCH_MIN)
            .fontSize(AppText.CAPTION)
            .fontColor(this.period === 'PM' ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
            .backgroundColor(this.period === 'PM' ? AppColor.PRIMARY_SOFT : AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ left: AppSize.GAP })
            .onClick(() => {
              this.period = 'PM';
            })
          Button('新增号源')
            .layoutWeight(1)
            .height(AppSize.TOUCH_MIN)
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.SURFACE)
            .backgroundColor(AppColor.PRIMARY)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ left: AppSize.GAP })
            .onClick(() => this.save())
        }
        .width('100%')
        .margin({ top: AppSize.GAP })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(AppColor.SURFACE)
      .borderRadius(AppSize.CARD_RADIUS)
      .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })

      Scroll() {
        Column() {
          if (this.loading) {
            LoadingBlock()
          } else if (this.schedules.length === 0) {
            EmptyState({ title: '暂无号源' })
          } else {
            ForEach(this.schedules, (item: Schedule) => {
              Column() {
                Row() {
                  Column() {
                    Text(`${item.doctorName} · ${item.doctorTitle}`)
                      .fontSize(AppText.SUBHEADING)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(AppColor.TEXT)
                    Text(`${item.departmentName} · ${item.workDate} ${periodText(item.period)}`)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.TEXT_SECONDARY)
                      .margin({ top: 4 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  StatusChip({
                    text: `剩 ${item.remainNum}/${item.totalNum}`,
                    color: item.remainNum > 0 ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY,
                    chipBackground: item.remainNum > 0 ? AppColor.PRIMARY_SOFT : AppColor.SURFACE_ALT
                  })
                }
                .width('100%')
              }
              .width('100%')
              .padding(16)
              .backgroundColor(AppColor.SURFACE)
              .borderRadius(AppSize.CARD_RADIUS)
              .margin({ bottom: AppSize.GAP })
            }, (item: Schedule) => `${item.id}`)
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
  }
}
