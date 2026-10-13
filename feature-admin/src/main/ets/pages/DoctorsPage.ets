import {
  ApiError,
  AppColor,
  AppSize,
  AppText,
  EmptyState,
  InfoBanner,
  LoadingBlock,
  SectionTitle,
  StatusChip
} from 'common-core';
import { AdminRepository } from '../data/AdminRepository';
import { Department, Doctor } from '../model/AdminModels';

@ComponentV2
export struct DoctorsPage {
  private readonly repository: AdminRepository = AdminRepository.getInstance();
  @Local doctors: Doctor[] = [];
  @Local departments: Department[] = [];
  @Local loading: boolean = true;
  @Local notice: string = '';
  @Local noticeTone: string = 'info';
  @Local editingId: number = 0;
  @Local name: string = '';
  @Local departmentId: number = 0;
  @Local title: string = '';
  @Local specialty: string = '';

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.notice = '';
    try {
      this.doctors = await this.repository.doctors();
      this.departments = await this.repository.departments();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.loading = false;
    }
  }

  private edit(item: Doctor): void {
    this.editingId = item.id;
    this.name = item.name;
    this.departmentId = item.departmentId;
    this.title = item.title;
    this.specialty = item.specialty;
    this.notice = '';
  }

  private cancelEdit(): void {
    this.editingId = 0;
    this.name = '';
    this.departmentId = 0;
    this.title = '';
    this.specialty = '';
  }

  async save(): Promise<void> {
    if (this.name.trim().length === 0 || this.departmentId === 0) {
      this.notice = '姓名与科室均必填';
      this.noticeTone = 'error';
      return;
    }
    const body: Record<string, Object> = {
      'name': this.name.trim(),
      'department_id': this.departmentId,
      'title': this.title.trim(),
      'specialty': this.specialty.trim(),
      'enabled': true
    };
    this.notice = '';
    try {
      if (this.editingId === 0) {
        await this.repository.createDoctor(body);
        this.notice = '医生已新增';
      } else {
        await this.repository.updateDoctor(this.editingId, body);
        this.notice = '医生已更新';
      }
      this.noticeTone = 'success';
      this.cancelEdit();
      await this.load();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  async remove(item: Doctor): Promise<void> {
    this.notice = '';
    try {
      await this.repository.deleteDoctor(item.id);
      this.notice = '医生已删除';
      this.noticeTone = 'success';
      await this.load();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  build() {
    Column() {
      Text('医生管理')
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
        SectionTitle({ title: this.editingId === 0 ? '新增医生' : `编辑医生 #${this.editingId}` })

        Row() {
          TextInput({ placeholder: '姓名', text: this.name })
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .onChange((value: string) => {
              this.name = value;
            })
          TextInput({ placeholder: '职称', text: this.title })
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ left: AppSize.GAP })
            .onChange((value: string) => {
              this.title = value;
            })
        }
        .width('100%')

        TextInput({ placeholder: '专长', text: this.specialty })
          .width('100%')
          .height(AppSize.CONTROL_HEIGHT)
          .fontSize(AppText.BODY)
          .backgroundColor(AppColor.SURFACE_ALT)
          .borderRadius(AppSize.CONTROL_RADIUS)
          .margin({ top: AppSize.GAP })
          .onChange((value: string) => {
            this.specialty = value;
          })

        Text('科室')
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.TEXT_SECONDARY)
          .width('100%')
          .margin({ top: AppSize.GAP, bottom: 6 })

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.departments, (department: Department) => {
            Button(department.name)
              .height(36)
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
          Button(this.editingId === 0 ? '新增医生' : '保存')
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .fontColor(AppColor.SURFACE)
            .backgroundColor(AppColor.PRIMARY)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .onClick(() => this.save())
          if (this.editingId !== 0) {
            Button('取消')
              .height(AppSize.CONTROL_HEIGHT)
              .fontSize(AppText.BODY)
              .fontColor(AppColor.TEXT_SECONDARY)
              .backgroundColor(AppColor.SURFACE_ALT)
              .borderRadius(AppSize.CONTROL_RADIUS)
              .margin({ left: AppSize.GAP })
              .onClick(() => this.cancelEdit())
          }
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
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
          } else if (this.doctors.length === 0) {
            EmptyState({ title: '暂无医生' })
          } else {
            ForEach(this.doctors, (item: Doctor) => {
              Column() {
                Row() {
                  Column() {
                    Text(`#${item.id} ${item.name} · ${item.title}`)
                      .fontSize(AppText.SUBHEADING)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(AppColor.TEXT)
                    Text(`${item.departmentName} · ${item.specialty}`)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.TEXT_SECONDARY)
                      .margin({ top: 4 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  StatusChip({
                    text: item.enabled ? '启用' : '停用',
                    color: item.enabled ? AppColor.SUCCESS : AppColor.TEXT_SECONDARY,
                    chipBackground: item.enabled ? AppColor.SUCCESS_SOFT : AppColor.SURFACE_ALT
                  })
                }
                .width('100%')

                Row() {
                  Button('编辑')
                    .height(36)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.PRIMARY)
                    .backgroundColor(AppColor.PRIMARY_SOFT)
                    .borderRadius(AppSize.CONTROL_RADIUS)
                    .onClick(() => this.edit(item))
                  Button('删除')
                    .height(36)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.DANGER)
                    .backgroundColor(AppColor.DANGER_SOFT)
                    .borderRadius(AppSize.CONTROL_RADIUS)
                    .margin({ left: AppSize.GAP })
                    .onClick(() => this.remove(item))
                }
                .width('100%')
                .justifyContent(FlexAlign.End)
                .margin({ top: AppSize.GAP })
              }
              .width('100%')
              .padding(16)
              .backgroundColor(AppColor.SURFACE)
              .borderRadius(AppSize.CARD_RADIUS)
              .margin({ bottom: AppSize.GAP })
            }, (item: Doctor) => `${item.id}`)
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
