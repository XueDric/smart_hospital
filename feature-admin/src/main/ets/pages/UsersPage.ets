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
import { AdminUser } from '../model/AdminModels';

@ComponentV2
export struct UsersPage {
  private readonly repository: AdminRepository = AdminRepository.getInstance();
  @Local users: AdminUser[] = [];
  @Local loading: boolean = true;
  @Local notice: string = '';
  @Local noticeTone: string = 'info';
  @Local loginName: string = '';
  @Local password: string = '';
  @Local role: string = 'doctor';
  @Local refId: string = '';
  @Local displayName: string = '';
  @Local resetUserId: number = 0;
  @Local resetPassword: string = '';

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.notice = '';
    try {
      this.users = await this.repository.users();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    } finally {
      this.loading = false;
    }
  }

  async save(): Promise<void> {
    if (this.loginName.trim().length === 0 || this.password.length < 6 || this.role.length === 0) {
      this.notice = '登录名、密码（≥6 位）与角色均必填';
      this.noticeTone = 'error';
      return;
    }
    const body: Record<string, Object> = {
      'login_name': this.loginName.trim(),
      'password': this.password,
      'role': this.role,
      'ref_id': Number(this.refId) || 0,
      'display_name': this.displayName.trim()
    };
    this.notice = '';
    try {
      await this.repository.createUser(body);
      this.notice = '账号已创建';
      this.noticeTone = 'success';
      this.loginName = '';
      this.password = '';
      this.refId = '';
      this.displayName = '';
      await this.load();
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  async reset(item: AdminUser): Promise<void> {
    if (this.resetPassword.length < 6) {
      this.notice = '新密码至少 6 位';
      this.noticeTone = 'error';
      this.resetUserId = item.userId;
      return;
    }
    this.notice = '';
    try {
      await this.repository.resetPassword(item.userId, this.resetPassword);
      this.notice = `已重置 ${item.loginName} 的密码（吊销其全部令牌）`;
      this.noticeTone = 'success';
      this.resetUserId = 0;
      this.resetPassword = '';
    } catch (error) {
      this.notice = ApiError.from(error as Error).userMessage();
      this.noticeTone = 'error';
    }
  }

  private roleText(role: string): string {
    if (role === 'admin') {
      return '管理员';
    }
    if (role === 'doctor') {
      return '医生';
    }
    if (role === 'patient') {
      return '患者';
    }
    return role;
  }

  build() {
    Column() {
      Text('账号管理')
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
        SectionTitle({ title: '新增账号' })

        Row() {
          TextInput({ placeholder: '登录名', text: this.loginName })
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .onChange((value: string) => {
              this.loginName = value;
            })
          TextInput({ placeholder: '初始密码（≥6 位）', text: this.password })
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .type(InputType.Password)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ left: AppSize.GAP })
            .onChange((value: string) => {
              this.password = value;
            })
        }
        .width('100%')

        Row() {
          TextInput({ placeholder: '姓名/显示名', text: this.displayName })
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ top: AppSize.GAP })
            .onChange((value: string) => {
              this.displayName = value;
            })
          TextInput({ placeholder: '关联 ID', text: this.refId })
            .layoutWeight(1)
            .height(AppSize.CONTROL_HEIGHT)
            .type(InputType.Number)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .margin({ left: AppSize.GAP, top: AppSize.GAP })
            .onChange((value: string) => {
              this.refId = value;
            })
        }
        .width('100%')

        Row() {
          this.roleButton('admin', '管理员')
          this.roleButton('doctor', '医生')
          this.roleButton('patient', '患者')
          Button('新增账号')
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
          } else if (this.users.length === 0) {
            EmptyState({ title: '暂无账号' })
          } else {
            ForEach(this.users, (item: AdminUser) => {
              Column() {
                Row() {
                  Column() {
                    Text(`${item.displayName || item.loginName}`)
                      .fontSize(AppText.SUBHEADING)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(AppColor.TEXT)
                    Text(`${item.loginName} · ref_id ${item.refId}`)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.TEXT_SECONDARY)
                      .margin({ top: 4 })
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)

                  StatusChip({
                    text: this.roleText(item.role),
                    color: AppColor.PRIMARY_DARK,
                    chipBackground: AppColor.PRIMARY_SOFT
                  })
                }
                .width('100%')

                if (this.resetUserId === item.userId) {
                  Row() {
                    TextInput({ placeholder: '新密码（≥6 位）', text: this.resetPassword })
                      .layoutWeight(1)
                      .height(AppSize.CONTROL_HEIGHT)
                      .type(InputType.Password)
                      .fontSize(AppText.BODY)
                      .backgroundColor(AppColor.SURFACE_ALT)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .onChange((value: string) => {
                        this.resetPassword = value;
                      })
                    Button('确认重置')
                      .height(AppSize.CONTROL_HEIGHT)
                      .fontSize(AppText.CAPTION)
                      .fontColor(AppColor.SURFACE)
                      .backgroundColor(AppColor.DANGER)
                      .borderRadius(AppSize.CONTROL_RADIUS)
                      .margin({ left: AppSize.GAP })
                      .onClick(() => this.reset(item))
                  }
                  .width('100%')
                  .margin({ top: AppSize.GAP })
                } else {
                  Button('重置密码')
                    .height(AppSize.TOUCH_MIN)
                    .fontSize(AppText.CAPTION)
                    .fontColor(AppColor.DANGER)
                    .backgroundColor(AppColor.DANGER_SOFT)
                    .borderRadius(AppSize.CONTROL_RADIUS)
                    .margin({ top: AppSize.GAP })
                    .onClick(() => {
                      this.resetUserId = item.userId;
                      this.resetPassword = '';
                    })
                }
              }
              .width('100%')
              .padding(16)
              .backgroundColor(AppColor.SURFACE)
              .borderRadius(AppSize.CARD_RADIUS)
              .margin({ bottom: AppSize.GAP })
            }, (item: AdminUser) => `${item.userId}`)
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

  @Builder
  roleButton(value: string, label: string) {
    Button(label)
      .layoutWeight(1)
      .height(AppSize.TOUCH_MIN)
      .fontSize(AppText.CAPTION)
      .fontColor(this.role === value ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
      .backgroundColor(this.role === value ? AppColor.PRIMARY_SOFT : AppColor.SURFACE_ALT)
      .borderRadius(AppSize.CONTROL_RADIUS)
      .margin({ left: AppSize.GAP })
      .onClick(() => {
        this.role = value;
      })
  }
}
