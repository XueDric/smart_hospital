// 负责人：彭翌菲
// 提供手机号和密码登录交互，完成参数校验与接口调用，
// 再根据账号状态和权限将用户分流到等待页或首页。

import { AuthApi, LoginRequest } from '../api/AuthApi';
import { Color, FontSize } from '../core/Theme';
import { TokenStore } from '../store/TokenStore';
import { PermissionStore, UpdateData } from '../store/PermissionStore';
import { pushTo, replaceTo } from '../utils/RouterUtils';

const LOGIN_PRIMARY: string = '#155DFC';
const LOGIN_PRIMARY_ACTION: string = '#2B7FFF';
const LOGIN_TEXT: string = '#101828';
const LOGIN_LABEL: string = '#4A5565';
const LOGIN_MUTED: string = '#99A1AF';
const LOGIN_DISABLED: string = '#D1D5DC';
const LOGIN_INPUT_BORDER: string = '#E5E7EB';
const LOGIN_BLUE_SHADOW: string = '#BEDBFF';

@Entry
@Component
struct LoginPage {
  @State phone: string = '';
  @State password: string = '';
  @State loading: boolean = false;
  @State phoneError: string = '';
  @State passwordError: string = '';
  @State errorMsg: string = '';
  @State backoffSeconds: number = 0;
  @State showPassword: boolean = false;
  @State phoneFocused: boolean = false;
  @State passwordFocused: boolean = false;

  private authApi: AuthApi = new AuthApi();
  private tokenStore: TokenStore = TokenStore.getInstance();
  private permissionStore: PermissionStore = PermissionStore.getInstance();
  private backoffTimer: number = -1;

  aboutToDisappear(): void {
    this.stopBackoff();
  }

