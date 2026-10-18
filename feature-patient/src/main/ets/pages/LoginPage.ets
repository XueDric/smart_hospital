import { ApiConfig, ApiError, ApiMode, AppRouter, ErrorCode, RouteName, SessionStore } from 'common-core';
import { PatientRepository } from '../data/PatientRepository';
import { LoginResult } from '../model/PatientModels';
import { AppButton, FieldLabel } from 'common-core';
import { AppColor, AppSize, AppText } from 'common-core';

@ComponentV2
export struct LoginPage {
  private readonly repository: PatientRepository = PatientRepository.getInstance();
  @Local loginName: string = '';
  @Local password: string = '';
  @Local loading: boolean = false;
  @Local errorMessage: string = '';
  @Local mockMode: boolean = false;

  aboutToAppear(): void {
    this.mockMode = ApiConfig.isMock();
    // ★ 2026-10-17 复查：过期判据统一收到 SessionStore.hasValidToken()，别在页面里各写一遍。
    if (SessionStore.hasValidToken() && SessionStore.getRole() === 'patient') {
      AppRouter.getInstance().reset(RouteName.HOME);
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
      const result: LoginResult = await this.repository.login(this.loginName.trim(), this.password);
      if (result.role !== 'patient') {
        throw new ApiError(ErrorCode.FORBIDDEN_ROLE, '当前账号不是患者账号', 403);
      }
      // ★ 2026-10-17（评审 P2-14）：令牌写进系统安全存储是异步的，**必须先 await 再跳转** ——
      // 否则用户登录后立刻退出应用，令牌可能还没落地（下次打开又要重登）。
      await SessionStore.saveLogin(result.token, result.expiresAt, result.userId, result.role,
        result.refId, result.patientId, result.displayName);
      AppRouter.getInstance().reset(RouteName.HOME);
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
    Scroll() {
      Column() {
        Column() {
          Text('智慧医院')
            .fontSize(AppText.DISPLAY)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.TEXT)
          Text('患者端')
            .fontSize(AppText.BODY)
            .fontColor(AppColor.PRIMARY_DARK)
            .margin({ top: 6 })
          Text('智能分诊 · 预问诊 · 预约挂号 · 医疗档案')
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.TEXT_SECONDARY)
            .margin({ top: 12 })
        }
        .width('100%')
        .padding({ top: 72, bottom: 32 })
        .alignItems(HorizontalAlign.Center)

        Column() {
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

          FieldLabel({ label: '登录账号', required: true })
            .margin({ top: AppSize.SECTION_GAP })
          TextInput({ placeholder: '请输入患者账号', text: this.loginName })
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

        Text('如出现胸痛、呼吸困难、意识障碍等危急情况，请立即前往急诊或拨打 120。')
          .fontSize(AppText.CAPTION)
          .fontColor(AppColor.WARNING)
          .backgroundColor(AppColor.WARNING_SOFT)
          .padding(12)
          .borderRadius(AppSize.CARD_RADIUS)
          .margin({ top: AppSize.SECTION_GAP })

        /*
         * ★ 2026-10-17（评审实测缺陷）：三个端的注册函数原先用 `replace` 抢首屏，
         * 结果首屏固定成管理端、患者登录页不可达。修好注册之后，跨端入口要显式给出来，
         * 否则医生端/管理端又变成"打包了但点不到"。
         */
        Row() {
          /*
           * ★ 2026-10-17 复查：原来只有纯文字，点击热区就是几个字的高度（< 40vp），
           * 手小的用户/单手操作很容易点不到 —— 与本行"让三端入口可达"的目的相悖。
           * 现在每段都撑到 44vp 高、左右各留 8vp 内边距。
           */
          Text('医生登录')
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.PRIMARY_DARK)
            .height(44)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              AppRouter.getInstance().replace(RouteName.DOCTOR_LOGIN);
            })
          Text('·')
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.TEXT_SECONDARY)
            .margin({ left: 4, right: 4 })
          Text('管理端登录')
            .fontSize(AppText.CAPTION)
            .fontColor(AppColor.PRIMARY_DARK)
            .height(44)
            .padding({ left: 8, right: 8 })
            .onClick(() => {
              AppRouter.getInstance().replace(RouteName.ADMIN_LOGIN);
            })
        }
        .margin({ top: AppSize.GAP, bottom: 24 })
      }
      .width('100%')
      .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.BACKGROUND)
  }
}
