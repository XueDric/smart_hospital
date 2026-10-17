import {
  ApiConfig,
  ApiError,
  ApiMode,
  AppRouter,
  RouteName,
  SessionStore,
  ThemeManager,
  ThemeMode
} from 'common-core';
import { PatientRepository } from '../data/PatientRepository';
import { CurrentUser } from '../model/PatientModels';
import {
  AppButton,
  FieldLabel,
  InfoBanner,
  PageHeader,
  SectionTitle
} from 'common-core';
import { AppColor, AppSize, AppText, formatEpoch } from 'common-core';

@ComponentV2
export struct ProfilePage {
  private readonly repository: PatientRepository = PatientRepository.getInstance();
  @Local displayName: string = '';
  @Local role: string = '';
  @Local patientId: number = 0;
  @Local userId: number = 0;
  @Local expiresAt: number = 0;
  @Local mockMode: boolean = false;
  @Local baseUrl: string = '';
  @Local themeMode: ThemeMode = ThemeMode.AUTO;
  @Local loading: boolean = false;
  @Local errorMessage: string = '';
  @Local bannerMessage: string = '';
  @Local bannerTone: string = 'info';

  aboutToAppear(): void {
    this.displayName = SessionStore.getDisplayName();
    this.role = SessionStore.getRole();
    this.patientId = SessionStore.getPatientId();
    this.userId = SessionStore.getUserId();
    this.expiresAt = SessionStore.getExpiresAt();
    this.mockMode = ApiConfig.isMock();
    this.themeMode = ThemeManager.getInstance().getMode();
    this.baseUrl = ApiConfig.baseUrl;
  }