  build() {
    Column() {
      Column() {
        Image($r('app.media.new_logo'))
          .width(64)
          .height(64)
          .margin({ bottom: 20 })

        Text('社团管理工具')
          .fontSize(24)
          .fontWeight(700)
          .fontFamily('Noto Sans CJK SC')
          .fontColor(LOGIN_TEXT)
          .lineHeight(32)

        Text('登录后查看你负责的每一件事')
          .fontSize(14)
          .fontWeight(400)
          .fontFamily('Noto Sans CJK SC')
          .fontColor(LOGIN_MUTED)
          .lineHeight(20)
          .margin({ top: 4 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .margin({ bottom: 32 })

      Column() {
        Column({ space: 6 }) {
          Text('手机号')
            .fontSize(14)
            .fontWeight(400)
            .fontFamily('Noto Sans CJK SC')
            .fontColor(LOGIN_LABEL)
            .lineHeight(20)

          TextInput({ placeholder: '', text: this.phone })
            .type(InputType.Number)
            .maxLength(11)
            .height(50)
            .fontSize(14)
            .fontWeight(400)
            .fontFamily('Noto Sans CJK SC')
            .fontColor(LOGIN_TEXT)
            .placeholderColor(LOGIN_TEXT)
            .backgroundColor(Color.surface)
            .borderRadius(12)
            .border({ width: 1, color: this.phoneBorderColor() })
            .padding({ left: 16, right: 16 })
            .onChange((value: string) => {
              this.phone = value;
            })
            .onFocus(() => {
              this.phoneFocused = true;
            })
            .onBlur(() => {
              this.phoneFocused = false;
            })

          if (this.phoneError.length > 0) {
            Text(this.phoneError)
              .width('100%')
              .fontSize(FontSize.caption)
              .fontColor(Color.danger)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 6 }) {
          Text('密码')
            .fontSize(14)
            .fontWeight(400)
            .fontFamily('Noto Sans CJK SC')
            .fontColor(LOGIN_LABEL)
            .lineHeight(20)

          Row() {
            TextInput({ placeholder: '', text: this.password })
              .type(this.showPassword ? InputType.Normal : InputType.Password)
              .showPasswordIcon(false)
              .maxLength(32)
              .layoutWeight(1)
              .height(50)
              .fontSize(14)
              .fontWeight(400)
              .fontFamily('Noto Sans CJK SC')
              .fontColor(LOGIN_TEXT)
              .placeholderColor(LOGIN_TEXT)
              .backgroundColor(Color.surface)
              .padding({ left: 16, right: 8 })
              .onChange((value: string) => {
                this.password = value;
              })
              .onFocus(() => {
                this.passwordFocused = true;
              })
              .onBlur(() => {
                this.passwordFocused = false;
              })

            Text(this.showPassword ? '隐藏' : '显示')
              .fontSize(14)
              .fontWeight(500)
              .fontFamily('Noto Sans CJK SC')
              .fontColor(LOGIN_PRIMARY_ACTION)
              .lineHeight(20)
              .padding({ left: 8, right: 16 })
              .onClick(() => {
                this.showPassword = !this.showPassword;
              })
          }
          .width('100%')
          .height(50)
          .backgroundColor(Color.surface)
          .borderRadius(12)
          .border({ width: 1, color: this.passwordBorderColor() })

          if (this.passwordError.length > 0) {
            Text(this.passwordError)
              .width('100%')
              .fontSize(FontSize.caption)
              .fontColor(Color.danger)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .margin({ top: 16 })

        if (this.errorMsg.length > 0) {
          Text(this.errorMsg)
            .width('100%')
            .fontSize(FontSize.caption)
            .fontColor(Color.danger)
            .margin({ top: 8 })
        }

        Button(this.buttonText())
          .width('100%')
          .height(56)
          .fontSize(16)
          .fontWeight(600)
          .fontFamily('Noto Sans CJK SC')
          .fontColor(Color.onPrimary)
          .backgroundColor(LOGIN_PRIMARY)
          .borderRadius(12)
          .shadow({
            radius: 15,
            color: LOGIN_BLUE_SHADOW,
            offsetX: 0,
            offsetY: 10
          })
          .enabled(!this.loading && this.backoffSeconds === 0)
          .opacity(this.loading || this.backoffSeconds > 0 ? 0.65 : 1)
          .onClick(() => {
            if (!this.loading && this.backoffSeconds === 0) {
              this.handleLogin();
            }
          })
          .margin({ top: 24 })

        Row({ space: 4 }) {
          Text('还没有账号？')
            .fontSize(14)
            .fontWeight(400)
            .fontFamily('Noto Sans CJK SC')
            .fontColor(LOGIN_MUTED)
            .lineHeight(20)
          Text('用注册口令加入')
            .fontSize(14)
            .fontWeight(500)
            .fontFamily('Noto Sans CJK SC')
            .fontColor(LOGIN_PRIMARY)
            .lineHeight(20)
            .onClick(() => {
              pushTo('pages/RegisterPage');
            })
        }
        .justifyContent(FlexAlign.Center)
        .width('100%')
        .margin({ top: 16 })

        Column({ space: 8 }) {
          Image($r('app.media.bit_logo'))
            .width(88)
            .height(88)

          Text('北京理工大学')
            .fontSize(14)
            .fontWeight(500)
            .fontFamily('Noto Sans CJK SC')
            .fontColor(LOGIN_LABEL)
            .lineHeight(20)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 44 })
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: 12 }) {
        Text('忘记密码？请联系会长或副会长在管理页为你重置')
          .width('100%')
          .fontSize(12)
          .fontWeight(400)
          .fontFamily('Noto Sans CJK SC')
          .fontColor(LOGIN_MUTED)
          .lineHeight(20)
          .textAlign(TextAlign.Center)

      }
      .width('100%')
      .margin({ top: 56 })
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 24, right: 24, top: 48, bottom: 32 })
    .backgroundColor(Color.surface)
  }

  private phoneBorderColor(): string {
    if (this.phoneError.length > 0) return Color.danger;
    if (this.phoneFocused) return LOGIN_PRIMARY_ACTION;
    return LOGIN_INPUT_BORDER;
  }

  private passwordBorderColor(): string {
    if (this.passwordError.length > 0) return Color.danger;
    if (this.passwordFocused) return LOGIN_PRIMARY_ACTION;
    return LOGIN_INPUT_BORDER;
  }

  private buttonText(): string {
    if (this.loading) return '登录中…';
    if (this.backoffSeconds > 0) return `请稍后再试 (${this.backoffSeconds})`;
    return '登录';
  }

  private startBackoff(): void {
    this.stopBackoff();
    this.backoffSeconds = 30;
    this.backoffTimer = setInterval(() => {
      if (this.backoffSeconds <= 1) {
        this.backoffSeconds = 0;
        this.stopBackoff();
      } else {
        this.backoffSeconds -= 1;
      }
    }, 1000);
  }

  private stopBackoff(): void {
    if (this.backoffTimer !== -1) {
      clearInterval(this.backoffTimer);
      this.backoffTimer = -1;
    }
  }

  private routeAfterAuth(status: string, viewScope: string): void {
    if (status === 'pending' || viewScope === 'none') {
      replaceTo('pages/PendingPage');
    } else {
      replaceTo('pages/Index');
    }
  }

  async handleLogin(): Promise<void> {
    this.phoneError = '';
    this.passwordError = '';
    this.errorMsg = '';
    let valid = true;
    if (!/^\d{11}$/.test(this.phone)) {
      this.phoneError = '请输入正确的手机号';
      valid = false;
    }
    if (this.password.length === 0) {
      this.passwordError = '请输入密码';
      valid = false;
    }
    if (!valid) {
      return;
    }

    this.loading = true;
    try {
      const request: LoginRequest = { phone: this.phone, password: this.password };
      const loginResp = await this.authApi.login(request);
      if (!loginResp.ok || loginResp.data === undefined) {
        this.errorMsg = loginResp.error?.message ?? '登录失败，请稍后重试';
        if (loginResp.error?.code === 'TOO_MANY_ATTEMPTS') {
          this.startBackoff();
        }
        return;
      }

      await this.tokenStore.setToken(loginResp.data.token);
      const meResp = await this.authApi.me();
      if (!meResp.ok || meResp.data === undefined) {
        this.errorMsg = meResp.error?.message ?? '登录状态校验失败，请重试';
        return;
      }

      const update: UpdateData = {
        user: meResp.data.member,
        permissions: meResp.data.permissions,
      };
      this.permissionStore.update(update);
      this.routeAfterAuth(meResp.data.member.status, meResp.data.permissions.view_scope);
    } catch (_) {
      this.errorMsg = '网络不可用，请检查服务端是否可访问';
    } finally {
      this.loading = false;
    }
  }
}
