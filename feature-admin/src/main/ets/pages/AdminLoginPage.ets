import {
  ApiConfig,
  ApiError,
  ApiMode,
  AppRouter,
  ErrorCode,
  RouteName,
  SessionStore
} from 'common-core';
import { AdminRepository } from '../data/AdminRepository';
import { AdminLoginResult } from '../model/AdminModels';
import { AppButton, FieldLabel } from 'common-core';
import { AppColor, AppSize, AppText } from 'common-core';

@ComponentV2
export struct AdminLoginPage {
  private readonly repository: AdminRepository = AdminRepository.getInstance();
  @Local loginName: string = '';
  @Local password: string = '';
  @Local loading: boolean = false;
  @Local errorMessage: string = '';
  @Local mockMode: boolean = false;

  aboutToAppear(): void {
    this.mockMode = ApiConfig.isMock();
    const expiresAt = SessionStore.getExpiresAt();
    const now = Math.floor(Date.now() / 1000);
    if (SessionStore.hasToken() && SessionStore.getRole() === 'admin' &&
      (expiresAt === 0 || expiresAt > now)) {
      AppRouter.getInstance().reset(RouteName.ADMIN_DASHBOARD);
    }
  }

  async submit(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.errorMessage = '';
    if (this.loginName.trim().length === 0 || this.password.length === 0) {
      this.errorMessage = '请输入账号和密码';
      return;
    }
    this.loading = true;
    try {
      const result: AdminLoginResult = await this.repository.login(this.loginName.trim(), this.password);
      if (result.role !== 'admin') {
        throw new ApiError(ErrorCode.FORBIDDEN_ROLE, '当前账号不是管理员账号', 403);
      }
      SessionStore.saveLogin(result.token, result.expiresAt, result.userId, result.role,
        result.refId, 0, result.displayName);
      AppRouter.getInstance().reset(RouteName.ADMIN_DASHBOARD);
    } catch (error) {
      this.errorMessage = ApiError.from(error as Error).userMessage();
    } finally {
      this.loading = false;
    }
  }

  private changeMode(mock: boolean): void {
    this.mockMode = mock;
    const mode = mock ? ApiMode.MOCK : ApiMode.LIVE;
    ApiConfig.mode = mode;
    SessionStore.setApiConfig(mode, ApiConfig.baseUrl);
    this.errorMessage = '';
  }

  build() {
    Stack() {
      Column() {
        Column() {
          Text('智慧医院')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.TEXT)
          Text('管理端')
            .fontSize(AppText.BODY)
            .fontColor(AppColor.PRIMARY_DARK)
            .margin({ top: 6 })
          Text('运营看板 · 基础数据 · AI 能力中心')
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.TEXT_SECONDARY)
            .margin({ top: 12 })
        }
        .width('100%')
        .padding({ top: 64, bottom: 28 })
        .alignItems(HorizontalAlign.Center)

        Column() {
          Row() {
            Button('在线服务')
              .layoutWeight(1)
              .height(40)
              .fontSize(AppText.CAPTION)
              .fontColor(this.mockMode ? AppColor.TEXT_SECONDARY : AppColor.PRIMARY_DARK)
              .backgroundColor(this.mockMode ? Color.Transparent : AppColor.PRIMARY_SOFT)
              .onClick(() => this.changeMode(false))
            Button('演示数据')
              .layoutWeight(1)
              .height(40)
              .fontSize(AppText.CAPTION)
              .fontColor(this.mockMode ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
              .backgroundColor(this.mockMode ? AppColor.PRIMARY_SOFT : Color.Transparent)
              .onClick(() => this.changeMode(true))
          }
          .width('100%')
          .padding(3)
          .backgroundColor(AppColor.SURFACE_ALT)
          .borderRadius(AppSize.CONTROL_RADIUS)

          FieldLabel({ label: '管理员账号', required: true })
            .margin({ top: AppSize.SECTION_GAP })
          TextInput({ placeholder: '请输入管理员账号', text: this.loginName })
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .onChange((value: string) => {
              this.loginName = value;
            })

          FieldLabel({ label: '密码', required: true })
            .margin({ top: AppSize.GAP })
          TextInput({ placeholder: '请输入密码', text: this.password })
            .type(InputType.Password)
            .height(AppSize.CONTROL_HEIGHT)
            .fontSize(AppText.BODY)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)
            .onChange((value: string) => {
              this.password = value;
            })

          if (this.errorMessage.length > 0) {
            Text(this.errorMessage)
              .width('100%')
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.DANGER)
              .backgroundColor(AppColor.DANGER_SOFT)
              .padding(10)
              .borderRadius(AppSize.CARD_RADIUS)
              .margin({ top: AppSize.GAP })
          }

          AppButton({
            text: this.loading ? '正在登录…' : '登录',
            isEnabled: !this.loading,
            onTap: () => this.submit()
          })
            .margin({ top: AppSize.SECTION_GAP })

          if (this.mockMode) {
            Text('演示模式可使用任意非空账号和密码')
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT_SECONDARY)
              .margin({ top: 10 })
          }
        }
        .width('100%')
        .padding(20)
        .backgroundColor(AppColor.SURFACE)
        .borderRadius(AppSize.CARD_RADIUS)
      }
      .width(360)
      .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.BACKGROUND)
  }
}
