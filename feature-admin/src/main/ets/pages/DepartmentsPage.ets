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
import { Department } from '../model/AdminModels';

@ComponentV2
export struct DepartmentsPage {
  private readonly repository: AdminRepository = AdminRepository.getInstance();
  @Local departments: Department[] = [];
  @Local loading: boolean = true;
  @Local notice: string = '';
  @Local noticeTone: string = 'info';
  @Local editingId: number = 0;
  @Local name: string = '';
  @Local code: string = '';
  @Local location: string = '';

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.notice = '';
    try {
      this.departments = await this.repository.departments();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.loading = false;
    }
  }

  private edit(item: Department): void {
    this.editingId = item.id;
    this.name = item.name;
    this.code = item.code;
    this.location = item.location;
    this.notice = '';
  }

  private cancelEdit(): void {
    this.editingId = 0;
    this.name = '';
    this.code = '';
    this.location = '';
  }

  async save(): Promise<void> {
    if (this.name.trim().length === 0 || this.code.trim().length === 0) {
      this.notice = '名称与编码均必填';
      this.noticeTone = 'error';
      return;
    }
    const body: Record<string, Object> = {
      'name': this.name.trim(),
      'code': this.code.trim(),
      'location': this.location.trim(),
      'sort': 0,
      'enabled': true
    };
    this.notice = '';
    try {
      if (this.editingId === 0) {
        await this.repository.createDepartment(body);
        this.notice = '科室已新增（name/code 唯一性已校验）';
      } else {
        await this.repository.updateDepartment(this.editingId, body);
        this.notice = '科室已更新';
      }
      this.noticeTone = 'success';
      this.cancelEdit();
      await this.load();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  async remove(item: Department): Promise<void> {
    this.notice = '';
    try {
      await this.repository.deleteDepartment(item.id);
      this.notice = '科室已删除';
      this.noticeTone = 'success';
      await this.load();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  build() {
    Column() {
      Text('科室管理')
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
        SectionTitle({ title: this.editingId === 0 ? '新增科室' : `编辑科室 #${this.editingId}` })

        Row() {
          TextInput({ placeholder: '名称（唯一）', text: this.name })
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .onChange((value: string) => {
              this.name = value;
            })
          TextInput({ placeholder: '编码（唯一）', text: this.code })
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ left: AppSize.GAP })
            .onChange((value: string) => {
              this.code = value;
            })
        }
        .width('100%')

        Row() {
          TextInput({ placeholder: '位置', text: this.location })
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ top: AppSize.GAP })
            .onChange((value: string) => {
              this.location = value;
            })
          Button(this.editingId === 0 ? '新增科室' : '保存')
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .fontColor(AppColor.SURFACE)
            .backgroundColor(AppColor.PRIMARY)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ left: AppSize.GAP, top: AppSize.GAP })
            .onClick(() => this.save())
          if (this.editingId !== 0) {
            Button('取消')
              .height(AppSize.CONTROL_HEIGHT)
              .fontSize(AppText.BODY)
              .fontColor(AppColor.TEXT_SECONDARY)
              .backgroundColor(AppColor.SURFACE_ALT)
              .borderRadius(AppSize.CONTROL_RADIUS)
              .margin({ left: AppSize.GAP, top: AppSize.GAP })
              .onClick(() => this.cancelEdit())
          }
        }
        .width('100%')
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
          } else if (this.departments.length === 0) {
            EmptyState({ title: '暂无科室' })
          } else {
            ForEach(this.departments, (item: Department) => {
              Column() {
                Row() {
                  Column() {
                    Text(`#${item.id} ${item.name}`)
                      .fontSize(AppText.SUBHEADING)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(AppColor.TEXT)
                    Text(`${item.code} · ${item.location}`)
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
            }, (item: Department) => `${item.id}`)
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