  async refreshIdentity(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    this.errorMessage = '';
    try {
      const user: CurrentUser = await this.repository.me();
      this.role = user.role;
      this.patientId = user.patientId;
      this.userId = user.userId;
      // ★ 2026-10-17：姓名也一起刷 —— 否则"同步身份信息"只同步一半，改名后界面还是旧名字。
      if (user.displayName.length > 0 && user.displayName !== this.displayName) {
        this.displayName = user.displayName;
        SessionStore.setDisplayName(user.displayName);
      }
      this.bannerTone = 'success';
      this.bannerMessage = '身份信息已同步';
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
    this.bannerTone = 'info';
    this.bannerMessage = mock ? '已切换到演示数据模式' : '已切换到在线服务模式';
  }

  private setTheme(mode: ThemeMode): void {
    this.themeMode = mode;
    ThemeManager.getInstance().setMode(mode);
  }

  private saveBaseUrl(): void {
    ApiConfig.baseUrl = this.baseUrl;
    this.baseUrl = ApiConfig.baseUrl;
    SessionStore.setApiConfig(ApiConfig.mode, this.baseUrl);
    this.bannerTone = 'success';
    this.bannerMessage = '服务地址已保存';
  }

  async logout(): Promise<void> {
    if (this.loading) {
      return;
    }
    this.loading = true;
    SessionStore.setPrevisitSessionId('');
    try {
      await this.repository.logout();
    } catch (error) {
      // 登出失败也需要清掉本地登录态，避免用户被卡在已登录页面。
    }
    await SessionStore.clearLogin();
    this.loading = false;
    AppRouter.getInstance().reset(RouteName.LOGIN);
  }

  build() {
    Column() {
      PageHeader({
        title: '我的',
        subtitle: '账号、服务地址与登录状态'
      })

      Scroll() {
        Column() {
          Column() {
            Text(this.displayName.length > 0 ? this.displayName : '患者')
              .fontSize(AppText.TITLE)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.TEXT)
              .width('100%')
            Text(`角色 ${this.role.length > 0 ? this.role : '未知'} · 患者档案 #${this.patientId}`)
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT_SECONDARY)
              .width('100%')
              .margin({ top: 6 })
            Text(`用户 #${this.userId} · 登录有效至 ${formatEpoch(this.expiresAt)}`)
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT_SECONDARY)
              .width('100%')
              .margin({ top: 4 })
            AppButton({
              text: this.loading ? '正在同步…' : '同步身份信息',
              secondary: true,
              isEnabled: !this.loading,
              onTap: () => this.refreshIdentity()
            })
              .margin({ top: AppSize.GAP })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(AppColor.SURFACE)
          .borderRadius(AppSize.CARD_RADIUS)
          .alignItems(HorizontalAlign.Start)

          if (this.bannerMessage.length > 0) {
            InfoBanner({ message: this.bannerMessage, tone: this.bannerTone })
              .margin({ top: AppSize.GAP })
          }
          if (this.errorMessage.length > 0) {
            InfoBanner({ message: this.errorMessage, tone: 'error' })
              .margin({ top: AppSize.GAP })
          }

          Column() {
            SectionTitle({ title: '外观' })
            Row() {
              Button('跟随系统')
                .layoutWeight(1)
                .height(AppSize.TOUCH_MIN)
                .fontSize(AppText.CAPTION)
                .fontColor(this.themeMode === ThemeMode.AUTO ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
                .backgroundColor(this.themeMode === ThemeMode.AUTO ? AppColor.PRIMARY_SOFT : Color.Transparent)
                .onClick(() => this.setTheme(ThemeMode.AUTO))
              Button('浅色')
                .layoutWeight(1)
                .height(AppSize.TOUCH_MIN)
                .fontSize(AppText.CAPTION)
                .fontColor(this.themeMode === ThemeMode.LIGHT ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
                .backgroundColor(this.themeMode === ThemeMode.LIGHT ? AppColor.PRIMARY_SOFT : Color.Transparent)
                .onClick(() => this.setTheme(ThemeMode.LIGHT))
              Button('深色')
                .layoutWeight(1)
                .height(AppSize.TOUCH_MIN)
                .fontSize(AppText.CAPTION)
                .fontColor(this.themeMode === ThemeMode.DARK ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
                .backgroundColor(this.themeMode === ThemeMode.DARK ? AppColor.PRIMARY_SOFT : Color.Transparent)
                .onClick(() => this.setTheme(ThemeMode.DARK))
            }
            .width('100%')
            .padding(3)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)

            Text('跟随系统时自动匹配浅色或深色；手动选择后重启仍保持。')
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.TEXT_SECONDARY)
              .width('100%')
              .margin({ top: 10 })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(AppColor.SURFACE)
          .borderRadius(AppSize.CARD_RADIUS)
          .margin({ top: AppSize.SECTION_GAP })
          .alignItems(HorizontalAlign.Start)

          Column() {
            SectionTitle({ title: '数据来源' })
            Row() {
              Button('在线服务')
                .layoutWeight(1)
                .height(AppSize.TOUCH_MIN)
                .fontSize(AppText.CAPTION)
                .fontColor(this.mockMode ? AppColor.TEXT_SECONDARY : AppColor.PRIMARY_DARK)
                .backgroundColor(this.mockMode ? Color.Transparent : AppColor.PRIMARY_SOFT)
                .onClick(() => this.changeMode(false))
              Button('演示数据')
                .layoutWeight(1)
                .height(AppSize.TOUCH_MIN)
                .fontSize(AppText.CAPTION)
                .fontColor(this.mockMode ? AppColor.PRIMARY_DARK : AppColor.TEXT_SECONDARY)
                .backgroundColor(this.mockMode ? AppColor.PRIMARY_SOFT : Color.Transparent)
                .onClick(() => this.changeMode(true))
            }
            .width('100%')
            .padding(3)
            .backgroundColor(AppColor.SURFACE_ALT)
            .borderRadius(AppSize.CONTROL_RADIUS)

            FieldLabel({ label: '服务地址（Base URL）' })
              .margin({ top: AppSize.GAP })
            TextInput({ placeholder: 'http://127.0.0.1:8091', text: this.baseUrl })
              .height(AppSize.CONTROL_HEIGHT)
              .fontSize(AppText.BODY)
              .backgroundColor(AppColor.SURFACE_ALT)
              .borderRadius(AppSize.CONTROL_RADIUS)
              .onChange((value: string) => {
                this.baseUrl = value;
              })
            AppButton({
              text: '保存服务地址',
              secondary: true,
              onTap: () => this.saveBaseUrl()
            })
              .margin({ top: 10 })
            Text('正式环境请使用 HTTPS，明文 HTTP 仅用于本机联调。')
              .fontSize(AppText.CAPTION)
              .fontColor(AppColor.WARNING)
              .width('100%')
              .margin({ top: 10 })
          }
          .width('100%')
          .padding(16)
          .backgroundColor(AppColor.SURFACE)
          .borderRadius(AppSize.CARD_RADIUS)
          .margin({ top: AppSize.SECTION_GAP })
          .alignItems(HorizontalAlign.Start)

          AppButton({
            text: this.loading ? '正在退出…' : '退出登录',
            isEnabled: !this.loading,
            onTap: () => this.logout()
          })
            .margin({ top: AppSize.SECTION_GAP, bottom: 24 })
        }
        .width('100%')
        .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING, top: AppSize.GAP })
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.BACKGROUND)
  }
}
