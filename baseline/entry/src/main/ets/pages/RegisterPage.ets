// 负责人：彭翌菲
// 提供注册口令和邀请深链注册流程，收集手机号、姓名和密码，
// 处理部门提示、客户端令牌及注册后的状态分流。

import { router } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
import { AuthApi, DeptBrief, RegisterRequest } from '../api/AuthApi';
import { TokenStore } from '../store/TokenStore';
import { PermissionStore, UpdateData } from '../store/PermissionStore';
import { genClientToken } from '../util/ClientToken';
import { backPage, replaceTo } from '../utils/RouterUtils';

const REGISTER_PRIMARY: string = '#155DFC';
const REGISTER_PRIMARY_ACTION: string = '#2B7FFF';
const REGISTER_TEXT: string = '#101828';
const REGISTER_LABEL: string = '#4A5565';
const REGISTER_MUTED: string = '#99A1AF';
const REGISTER_INPUT_BORDER: string = '#E5E7EB';
const REGISTER_BLUE_CARD_BORDER: string = '#DBEAFE';
const REGISTER_ERROR: string = '#FB2C36';
const REGISTER_ERROR_BORDER: string = '#FF6467';
const REGISTER_HEADER_BORDER: string = '#F3F4F6';
const REGISTER_BLUE_SHADOW: string = '#BEDBFF';

interface RegisterRouteParams {
  invite_token?: string;
  dept_hint?: string;
}

@Entry
@Component
struct RegisterPage {
  @State code: string = '';
  @State phone: string = '';
  @State name: string = '';
  @State password: string = '';
  @State loading: boolean = false;
  @State codeError: string = '';
  @State phoneError: string = '';
  @State nameError: string = '';
  @State passwordError: string = '';
  @State formError: string = '';
  @State backoffSeconds: number = 0;
  @State inviteToken: string = '';
  @State deptHint: DeptBrief | null = null;
  @State inviteInvalid: boolean = false;
  @State codeFocused: boolean = false;
  @State phoneFocused: boolean = false;
  @State nameFocused: boolean = false;
  @State passwordFocused: boolean = false;
  @State showPassword: boolean = false;

  private authApi: AuthApi = new AuthApi();
  private tokenStore: TokenStore = TokenStore.getInstance();
  private permissionStore: PermissionStore = PermissionStore.getInstance();
  private clientToken: string = genClientToken();
  private backoffTimer: number = -1;

  aboutToAppear(): void {
    const params = router.getParams() as RegisterRouteParams;
    if (params !== undefined && params !== null && params.invite_token !== undefined && params.invite_token.length > 0) {
      this.inviteToken = params.invite_token;
      this.loadInvitePreview();
    }
  }

  aboutToDisappear(): void {
    this.stopBackoff();
  }

  build() {
    Scroll() {
      Column() {
        Row({ space: 4 }) {
          Image($r('app.media.icon_chevron_left_figma'))
            .width(18)
            .height(18)
          Text('加入社团')
            .fontSize(14)
            .fontWeight(400)
            .fontFamily('Noto Sans CJK SC')
            .fontColor(REGISTER_PRIMARY)
            .lineHeight(20)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .alignItems(VerticalAlign.Center)
        .onClick(() => backPage())

        Divider()
          .color(REGISTER_HEADER_BORDER)
          .strokeWidth(1)

        Column({ space: 16 }) {

          Column({ space: 6 }) {
            Text('注册口令')
              .fontSize(14)
              .fontWeight(400)
              .fontFamily('Noto Sans CJK SC')
              .fontColor(REGISTER_LABEL)
              .lineHeight(20)

            TextInput({ text: this.code })
              .maxLength(32)
              .height(50)
              .fontSize(14)
              .fontWeight(400)
              .fontFamily('Noto Sans CJK SC')
              .fontColor(REGISTER_TEXT)
              .backgroundColor('#FFFFFF')
              .borderRadius(12)
              .border({ width: 1, color: this.codeBorderColor() })
              .outline({ width: this.codeFocused ? 2 : 0, color: REGISTER_BLUE_CARD_BORDER, radius: 12 })
              .padding({ left: 16, right: 16 })
              .onChange((value: string) => {
                this.code = value;
              })
              .onFocus(() => {
                this.codeFocused = true;
              })
              .onBlur(() => {
                this.codeFocused = false;
              })

            if (this.codeError.length > 0) {
              Text(this.codeError)
                .width('100%')
                .fontSize(12)
                .fontWeight(400)
                .fontFamily('Noto Sans CJK SC')
                .fontColor(REGISTER_ERROR)
                .lineHeight(16)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Column({ space: 6 }) {
            Text('手机号')
              .fontSize(14)
              .fontWeight(400)
              .fontFamily('Noto Sans CJK SC')
              .fontColor(REGISTER_LABEL)
              .lineHeight(20)

            TextInput({ text: this.phone })
              .type(InputType.Number)
              .maxLength(11)
              .height(50)
              .fontSize(14)
              .fontWeight(400)
              .fontFamily('Noto Sans CJK SC')
              .fontColor(REGISTER_TEXT)
              .backgroundColor('#FFFFFF')
              .borderRadius(12)
              .border({ width: 1, color: this.phoneBorderColor() })
              .outline({ width: this.phoneFocused ? 2 : 0, color: REGISTER_BLUE_CARD_BORDER, radius: 12 })
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
                .fontSize(12)
                .fontWeight(400)
                .fontFamily('Noto Sans CJK SC')
                .fontColor(REGISTER_ERROR)
                .lineHeight(16)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Column({ space: 6 }) {
            Text('姓名')
              .fontSize(14)
              .fontWeight(400)
              .fontFamily('Noto Sans CJK SC')
              .fontColor(REGISTER_LABEL)
              .lineHeight(20)

            TextInput({ text: this.name })
              .maxLength(32)
              .height(50)
              .fontSize(14)
              .fontWeight(400)
              .fontFamily('Noto Sans CJK SC')
              .fontColor(REGISTER_TEXT)
              .backgroundColor('#FFFFFF')
              .borderRadius(12)
              .border({ width: 1, color: this.nameBorderColor() })
              .outline({ width: this.nameFocused ? 2 : 0, color: REGISTER_BLUE_CARD_BORDER, radius: 12 })
              .padding({ left: 16, right: 16 })
              .onChange((value: string) => {
                this.name = value;
              })
              .onFocus(() => {
                this.nameFocused = true;
              })
              .onBlur(() => {
                this.nameFocused = false;
              })

            if (this.nameError.length > 0) {
              Text(this.nameError)
                .width('100%')
                .fontSize(12)
                .fontWeight(400)
                .fontFamily('Noto Sans CJK SC')
                .fontColor(REGISTER_ERROR)
                .lineHeight(16)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Column({ space: 6 }) {
            Text('密码')
              .fontSize(14)
              .fontWeight(400)
              .fontFamily('Noto Sans CJK SC')
              .fontColor(REGISTER_LABEL)
              .lineHeight(20)

            Row() {
              TextInput({ text: this.password })
                .type(this.showPassword ? InputType.Normal : InputType.Password)
                .showPasswordIcon(false)
                .maxLength(32)
                .layoutWeight(1)
                .height(50)
                .fontSize(14)
                .fontWeight(400)
                .fontFamily('Noto Sans CJK SC')
                .fontColor(REGISTER_TEXT)
                .backgroundColor('#FFFFFF')
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
                .fontColor(REGISTER_PRIMARY_ACTION)
                .lineHeight(20)
                .padding({ left: 8, right: 16 })
                .onClick(() => {
                  this.showPassword = !this.showPassword;
                })
            }
            .width('100%')
            .height(50)
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .border({ width: 1, color: this.passwordBorderColor() })
            .outline({ width: this.passwordFocused ? 2 : 0, color: REGISTER_BLUE_CARD_BORDER, radius: 12 })

            if (this.passwordError.length > 0) {
              Text(this.passwordError)
                .width('100%')
                .fontSize(12)
                .fontWeight(400)
                .fontFamily('Noto Sans CJK SC')
                .fontColor(REGISTER_ERROR)
                .lineHeight(16)
            } else {
              Text('密码：8-32 位，仅支持数字、英文或符号')
                .width('100%')
                .fontSize(12)
                .fontWeight(400)
                .fontFamily('Noto Sans CJK SC')
                .fontColor(REGISTER_MUTED)
                .lineHeight(16)
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          if (this.inviteInvalid) {
            Text('链接已失效：该招募链接已停用或不存在，仍可用注册口令加入。')
              .width('100%')
              .fontSize(14)
              .fontWeight(400)
              .fontFamily('Noto Sans CJK SC')
              .fontColor(REGISTER_LABEL)
              .lineHeight(22.75)
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .backgroundColor('#F9FAFB')
              .border({ width: 1, color: REGISTER_INPUT_BORDER })
              .borderRadius(12)
          }

          if (this.formError.length > 0) {
            Text(this.formError)
              .width('100%')
              .fontSize(12)
              .fontWeight(400)
              .fontFamily('Noto Sans CJK SC')
              .fontColor(REGISTER_ERROR)
              .lineHeight(16)
          }

          Button(this.buttonText())
            .width('100%')
            .height(56)
            .fontSize(16)
            .fontWeight(600)
            .fontFamily('Noto Sans CJK SC')
            .fontColor('#FFFFFF')
            .backgroundColor(REGISTER_PRIMARY)
            .borderRadius(12)
            .shadow({
              radius: 15,
              color: REGISTER_BLUE_SHADOW,
              offsetX: 0,
              offsetY: 10
            })
            .enabled(!this.loading && this.backoffSeconds === 0)
            .opacity(this.loading || this.backoffSeconds > 0 ? 0.65 : 1)
            .onClick(() => {
              if (!this.loading && this.backoffSeconds === 0) {
                this.handleRegister();
              }
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 24 })
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .backgroundColor('#FFFFFF')
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Off)
    .backgroundColor('#FFFFFF')
  }

  private codeBorderColor(): string {
    if (this.codeError.length > 0) return REGISTER_ERROR_BORDER;
    if (this.codeFocused) return REGISTER_PRIMARY_ACTION;
    return REGISTER_INPUT_BORDER;
  }

  private phoneBorderColor(): string {
    if (this.phoneError.length > 0) return REGISTER_ERROR_BORDER;
    if (this.phoneFocused) return REGISTER_PRIMARY_ACTION;
    return REGISTER_INPUT_BORDER;
  }

  private nameBorderColor(): string {
    if (this.nameError.length > 0) return REGISTER_ERROR_BORDER;
    if (this.nameFocused) return REGISTER_PRIMARY_ACTION;
    return REGISTER_INPUT_BORDER;
  }

  private passwordBorderColor(): string {
    if (this.passwordError.length > 0) return REGISTER_ERROR_BORDER;
    if (this.passwordFocused) return REGISTER_PRIMARY_ACTION;
    return REGISTER_INPUT_BORDER;
  }

  private buttonText(): string {
    if (this.loading) return '提交中…';
    if (this.backoffSeconds > 0) return `请稍后再试 (${this.backoffSeconds})`;
    return '提交申请';
  }

  private async loadInvitePreview(): Promise<void> {
    const response = await this.authApi.previewInvite(this.inviteToken);
    if (response.ok && response.data !== undefined) {
      if (response.data.enabled && response.data.dept !== null) {
        this.deptHint = response.data.dept;
      } else {
        this.inviteInvalid = true;
      }
    }
  }

  private isPasswordValid(value: string): boolean {
    const bytes: number = new util.TextEncoder().encodeInto(value).length;
    if (bytes < 8 || bytes > 32) {
      return false;
    }
    for (let i = 0; i < value.length; i++) {
      const code: number = value.charCodeAt(i);
      if (code < 0x21 || code > 0x7E) {
        return false;
      }
    }
    return true;
  }

  private clearErrors(): void {
    this.codeError = '';
    this.phoneError = '';
    this.nameError = '';
    this.passwordError = '';
    this.formError = '';
  }

  private validate(): boolean {
    this.clearErrors();
    let valid = true;
    if (this.code.length < 6 || this.code.length > 32) {
      this.codeError = '注册口令需为 6–32 位';
      valid = false;
    }
    if (!/^\d{11}$/.test(this.phone)) {
      this.phoneError = '请输入正确的手机号';
      valid = false;
    }
    if (this.name.length === 0 || this.name.length > 32) {
      this.nameError = '姓名不能为空且不能超过 32 个字符';
      valid = false;
    }
    if (!this.isPasswordValid(this.password)) {
      this.passwordError = '密码须为 8-32 位，仅支持数字、英文或符号';
      valid = false;
    }
    return valid;
  }

  private applyServerFields(fields?: Record<string, string>): void {
    if (fields === undefined) return;
    if (fields['register_code'] !== undefined) this.codeError = fields['register_code'];
    if (fields['phone'] !== undefined) this.phoneError = fields['phone'];
    if (fields['name'] !== undefined) this.nameError = fields['name'];
    if (fields['password'] !== undefined) this.passwordError = fields['password'];
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

  async handleRegister(): Promise<void> {
    if (!this.validate()) return;
    this.loading = true;
    try {
      const request: RegisterRequest = {
        register_code: this.code,
        phone: this.phone,
        name: this.name,
        password: this.password,
        client_token: this.clientToken,
      };
      if (this.inviteToken.length > 0) {
        request.invite_token = this.inviteToken;
      }

      const response = await this.authApi.register(request);
      if (!response.ok || response.data === undefined) {
        const code = response.error?.code ?? '';
        if (code === 'REGISTER_CODE_INVALID') {
          this.codeError = '注册口令不正确（REGISTER_CODE_INVALID）';
        } else if (code === 'ALREADY_EXISTS') {
          this.phoneError = '已存在同名或同手机号的账号';
        } else {
          this.applyServerFields(response.error?.fields);
          this.formError = response.error?.message ?? '注册失败，请稍后重试';
        }
        if (code === 'TOO_MANY_ATTEMPTS') {
          this.startBackoff();
        }
        return;
      }

      await this.tokenStore.setToken(response.data.token);
      const update: UpdateData = {
        user: response.data.member,
        permissions: response.data.permissions,
      };
      this.permissionStore.update(update);
      replaceTo('pages/PendingPage');
    } catch (_) {
      this.formError = '网络不可用，请检查服务端是否可访问';
    } finally {
      this.loading = false;
    }
  }
}
